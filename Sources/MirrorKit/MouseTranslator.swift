import CoreGraphics
import ScrcpyKit

/// Turns mouse activity over the mirror view into control messages, following
/// scrcpy's own bindings: left button = finger, right = Back, middle = Home,
/// 4th = app switcher, 5th = notification panel.
///
/// Points are in view coordinates with a top-left origin.
public struct MouseTranslator {
    public enum SecondaryButton: Sendable {
        case right, middle, fourth, fifth
    }

    /// Nil until the first session packet; nothing is sent before that.
    public var mapper: VideoPointMapper?
    private var isTouching = false

    /// Trackpad points per wheel tick. Android scrolls ~64 dp per tick, and a
    /// phone-sized window shows roughly 1 dp per point, so this runs a little
    /// faster than the fingers (SDL's 10 makes scrcpy scroll far too fast).
    static let pointsPerTick: CGFloat = 40

    public init() {}

    // MARK: Left button → touch

    public mutating func primaryDown(at point: CGPoint, in viewSize: CGSize) -> [ControlMessage] {
        // A press in the letterbox is not a touch.
        guard let mapped = mapper?.map(point, in: viewSize), mapped.isInside else { return [] }
        isTouching = true
        return [.injectTouch(action: .down, pointerID: PointerID.mouse, position: mapped.position,
                             pressure: 1, actionButton: .primary, buttons: .primary)]
    }

    public func primaryDragged(to point: CGPoint, in viewSize: CGSize) -> [ControlMessage] {
        // Drags may leave the video; the position is clamped to its edge.
        guard isTouching, let mapped = mapper?.map(point, in: viewSize) else { return [] }
        return [.injectTouch(action: .move, pointerID: PointerID.mouse, position: mapped.position,
                             pressure: 1, buttons: .primary)]
    }

    public mutating func primaryUp(at point: CGPoint, in viewSize: CGSize) -> [ControlMessage] {
        guard isTouching, let mapped = mapper?.map(point, in: viewSize) else { return [] }
        isTouching = false
        return [.injectTouch(action: .up, pointerID: PointerID.mouse, position: mapped.position,
                             pressure: 0, actionButton: .primary)]
    }

    /// Ends a touch whose button-up will never arrive (rotation, lost focus).
    public mutating func cancelTouch() -> [ControlMessage] {
        guard isTouching, let mapper else { return [] }
        isTouching = false
        let origin = ScreenPosition(x: 0, y: 0, screenWidth: UInt16(mapper.videoWidth),
                                    screenHeight: UInt16(mapper.videoHeight))
        return [.injectTouch(action: .cancel, pointerID: PointerID.mouse, position: origin, pressure: 0)]
    }

    // MARK: Pointer without buttons

    public func hover(at point: CGPoint, in viewSize: CGSize) -> [ControlMessage] {
        guard !isTouching, let mapped = mapper?.map(point, in: viewSize), mapped.isInside else { return [] }
        return [.injectTouch(action: .hoverMove, pointerID: PointerID.mouse, position: mapped.position, pressure: 1)]
    }

    /// `deltaX` / `deltaY` as reported by AppKit's `scrollingDelta`.
    public func scroll(at point: CGPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat,
                       isPrecise: Bool) -> [ControlMessage] {
        guard let mapped = mapper?.map(point, in: viewSize), mapped.isInside else { return [] }
        // Trackpads report points, wheels report ticks. AppKit's horizontal
        // axis is the opposite of Android's.
        let divisor = isPrecise ? Self.pointsPerTick : 1
        let horizontal = Float(-deltaX / divisor)
        let vertical = Float(deltaY / divisor)
        guard horizontal != 0 || vertical != 0 else { return [] }
        return [.injectScroll(position: mapped.position, horizontal: horizontal, vertical: vertical,
                              buttons: isTouching ? .primary : [])]
    }

    // MARK: Other buttons → navigation

    public func secondaryDown(_ button: SecondaryButton) -> [ControlMessage] {
        switch button {
        case .right: return [.backOrScreenOn(action: .down)]
        case .middle: return [.injectKeycode(action: .down, keycode: AndroidKeycode.home.rawValue)]
        case .fourth: return [.injectKeycode(action: .down, keycode: AndroidKeycode.appSwitch.rawValue)]
        case .fifth: return [.expandNotificationPanel]
        }
    }

    public func secondaryUp(_ button: SecondaryButton) -> [ControlMessage] {
        switch button {
        case .right: return [.backOrScreenOn(action: .up)]
        case .middle: return [.injectKeycode(action: .up, keycode: AndroidKeycode.home.rawValue)]
        case .fourth: return [.injectKeycode(action: .up, keycode: AndroidKeycode.appSwitch.rawValue)]
        case .fifth: return []
        }
    }
}
