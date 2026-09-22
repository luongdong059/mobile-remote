import CoreMedia
import Foundation

public enum VideoKitError: Error, CustomStringConvertible {
    case missingParameterSets
    case emptyFrame
    case coreMedia(operation: String, status: OSStatus)
    case decodeFailed(OSStatus)
    case imageEncodingFailed

    public var description: String {
        switch self {
        case .missingParameterSets: return "config packet has no usable parameter sets"
        case .emptyFrame: return "packet contains no frame data"
        case .coreMedia(let operation, let status): return "\(operation) failed (\(status))"
        case .decodeFailed(let status): return "decode failed (\(status))"
        case .imageEncodingFailed: return "could not encode image"
        }
    }
}

public enum SampleBuffers {
    /// Builds the format description from a config packet (SPS/PPS, plus VPS for HEVC).
    public static func formatDescription(
        codec: VideoCodecKind, configPayload: Data
    ) throws -> CMVideoFormatDescription {
        let sets = AnnexB.nalUnits(in: configPayload).filter { AnnexB.isParameterSet($0, codec: codec) }
        guard sets.count >= (codec == .h264 ? 2 : 3) else { throw VideoKitError.missingParameterSets }

        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var description: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else {
            throw VideoKitError.coreMedia(operation: "create format description", status: status)
        }
        return description
    }

    /// Wraps one Annex B frame as a sample buffer ready for decoding.
    public static func sampleBuffer(
        codec: VideoCodecKind, payload: Data, ptsMicroseconds: UInt64, format: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        let frame = AnnexB.avcc(from: payload, codec: codec)
        guard !frame.isEmpty else { throw VideoKitError.emptyFrame }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: frame.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else {
            throw VideoKitError.coreMedia(operation: "create block buffer", status: status)
        }
        status = frame.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: frame.count)
        }
        guard status == kCMBlockBufferNoErr else {
            throw VideoKitError.coreMedia(operation: "fill block buffer", status: status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = frame.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw VideoKitError.coreMedia(operation: "create sample buffer", status: status)
        }

        return sample
    }
}
