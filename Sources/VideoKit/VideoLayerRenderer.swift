import CoreMedia
import CoreVideo
import QuartzCore

/// Decodes every frame itself and shows the newest picture in a plain layer.
///
/// Compared with handing compressed frames to `AVSampleBufferDisplayLayer`,
/// nothing is queued or paced out of sight: each frame is decoded in stream
/// order, decode errors surface as thrown errors, and the latest picture wins.
public final class VideoLayerRenderer: @unchecked Sendable {
    public let layer: CALayer
    private var decoder: FrameDecoder?

    public init() {
        layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Call for every config packet, from the thread that calls `render`.
    public func configure(format: CMVideoFormatDescription) throws {
        decoder = try FrameDecoder(format: format,
                                   pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, realTime: true)
    }

    /// Decodes and shows one frame. When this throws, the decoder has lost its
    /// reference and the stream must restart from a key frame.
    public func render(_ sample: CMSampleBuffer) throws {
        guard let decoder else { throw VideoKitError.missingParameterSets }
        try present(try decoder.decode(sample))
    }

    /// Shows an already decoded picture (must be IOSurface backed, which
    /// VideoToolbox and AVCapture output both are).
    public func present(_ image: CVPixelBuffer) throws {
        guard let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
            throw VideoKitError.decodeFailed(kCVReturnInvalidPixelFormat)
        }
        // Off the main thread on purpose: a busy main thread must not delay
        // frames. An explicit, flushed transaction makes that safe.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()
        CATransaction.flush()
    }
}
