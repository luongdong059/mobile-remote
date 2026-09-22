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
    /// While a trackpad pinch is in progress: the anchor under the pointer
    /// and the current spread factor.
    private var pinch: (anchor: CGPoint, scale: CGFloat)?

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

    // MARK: Trackpad pinch → two fingers

    /// Like scrcpy's Ctrl+click: one finger under the pointer, a virtual
    /// finger mirrored through the screen centre, both moving apart or
    /// together as the pinch changes.
    public mutating func pinchBegan(at point: CGPoint, in viewSize: CGSize) -> [ControlMessage] {
        guard !isTouching, let mapped = mapper?.map(point, in: viewSize), mapped.isInside else { return [] }
        let anchor = CGPoint(x: CGFloat(mapped.position.x), y: CGFloat(mapped.position.y))
        pinch = (anchor, 1)
        return fingers(action: .down)
    }

    /// `magnification` is AppKit's per-event delta (0.1 = 10 % larger).
    public mutating func pinchChanged(by magnification: CGFloat) -> [ControlMessage] {
        guard pinch != nil else { return [] }
        pinch!.scale = max(0.2, pinch!.scale * (1 + magnification))
        return fingers(action: .move)
    }

    public mutating func pinchEnded() -> [ControlMessage] {
        guard pinch != nil else { return [] }
        defer { pinch = nil }
        return fingers(action: .up)
    }

    private func fingers(action: TouchAction) -> [ControlMessage] {
        guard let pinch, let mapper else { return [] }
        let centre = CGPoint(x: CGFloat(mapper.videoWidth) / 2, y: CGFloat(mapper.videoHeight) / 2)
        // Both fingers sit on the line through the centre, `scale` times as far out.
        let dx = (pinch.anchor.x - centre.x) * pinch.scale, dy = (pinch.anchor.y - centre.y) * pinch.scale
        let first = clamp(CGPoint(x: centre.x + dx, y: centre.y + dy), mapper)
        let second = clamp(CGPoint(x: centre.x - dx, y: centre.y - dy), mapper)
        let pressure: Float = action == .up ? 0 : 1
        let buttons: MouseButtons = action == .up ? [] : .primary
        return [
            .injectTouch(action: action, pointerID: PointerID.mouse, position: first, pressure: pressure,
                         actionButton: action == .move ? [] : .primary, buttons: buttons),
            .injectTouch(action: action, pointerID: PointerID.virtualFinger, position: second, pressure: pressure,
                         actionButton: action == .move ? [] : .primary, buttons: buttons),
        ]
    }

    private func clamp(_ point: CGPoint, _ mapper: VideoPointMapper) -> ScreenPosition {
        ScreenPosition(x: Int32(min(max(point.x, 0), CGFloat(mapper.videoWidth - 1))),
                       y: Int32(min(max(point.y, 0), CGFloat(mapper.videoHeight - 1))),
                       screenWidth: UInt16(mapper.videoWidth), screenHeight: UInt16(mapper.videoHeight))
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
