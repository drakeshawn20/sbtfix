import SwiftUI
import SonyProtocol

@main
struct SbtfixApp: App {
    @StateObject private var controller: HeadphoneController

    init() {
        let c = HeadphoneController()
        _controller = StateObject(wrappedValue: c)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.async {
                Screenshots.render(to: dir)
                exit(0)
            }
            return
        }
        // Connect at launch rather than when the menu is first opened.
        DispatchQueue.main.async { c.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(controller: controller)
        } label: {
            Image(systemName: controller.status == .connected ? controller.ambient.mode.symbol : "headphones")
        }
        .menuBarExtraStyle(.window)
    }
}

extension AmbientMode {
    var title: String {
        switch self {
        case .noiseCancelling: "Noise Cancelling"
        case .windNoiseReduction: "Wind Reduction"
        case .ambient: "Ambient Sound"
        case .off: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCancelling: "person.wave.2.fill"
        case .windNoiseReduction: "wind"
        case .ambient: "ear.fill"
        case .off: "headphones"
        }
    }
}

struct ControlPanel: View {
    @ObservedObject var controller: HeadphoneController
    @State private var level: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if controller.status == .connected {
                if !controller.availableModes.isEmpty {
                    modePicker
                    if controller.ambient.mode == .ambient { ambientOptions }
                }
                if let speakToChat = controller.speakToChat {
                    Divider()
                    Toggle("Speak-to-Chat", isOn: Binding(
                        get: { speakToChat },
                        set: { controller.setSpeakToChat($0) }))
                }
            } else {
                statusMessage
            }
            Divider()
            HStack {
                if controller.status != .connected {
                    Button("Retry") { controller.connect() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: controller.availableModes.count > 3 ? 360 : 300)
        .toggleStyle(.switch)
        .onAppear {
            level = Double(controller.ambient.level)
            controller.refresh()
        }
        .onChange(of: controller.ambient.level) { _, new in level = Double(new) }
    }

    private var header: some View {
        let b = controller.batteries
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: controller.profile.isEarbuds ? "earbuds" : "headphones").font(.title2)
                Text(controller.deviceName ?? "Sony Headphones").font(.headline).lineLimit(1)
                Spacer()
                if let single = b.single { batteryLabel(nil, single) }
            }
            // Earbuds report up to three levels; give them their own row.
            if b.single == nil && !b.isEmpty {
                HStack(spacing: 12) {
                    if let left = b.left { batteryLabel("L", left) }
                    if let right = b.right { batteryLabel("R", right) }
                    if let c = b.caseBattery { batteryLabel("Case", c) }
                }
            }
        }
    }

    private func batteryLabel(_ prefix: String?, _ battery: BatteryLevel) -> some View {
        let text = [prefix, "\(battery.level)%"].compactMap { $0 }.joined(separator: " ")
        return Label(text, systemImage: battery.charging ? "battery.100.bolt" : batterySymbol(battery.level))
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .foregroundStyle(battery.level <= 20 ? .red : .secondary)
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(controller.availableModes) { mode in
                let selected = controller.ambient.mode == mode
                Button { controller.setMode(mode) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.symbol).font(.title2)
                        Text(mode.title).font(.caption).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(selected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(selected ? .white : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ambientOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ambient level")
                Spacer()
                Text("\(Int(level))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $level, in: 1...20, step: 1)
                .onChange(of: level) { _, new in
                    if Int(new) != controller.ambient.level { controller.setAmbientLevel(Int(new)) }
                }
            Toggle("Focus on voice", isOn: Binding(
                get: { controller.ambient.focusOnVoice },
                set: { controller.setFocusOnVoice($0) }))
        }
    }

    private var statusMessage: some View {
        Group {
            switch controller.status {
            case .searching:
                Text("Waiting for headphones to connect…")
            case .connecting:
                HStack { ProgressView().controlSize(.small); Text("Connecting…") }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red)
            case .connected:
                EmptyView()
            }
        }
        .font(.callout)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }
}
