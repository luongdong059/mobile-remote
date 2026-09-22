import Foundation

/// Byte-level encoding of the adb "smart socket" and sync protocols.
enum ADBWire {
    static let syncDataMax = 64 * 1024

    /// Host requests are the payload prefixed by its length as 4 hex digits.
    static func request(_ payload: String) -> Data {
        let body = Data(payload.utf8)
        return Data(String(format: "%04x", body.count).utf8) + body
    }

    static func parseHexLength(_ data: Data) throws -> Int {
        guard data.count == 4, let text = String(data: data, encoding: .ascii),
              let length = Int(text, radix: 16) else {
            throw ADBError.protocolViolation("bad length prefix \(Array(data))")
        }
        return length
    }

    /// Sync packets are a 4-char ASCII id followed by a little-endian u32.
    static func syncHeader(_ id: String, _ value: UInt32) -> Data {
        var data = Data(id.utf8)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func syncSend(remotePath: String, mode: UInt32) -> Data {
        let spec = Data("\(remotePath),\(0o100000 | mode)".utf8)
        return syncHeader("SEND", UInt32(spec.count)) + spec
    }
}
