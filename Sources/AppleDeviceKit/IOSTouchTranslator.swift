import CoreGraphics
import Foundation
import MirrorKit

/// Turns mouse activity over the mirror into WebDriverAgent gestures.
///
/// WebDriverAgent replays a gesture as a whole, so a drag is collected while
/// the button is down and sent on release, with its timing kept. That costs
/// the live feedback a real finger gives, but every tap, swipe and long
/// press lands as one gesture with the right speed.
///
/// Every pointer move has a fixed cost in WebDriverAgent (a 49-move drag
/// took 31 s before tuning), so the path is thinned to a few waypoints
/// before it is sent.
public struct IOSTouchTranslator {
    public var mapper: VideoPointMapper?
    private var samples: [(pixels: CGPoint, delay: TimeInterval)] = []
    private var lastSample: Date?

    /// Mouse moves closer than this (in video pixels) are not worth a sample.
    static let minimumStep: CGFloat = 4
    /// Waypoints kept per gesture besides the start. With snapshots off each
    /// costs ~0.05 s on top of ~0.4 s per gesture (0.45 s each with them on).
    static let maxMoves = 4
    /// A drag slower than this is replayed at this speed.
    static let maxGestureDuration: TimeInterval = 1.5
    /// Pixels moved by one wheel tick / point of trackpad travel.
    static let scrollPixelsPerTick: CGFloat = 180
    static let scrollPixelsPerPoint: CGFloat = 4.5

    public init() {}

    public mutating func primaryDown(at point: CGPoint, in viewSize: CGSize) {
        guard let mapped = mapper?.map(point, in: viewSize), mapped.isInside else { return }
        samples = [(CGPoint(x: Int(mapped.position.x), y: Int(mapped.position.y)), 0)]
        lastSample = Date()
    }

    public mutating func primaryDragged(to point: CGPoint, in viewSize: CGSize) {
        guard !samples.isEmpty, let mapped = mapper?.map(point, in: viewSize) else { return }
        let pixels = CGPoint(x: Int(mapped.position.x), y: Int(mapped.position.y))
        guard let last = samples.last, hypot(pixels.x - last.pixels.x, pixels.y - last.pixels.y) >= Self.minimumStep else { return }
        let now = Date()
        samples.append((pixels, now.timeIntervalSince(lastSample ?? now)))
        lastSample = now
    }

    /// The finished gesture, or nil when no press was in progress.
    public mutating func primaryUp(at point: CGPoint, in viewSize: CGSize) -> [(pixels: CGPoint, delay: TimeInterval)]? {
        guard !samples.isEmpty else { return nil }
        defer { samples = []; lastSample = nil }
        if let mapped = mapper?.map(point, in: viewSize), let last = samples.last,
           mapped.position.x != Int32(last.pixels.x) || mapped.position.y != Int32(last.pixels.y) {
            let now = Date()
            samples.append((CGPoint(x: Int(mapped.position.x), y: Int(mapped.position.y)), now.timeIntervalSince(lastSample ?? now)))
        } else if samples.count > 1, let last = samples.last {
            // Holding still before release: keep the hold time.
            samples.append((last.pixels, Date().timeIntervalSince(lastSample ?? Date())))
        } else if samples.count == 1, let start = lastSample, Date().timeIntervalSince(start) > 0.4 {
            // A long press: same spot, held.
            samples.append((samples[0].pixels, Date().timeIntervalSince(start)))
        }
        return Self.thinned(samples)
    }

    /// Keeps the start, the end and up to `maxMoves - 1` evenly spaced points
    /// in between; the total duration is preserved, then capped.
    static func thinned(_ samples: [(pixels: CGPoint, delay: TimeInterval)]) -> [(pixels: CGPoint, delay: TimeInterval)] {
        guard samples.count > 2 else { return samples.map { ($0.pixels, min($0.delay, maxGestureDuration)) } }
        let total = min(samples.dropFirst().reduce(0) { $0 + $1.delay }, maxGestureDuration)
        let moves = min(maxMoves, samples.count - 1)
        var result = [samples[0]]
        for step in 1...moves {
            let index = Int((Double(step) / Double(moves) * Double(samples.count - 1)).rounded())
            result.append((samples[index].pixels, total / Double(moves)))
        }
        return result
    }

    public mutating func cancel() {
        samples = []
        lastSample = nil
    }

    /// A short swipe standing in for wheel / trackpad scrolling.
    public func scroll(at point: CGPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat,
                       isPrecise: Bool) -> [(pixels: CGPoint, delay: TimeInterval)]? {
        guard let mapped = mapper?.map(point, in: viewSize), mapped.isInside, let mapper else { return nil }
        let unit = isPrecise ? Self.scrollPixelsPerPoint : Self.scrollPixelsPerTick
        // Wheel "down" (content up) means the finger moves up the screen.
        let dx = deltaX * unit, dy = deltaY * unit
        guard abs(dx) + abs(dy) >= Self.minimumStep else { return nil }
        let start = CGPoint(x: CGFloat(mapped.position.x), y: CGFloat(mapped.position.y))
        let end = CGPoint(x: min(max(start.x + dx, 0), CGFloat(mapper.videoWidth - 1)),
                          y: min(max(start.y + dy, 0), CGFloat(mapper.videoHeight - 1)))
        return [(start, 0), (end, 0.08), (end, 0.02)]
    }
}
