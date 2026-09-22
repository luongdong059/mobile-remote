import ADBKit
import Foundation

/// Device → client messages on the control socket.
public enum DeviceMessage: Equatable, Sendable {
    /// The phone's clipboard changed (sent when `clipboard_autosync` is on).
    case clipboard(String)
    /// The phone applied the `setClipboard` with this sequence number.
    case clipboardAcknowledged(sequence: UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

/// The socket must be drained even when nothing uses the messages, or the
/// server's sender eventually blocks on a full buffer.
public struct DeviceMessageReader {
    private let source: any ByteSource
    static let maxTextBytes = 1 << 18

    public init(source: any ByteSource) {
        self.source = source
    }

    /// Returns nil when the stream ends.
    public func next() throws -> DeviceMessage? {
        let type: UInt8
        do {
            type = try source.readExactly(1)[0]
        } catch ADBError.endOfStream {
            return nil
        }
        switch type {
        case 0:
            let length = Int(try readInteger(UInt32.self))
            guard length <= Self.maxTextBytes else {
                throw ScrcpyError.malformedPacket("clipboard of \(length) bytes")
            }
            return .clipboard(String(decoding: try source.readExactly(length), as: UTF8.self))
        case 1:
            return .clipboardAcknowledged(sequence: try readInteger(UInt64.self))
        case 2:
            let id = try readInteger(UInt16.self)
            let size = Int(try readInteger(UInt16.self))
            return .uhidOutput(id: id, data: try source.readExactly(size))
        default:
            throw ScrcpyError.malformedPacket("unknown device message type \(type)")
        }
    }

    private func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        try source.readExactly(MemoryLayout<T>.size).reduce(0) { $0 << 8 | T($1) }
    }
}
