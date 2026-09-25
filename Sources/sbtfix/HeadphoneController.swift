import Foundation
import IOBluetooth
import os
import SonyProtocol

struct Batteries: Equatable {
    var single: BatteryLevel?
    var left: BatteryLevel?
    var right: BatteryLevel?
    var caseBattery: BatteryLevel?

    var isEmpty: Bool { single == nil && left == nil && right == nil && caseBattery == nil }
}

/// Owns the RFCOMM link to the headphones. All IOBluetooth callbacks arrive on the main run loop.
final class HeadphoneController: NSObject, ObservableObject {
    private let log = Logger(subsystem: "io.github.htsecurity.sbtfix", category: "bt")

    enum Status: Equatable {
        case searching
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var deviceName: String?
    @Published private(set) var profile = DeviceProfile()
    @Published private(set) var batteries = Batteries()
    @Published private(set) var ambient = AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 10)
    @Published private(set) var ambientLayout: AmbientLayout?
    /// nil until the device answers; stays nil on models without Speak-to-Chat.
    @Published private(set) var speakToChat: Bool?

    var availableModes: [AmbientMode] { profile.modes(layout: ambientLayout) }

    /// Control service UUIDs: v2 (WH-1000XM5 and newer) first, then v1 (XM3/XM4 era).
    private static let serviceUUIDs: [[UInt8]] = [
        [0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8, 0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2],
        [0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD, 0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA],
    ]

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = FrameParser()
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?

    // The headphones accept one command at a time; the next is sent once the ACK arrives.
    private var queue: [(key: String?, payload: [UInt8])] = []
    private var sequence: UInt8 = 0
    private var awaitingAck = false
    private var ackTimer: Timer?
    private var batteryTimer: Timer?
    private var retryTimer: Timer?
    private var connectingSince: Date?
    /// While the user is changing ambient settings, the device echoes each intermediate value.
    /// Those echoes lag behind the UI, so they're ignored until things settle, then re-read once.
    private var lastAmbientSet = Date.distantPast
    private var ambientSyncTimer: Timer?

    /// Detected from the init reply; nothing but init is sent before it's known.
    private var version: ProtocolVersion?

    func start() {
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceDidConnect(_:device:)))
        // Covers Bluetooth being switched on and connect events we miss (e.g. while it was off).
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.status == .connecting, let since = self.connectingSince, Date().timeIntervalSince(since) > 20 {
                self.log.error("connect timed out")
                self.tearDown()
            }
            guard self.channel == nil, self.status != .connecting else { return }
            self.connect()
        }
        connect()
    }

    func connect() {
        guard channel == nil else { return }
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            status = .failed("Bluetooth is turned off")
            return
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let sony = paired.filter { DeviceProfile.isSony(name: $0.name ?? "") }
        guard let target = sony.first(where: { $0.isConnected() }) else {
            status = sony.isEmpty ? .failed("No paired Sony headphones found") : .searching
            deviceName = sony.first?.name
            return
        }
        device = target
        deviceName = target.name
        profile = DeviceProfile.forName(target.name ?? "")
        status = .connecting
        connectingSince = Date()

        if let channelID = rfcommChannelID(for: target) {
            openChannel(channelID)
        } else {
            let uuids = Self.serviceUUIDs.map { IOBluetoothSDPUUID(bytes: $0, length: 16) }
            target.performSDPQuery(self, uuids: uuids)
        }
    }

    // MARK: - Commands

    /// Re-reads state from the headphones (e.g. after buttons on the headphones were used).
    func refresh() {
        guard let version, status == .connected else { return }
        if profile.hasAmbientControl {
            if case .v2(let type, _) = ambientLayout {
                enqueue(Command.getAmbient(.v2, inquiredType: type), key: "get-anc")
            } else {
                enqueue(Command.getAmbient(version), key: "get-anc")
            }
        }
        requestBattery()
        enqueue(Command.getSpeakToChat(version), key: "get-stc")
    }

    func setMode(_ mode: AmbientMode) {
        var s = ambient
        s.mode = mode
        sendAmbient(s)
    }

    func setAmbientLevel(_ level: Int) {
        var s = ambient
        s.level = level
        sendAmbient(s)
    }

    func setFocusOnVoice(_ on: Bool) {
        var s = ambient
        s.focusOnVoice = on
        sendAmbient(s)
    }

    func setSpeakToChat(_ on: Bool) {
        guard let version else { return }
        speakToChat = on
        enqueue(Command.setSpeakToChat(on, version), key: "stc")
    }

    private func sendAmbient(_ s: AmbientState) {
        guard let version else { return }
        ambient = s
        // If the device hasn't told us its layout yet, fall back to the most common one.
        let layout = ambientLayout ?? (version == .v1
            ? .v1(windCapable: profile.hasWindNoiseReduction)
            : .v2(inquiredType: 0x17, windByte: profile.hasWindNoiseReduction))
        enqueue(Command.setAmbient(s, layout: layout), key: "anc")
        lastAmbientSet = Date()
        ambientSyncTimer?.invalidate()
        ambientSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, let version = self.version else { return }
            if case .v2(let type, _) = layout {
                self.enqueue(Command.getAmbient(.v2, inquiredType: type), key: "get-anc")
            } else {
                self.enqueue(Command.getAmbient(version), key: "get-anc")
            }
        }
    }

    private func requestBattery() {
        guard let version else { return }
        for kind in profile.batteryKinds {
            if let payload = Command.getBattery(version, kind: kind) {
                enqueue(payload, key: "battery-\(kind)")
            }
        }
    }

    // MARK: - Connection

    private func rfcommChannelID(for d: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        for bytes in Self.serviceUUIDs {
            let uuid = IOBluetoothSDPUUID(bytes: bytes, length: 16)
            guard let record = d.getServiceRecord(for: uuid) else { continue }
            var id: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&id) == kIOReturnSuccess { return id }
        }
        return nil
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let d = device, d == self.device else { return }
        if let id = rfcommChannelID(for: d) {
            openChannel(id)
        } else {
            self.status = .failed("\(d.name ?? "This device") doesn't expose the Sony control service")
        }
    }

    private func openChannel(_ id: BluetoothRFCOMMChannelID) {
        guard let device else { return }
        var ch: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&ch, withChannelID: id, delegate: self)
        if result == kIOReturnSuccess {
            channel = ch
        } else {
            status = .failed(String(format: "Could not open control channel (0x%08x)", result))
        }
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard DeviceProfile.isSony(name: device.name ?? ""), channel == nil else { return }
        // Give the audio profiles a moment to settle before opening RFCOMM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    @objc private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        tearDown()
    }

    private func tearDown() {
        ackTimer?.invalidate()
        ackTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        ambientSyncTimer?.invalidate()
        ambientSyncTimer = nil
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        disconnectNotification?.unregister()
        disconnectNotification = nil
        queue.removeAll()
        awaitingAck = false
        sequence = 0
        parser = FrameParser()
        version = nil
        ambientLayout = nil
        batteries = Batteries()
        speakToChat = nil
        status = .searching
    }

    // MARK: - Messaging

    private func enqueue(_ payload: [UInt8], key: String? = nil) {
        // Coalesce repeated settings (e.g. slider drags) so only the latest value is sent.
        if let key, let i = queue.firstIndex(where: { $0.key == key }) {
            queue[i].payload = payload
        } else {
            queue.append((key, payload))
        }
        pump()
    }

    private func pump() {
        guard !awaitingAck, status == .connected, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        write(Message(type: .command1, sequence: sequence, payload: next.payload).encode())
        awaitingAck = true
        ackTimer?.invalidate()
        ackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.awaitingAck = false
            self?.pump()
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let channel else { return }
        log.debug("tx \(hex(bytes), privacy: .public)")
        var data = bytes
        data.withUnsafeMutableBytes { buf in
            _ = channel.writeSync(buf.baseAddress, length: UInt16(buf.count))
        }
    }

    private func handle(_ message: Message) {
        switch message.type {
        case .ack:
            sequence = message.sequence
            awaitingAck = false
            ackTimer?.invalidate()
            pump()
        case .command1, .command2:
            log.debug("rx \(hex(message.payload), privacy: .public)")
            write(Message(type: .ack, sequence: 1 &- message.sequence, payload: []).encode())
            apply(EventParser.parse(message.payload, version: version))
        }
    }

    private func apply(_ event: Event) {
        log.debug("event \(String(describing: event), privacy: .public)")
        switch event {
        case .initReply(let v):
            guard version == nil else { return }
            version = v
            log.info("protocol \(String(describing: v), privacy: .public)")
            requestInitialState(v)
        case let .ambient(state, layout):
            ambientLayout = layout
            // Don't clobber a change the user is still making (see lastAmbientSet).
            guard !queue.contains(where: { $0.key == "anc" }),
                  Date().timeIntervalSince(lastAmbientSet) > 0.8 else { return }
            var s = state
            // v1 reports level 0 outside ambient mode; keep the last real level for the slider.
            if s.mode != .ambient { s.level = ambient.level }
            ambient = s
        case .battery(let level):
            batteries.single = level
        case let .batteryDual(left, right):
            batteries.left = left
            batteries.right = right
        case .batteryCase(let level):
            batteries.caseBattery = level
        case .speakToChat(let enabled):
            speakToChat = enabled
        case .unknown:
            break
        }
    }

    private func requestInitialState(_ v: ProtocolVersion) {
        if profile.hasAmbientControl {
            switch v {
            case .v1:
                enqueue(Command.getAmbient(.v1))
            case .v2:
                // Firmware differs in which layout it answers (0x15, 0x17 or 0x22; XM5 fw 2.4.1
                // only answers 0x17). Ask with each — the reply tells us which to use for SET.
                for type: UInt8 in profile.hasNoiseCancelling ? [0x17, 0x15] : [0x17, 0x22] {
                    enqueue(Command.getAmbient(.v2, inquiredType: type))
                }
            }
        }
        requestBattery()
        enqueue(Command.getSpeakToChat(v))
    }
}

extension HeadphoneController: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            channel = nil
            status = .failed(String(format: "Control channel failed to open (0x%08x)", error))
            log.error("channel open failed \(error)")
            return
        }
        status = .connected
        log.info("control channel open")
        disconnectNotification = device?.register(forDisconnectNotification: self,
                                                  selector: #selector(deviceDidDisconnect(_:device:)))
        // Everything else is requested once the init reply tells us the protocol version.
        enqueue(Command.initRequest)
        // Battery isn't always pushed; refresh it periodically.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.requestBattery()
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        for message in parser.feed(bytes) {
            handle(message)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        tearDown()
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - Screenshot support

extension HeadphoneController {
    /// A controller with fixed state and no Bluetooth, used to render README screenshots.
    static func preview(status: Status, name: String = "WH-1000XM5",
                        batteries: Batteries = Batteries(single: BatteryLevel(level: 72, charging: false)),
                        ambient: AmbientState = AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 20),
                        speakToChat: Bool? = false) -> HeadphoneController {
        let c = HeadphoneController()
        c.status = status
        c.deviceName = name
        c.profile = DeviceProfile.forName(name)
        c.batteries = batteries
        c.ambient = ambient
        c.speakToChat = speakToChat
        return c
    }
}
