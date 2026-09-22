import Foundation

/// The scrcpy client/server protocol is internal to scrcpy and changes between
/// releases (v4.0 reshaped the video stream). Everything here targets exactly
/// one pinned server build; bump all three constants together.
public enum ScrcpyProtocol {
    public static let serverVersion = "4.1"
    public static let serverResourceName = "scrcpy-server-v4.1"
    public static let serverSHA256 = "deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae"

    public static let remoteServerPath = "/data/local/tmp/scrcpy-server.jar"
    static let deviceNameLength = 64
    static let packetHeaderLength = 12
    /// Guards against allocating garbage sizes after a desync.
    static let maxPacketSize = 32 * 1024 * 1024
}

public enum StreamCodec: UInt32, Sendable {
    case h264 = 0x6832_3634
    case h265 = 0x6832_3635
    case av1 = 0x0061_7631
    case vp8 = 0x0076_7038
    case vp9 = 0x0076_7039
    case opus = 0x6f70_7573
    case aac = 0x0061_6163
    case flac = 0x666c_6163
    case raw = 0x0072_6177

    /// Value for the `video_codec` / `audio_codec` server option.
    public var optionValue: String { String(describing: self) }
}

public enum ScrcpyError: Error, Equatable, CustomStringConvertible {
    case serverBinaryMissing
    case serverBinaryCorrupted(sha256: String)
    case serverExited(log: [String])
    case connectTimeout(log: [String])
    /// The device reported the stream as disabled (codec id 0).
    case streamDisabled
    /// The device failed to configure the stream (codec id 1).
    case streamConfigurationFailed
    case unknownCodec(UInt32)
    case malformedPacket(String)
    case controlDisabled

    public var description: String {
        switch self {
        case .serverBinaryMissing:
            return "bundled \(ScrcpyProtocol.serverResourceName) not found"
        case .serverBinaryCorrupted(let sha256):
            return "bundled scrcpy-server has unexpected sha256 \(sha256)"
        case .serverExited(let log):
            return "scrcpy-server exited before accepting connections:\n" + log.joined(separator: "\n")
        case .connectTimeout(let log):
            return "timed out connecting to scrcpy-server:\n" + log.joined(separator: "\n")
        case .streamDisabled:
            return "stream disabled by the device"
        case .streamConfigurationFailed:
            return "the device could not configure the stream"
        case .unknownCodec(let id):
            return String(format: "unknown codec id 0x%08x", id)
        case .malformedPacket(let detail):
            return "malformed packet: \(detail)"
        case .controlDisabled:
            return "session was started without a control socket"
        }
    }
}
