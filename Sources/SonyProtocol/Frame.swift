import Foundation

/// Sony "MDR" framing used by WH-1000XM* headphones over RFCOMM.
///
/// Wire format:  0x3E | type | seq | len(4, big endian) | payload | checksum | 0x3C
/// Everything between the header and trailer is escaped: 0x3C/0x3D/0x3E become
/// 0x3D followed by (byte & 0xEF). The checksum is the byte sum of type..payload.
public enum MessageType: UInt8 {
    case ack = 0x01
    case command1 = 0x0C
    case command2 = 0x0E
}

public struct Message: Equatable {
    public let type: MessageType
    public let sequence: UInt8
    public let payload: [UInt8]

    public init(type: MessageType, sequence: UInt8, payload: [UInt8]) {
        self.type = type
        self.sequence = sequence
        self.payload = payload
    }

    static let header: UInt8 = 0x3E
    static let trailer: UInt8 = 0x3C
    static let escape: UInt8 = 0x3D
    static let escapeMask: UInt8 = 0xEF

    public func encode() -> [UInt8] {
        let length = UInt32(payload.count)
        var body: [UInt8] = [type.rawValue, sequence,
                             UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                             UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        body += payload
        body.append(Self.checksum(body))

        var out: [UInt8] = [Self.header]
        for b in body {
            if b == Self.header || b == Self.trailer || b == Self.escape {
                out.append(Self.escape)
                out.append(b & Self.escapeMask)
            } else {
                out.append(b)
            }
        }
        out.append(Self.trailer)
        return out
    }

    /// Decodes one frame's contents (without header/trailer, still escaped).
    static func decode(escaped: ArraySlice<UInt8>) -> Message? {
        var raw: [UInt8] = []
        raw.reserveCapacity(escaped.count)
        var it = escaped.makeIterator()
        while let b = it.next() {
            if b == escape {
                guard let next = it.next() else { return nil }
                raw.append(next | ~escapeMask)
            } else {
                raw.append(b)
            }
        }
        guard raw.count >= 7 else { return nil }
        guard checksum(raw[..<(raw.count - 1)]) == raw[raw.count - 1] else { return nil }
        let length = Int(raw[2]) << 24 | Int(raw[3]) << 16 | Int(raw[4]) << 8 | Int(raw[5])
        guard length == raw.count - 7, let type = MessageType(rawValue: raw[0]) else { return nil }
        return Message(type: type, sequence: raw[1], payload: Array(raw[6..<(6 + length)]))
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }
}

/// Accumulates bytes from the RFCOMM stream and yields complete messages.
public struct FrameParser {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Message] {
        buffer += bytes
        var messages: [Message] = []
        while true {
            guard let start = buffer.firstIndex(of: Message.header) else {
                buffer.removeAll()
                break
            }
            guard let end = buffer[(start + 1)...].firstIndex(of: Message.trailer) else {
                buffer.removeFirst(start)
                break
            }
            if let msg = Message.decode(escaped: buffer[(start + 1)..<end]) {
                messages.append(msg)
            }
            buffer.removeFirst(end + 1)
        }
        return messages
    }
}
