import ADBKit
import Foundation
import Testing
@testable import ScrcpyKit

/// Serves a fixed byte string, like a socket that then reaches end of stream.
final class DataByteSource: ByteSource {
    private var remaining: Data

    init(_ bytes: [UInt8]) {
        remaining = Data(bytes)
    }

    func readExactly(_ count: Int) throws -> Data {
        guard remaining.count >= count else { throw ADBError.endOfStream }
        defer { remaining = Data(remaining.dropFirst(count)) }
        return Data(remaining.prefix(count))
    }
}

@Suite struct StreamDemuxerTests {
    static let h264: [UInt8] = [0x68, 0x32, 0x36, 0x34]

    @Test func parsesAV4Stream() throws {
        let demuxer = StreamDemuxer(source: DataByteSource(
            Self.h264
            + [0x80, 0, 0, 0, 0, 0, 0x04, 0x38, 0, 0, 0x09, 0x24] // session 1080x2340
            + [0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0xaa, 0xbb, 0xcc] // config
            + [0x20, 0, 0, 0, 0, 0, 0x03, 0xe8, 0, 0, 0, 2, 0x01, 0x02] // key frame, pts 1000
            + [0x00, 0, 0, 0, 0, 0, 0x07, 0xd0, 0, 0, 0, 1, 0x03] // frame, pts 2000
        ))

        #expect(try demuxer.readCodec() == .h264)
        #expect(try demuxer.nextPacket() == .session(width: 1080, height: 2340, clientResized: false))
        #expect(try demuxer.nextPacket() == .media(MediaPacket(
            pts: nil, isConfig: true, isKeyFrame: false, payload: Data([0xaa, 0xbb, 0xcc]))))
        #expect(try demuxer.nextPacket() == .media(MediaPacket(
            pts: 1000, isConfig: false, isKeyFrame: true, payload: Data([0x01, 0x02]))))
        #expect(try demuxer.nextPacket() == .media(MediaPacket(
            pts: 2000, isConfig: false, isKeyFrame: false, payload: Data([0x03]))))
        #expect(try demuxer.nextPacket() == nil)
    }

    @Test func sessionPacketCarriesTheClientResizedFlag() throws {
        let demuxer = StreamDemuxer(source: DataByteSource([0x80, 0, 0, 0x01, 0, 0, 0x02, 0x4e, 0, 0, 0x05, 0x00]))
        #expect(try demuxer.nextPacket() == .session(width: 590, height: 1280, clientResized: true))
    }

    @Test func ptsKeepsAll61Bits() throws {
        let demuxer = StreamDemuxer(source: DataByteSource(
            [0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 1, 0x00]))
        guard case .media(let media)? = try demuxer.nextPacket() else {
            Issue.record("expected a media packet")
            return
        }
        #expect(media.pts == (1 << 61) - 1)
        #expect(media.isKeyFrame)
        #expect(!media.isConfig)
    }

    @Test func codecIdsZeroAndOneAreErrors() {
        #expect(throws: ScrcpyError.streamDisabled) {
            try StreamDemuxer(source: DataByteSource([0, 0, 0, 0])).readCodec()
        }
        #expect(throws: ScrcpyError.streamConfigurationFailed) {
            try StreamDemuxer(source: DataByteSource([0, 0, 0, 1])).readCodec()
        }
        #expect(throws: ScrcpyError.unknownCodec(0x1234_5678)) {
            try StreamDemuxer(source: DataByteSource([0x12, 0x34, 0x56, 0x78])).readCodec()
        }
    }

    @Test func rejectsAbsurdPacketSizes() {
        let demuxer = StreamDemuxer(source: DataByteSource([0, 0, 0, 0, 0, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff]))
        #expect(throws: ScrcpyError.self) { try demuxer.nextPacket() }
    }

    @Test func truncatedPayloadIsAnErrorNotACleanEnd() {
        let demuxer = StreamDemuxer(source: DataByteSource([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0x01]))
        #expect(throws: ADBError.endOfStream) { try demuxer.nextPacket() }
    }
}

@Suite struct ScrcpyServerOptionsTests {
    @Test func defaultsSendOnlyWhatDiffersFromTheServer() {
        let options = ScrcpyServerOptions(scid: 0x0123_abcd)
        #expect(options.socketName == "scrcpy_0123abcd")
        #expect(options.arguments() == [
            "scid=0123abcd", "log_level=info", "tunnel_forward=true", "audio=false", "max_fps=60",
        ])
    }

    @Test func customOptions() {
        var options = ScrcpyServerOptions(scid: 1)
        options.videoCodec = .h265
        options.maxSize = 1280
        options.videoBitRate = 4_000_000
        options.powerOn = false
        options.extra = ["new_display": "1920x1080/240"]
        #expect(options.arguments() == [
            "scid=00000001", "log_level=info", "tunnel_forward=true", "audio=false", "video_codec=h265",
            "video_bit_rate=4000000", "max_size=1280", "max_fps=60", "power_on=false",
            "new_display=1920x1080/240",
        ])
    }

    @Test func scidIsLimitedTo31Bits() {
        #expect(ScrcpyServerOptions(scid: 0xffff_ffff).scid == 0x7fff_ffff)
    }

    @Test func shellCommandQuotesUnsafeWords() {
        var options = ScrcpyServerOptions(scid: 1)
        options.extra = ["video_codec_options": "profile=1;level=2"]
        let command = options.shellCommand()
        #expect(command.hasPrefix(
            "CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 "))
        #expect(command.hasSuffix("'video_codec_options=profile=1;level=2'"))
    }

    @Test func bundledServerMatchesThePinnedDigest() throws {
        #expect(try ServerBinary.load().count == 733_706)
    }
}
