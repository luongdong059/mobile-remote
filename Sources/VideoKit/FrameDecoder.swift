import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Synchronous hardware decode, one frame in, one picture out, in stream order.
public final class FrameDecoder {
    private let session: VTDecompressionSession

    /// BGRA suits image export; live display asks for the decoder's native
    /// YCbCr and `realTime`. Output is always IOSurface backed.
    public init(format: CMVideoFormatDescription, pixelFormat: OSType = kCVPixelFormatType_32BGRA,
                realTime: Bool = false) throws {
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else {
            throw VideoKitError.coreMedia(operation: "create decompression session", status: status)
        }
        if realTime {
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        self.session = session
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    public func decode(_ sample: CMSampleBuffer) throws -> CVPixelBuffer {
        final class Output: @unchecked Sendable {
            var status: OSStatus = noErr
            var image: CVImageBuffer?
        }
        let output = Output()
        // No async flag: the handler runs before this call returns.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            output.status = status
            output.image = image
        }
        guard status == noErr, output.status == noErr, let image = output.image else {
            throw VideoKitError.decodeFailed(status != noErr ? status : output.status)
        }
        return image
    }

    public static func writePNG(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
        try pngData(pixelBuffer).write(to: url)
    }

    /// Works for any pixel format Core Image reads, including 4:2:0 YCbCr.
    public static func pngData(_ pixelBuffer: CVPixelBuffer) throws -> Data {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let data = NSMutableData()
        guard let rendered = CIContext().createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw VideoKitError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw VideoKitError.imageEncodingFailed }
        return data as Data
    }
}
