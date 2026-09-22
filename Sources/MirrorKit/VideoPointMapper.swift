import CoreGraphics
import ScrcpyKit

public struct MappedPoint: Equatable, Sendable {
    /// In video pixels, clamped onto the video.
    public let position: ScreenPosition
    /// False when the point was in the letterbox around the video.
    public let isInside: Bool
}

/// Maps view coordinates (top-left origin, points) onto the aspect-fitted
/// video. Working in ratios makes the Retina scale factor irrelevant.
public struct VideoPointMapper: Equatable, Sendable {
    public let videoWidth: Int
    public let videoHeight: Int

    /// The size must be the one from the latest session packet: the server
    /// silently drops positional events generated for any other size.
    public init?(videoWidth: Int, videoHeight: Int) {
        guard (1...Int(UInt16.max)).contains(videoWidth), (1...Int(UInt16.max)).contains(videoHeight) else {
            return nil
        }
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
    }

    /// Where the video sits inside a view of `viewSize`.
    public func videoRect(in viewSize: CGSize) -> CGRect {
        let scale = min(viewSize.width / CGFloat(videoWidth), viewSize.height / CGFloat(videoHeight))
        let size = CGSize(width: CGFloat(videoWidth) * scale, height: CGFloat(videoHeight) * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public func map(_ point: CGPoint, in viewSize: CGSize) -> MappedPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let rect = videoRect(in: viewSize)
        let x = ((point.x - rect.minX) / rect.width * CGFloat(videoWidth)).rounded(.down)
        let y = ((point.y - rect.minY) / rect.height * CGFloat(videoHeight)).rounded(.down)
        return MappedPoint(
            position: ScreenPosition(
                x: Int32(min(max(x, 0), CGFloat(videoWidth - 1))),
                y: Int32(min(max(y, 0), CGFloat(videoHeight - 1))),
                screenWidth: UInt16(videoWidth), screenHeight: UInt16(videoHeight)),
            isInside: rect.contains(point))
    }
}
