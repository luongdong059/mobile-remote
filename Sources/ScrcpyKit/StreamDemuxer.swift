import ADBKit
import Foundation

public struct MediaPacket: Equatable, Sendable {
    /// Microseconds on the device clock; nil for config packets.
    public let pts: UInt64?
    /// Codec configuration (SPS/PPS for H.264), not a frame.
    public let isConfig: Bool
    public let isKeyFrame: Bool
    /// Raw MediaCodec output: Annex B for H.264 / H.265.
    public let payload: Data
}

public enum StreamPacket: Equatable, Sendable {
    /// Start of a capture session: sent before the first frame and again after
    /// every rotation / resize. A new config packet follows.
    case session(width: Int, height: Int, clientResized: Bool)
    case media(MediaPacket)
}

/// Parses one scrcpy v4.x stream: a u32 codec id, then 12-byte-header packets.
///
///     session: [flags u32: bit 31 = session, bit 0 = client resized] [width u32] [height u32]
///     media:   [u64: bit 63 = 0, bit 62 = config, bit 61 = key frame, low 61 = pts] [size u32] [payload]
///
/// v3.x differs (no session packets, width/height after the codec id, flags in
/// bits 63/62), so most third-party write-ups do not apply.
public struct StreamDemuxer {
    private let source: any ByteSource

    public init(source: any ByteSource) {
        self.source = source
    }

    public func readCodec() throws -> StreamCodec {
        let raw = Self.u32([UInt8](try source.readExactly(4)), 0)
        switch raw {
        case 0: throw ScrcpyError.streamDisabled
        case 1: throw ScrcpyError.streamConfigurationFailed
        default:
            guard let codec = StreamCodec(rawValue: raw) else { throw ScrcpyError.unknownCodec(raw) }
            return codec
        }
    }

    /// Returns nil when the stream ends.
    public func nextPacket() throws -> StreamPacket? {
        let header: [UInt8]
        do {
            header = [UInt8](try source.readExactly(ScrcpyProtocol.packetHeaderLength))
        } catch ADBError.endOfStream {
            return nil
        }

        if header[0] & 0x80 != 0 {
            return .session(width: Int(Self.u32(header, 4)), height: Int(Self.u32(header, 8)),
                            clientResized: header[3] & 0x01 != 0)
        }

        let ptsAndFlags = UInt64(Self.u32(header, 0)) << 32 | UInt64(Self.u32(header, 4))
        let size = Int(Self.u32(header, 8))
        guard size > 0, size <= ScrcpyProtocol.maxPacketSize else {
            throw ScrcpyError.malformedPacket("packet size \(size)")
        }
        let isConfig = ptsAndFlags & (1 << 62) != 0
        return .media(MediaPacket(
            pts: isConfig ? nil : ptsAndFlags & ((1 << 61) - 1),
            isConfig: isConfig,
            isKeyFrame: ptsAndFlags & (1 << 61) != 0,
            payload: try source.readExactly(size)))
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
