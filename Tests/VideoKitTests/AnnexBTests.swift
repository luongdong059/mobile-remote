import CoreMedia
import Foundation
import Testing
@testable import VideoKit

@Suite struct AnnexBTests {
    @Test func splitsOnThreeAndFourByteStartCodes() {
        let data = Data([0, 0, 0, 1, 0x67, 0xaa, 0, 0, 1, 0x68, 0xbb, 0xcc, 0, 0, 0, 1, 0x65, 0x01])
        #expect(AnnexB.nalUnits(in: data) == [Data([0x67, 0xaa]), Data([0x68, 0xbb, 0xcc]), Data([0x65, 0x01])])
    }

    @Test func dataWithoutAStartCodeHasNoUnits() {
        #expect(AnnexB.nalUnits(in: Data([0x65, 0x01, 0x02])).isEmpty)
        #expect(AnnexB.nalUnits(in: Data()).isEmpty)
    }

    @Test func recognisesParameterSets() {
        #expect(AnnexB.isParameterSet(Data([0x67]), codec: .h264)) // SPS
        #expect(AnnexB.isParameterSet(Data([0x68]), codec: .h264)) // PPS
        #expect(!AnnexB.isParameterSet(Data([0x65]), codec: .h264)) // IDR slice
        #expect(AnnexB.isParameterSet(Data([0x40, 0x01]), codec: .hevc)) // VPS (32)
        #expect(AnnexB.isParameterSet(Data([0x42, 0x01]), codec: .hevc)) // SPS (33)
        #expect(AnnexB.isParameterSet(Data([0x44, 0x01]), codec: .hevc)) // PPS (34)
        #expect(!AnnexB.isParameterSet(Data([0x26, 0x01]), codec: .hevc)) // IDR_W_RADL (19)
    }

    @Test func avccPrefixesLengthsAndDropsParameterSets() {
        let data = Data([0, 0, 0, 1, 0x67, 0xaa, 0, 0, 0, 1, 0x68, 0xbb, 0, 0, 0, 1, 0x65, 0x01, 0x02])
        #expect(AnnexB.avcc(from: data, codec: .h264) == Data([0, 0, 0, 3, 0x65, 0x01, 0x02]))
    }

    @Test func slicedDataIsHandled() {
        let padded = Data([0xff, 0xff, 0, 0, 1, 0x65, 0x07])
        #expect(AnnexB.nalUnits(in: padded.dropFirst(2)) == [Data([0x65, 0x07])])
    }

    @Test func configWithoutParameterSetsIsRejected() {
        #expect(throws: VideoKitError.self) {
            try SampleBuffers.formatDescription(codec: .h264, configPayload: Data([0, 0, 0, 1, 0x65, 0x01]))
        }
    }
}
