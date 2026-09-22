import AppKit
import MirrorKit
import ScrcpyKit
import SwiftUI
import VideoKit

/// Where the mirror view's mouse activity goes. Points have a top-left
/// origin in view coordinates.
@MainActor
protocol MirrorInputSink: AnyObject {
    func videoSizeChanged(width: Int, height: Int)
    func primaryDown(at point: CGPoint, in viewSize: CGSize)
    func primaryDragged(to point: CGPoint, in viewSize: CGSize)
    func primaryUp(at point: CGPoint, in viewSize: CGSize)
    func hover(at point: CGPoint, in viewSize: CGSize)
    func scroll(at point: CGPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool)
    func secondaryDown(_ button: MouseTranslator.SecondaryButton)
    func secondaryUp(_ button: MouseTranslator.SecondaryButton)
    /// Text as typed, including what the Mac's input method composed.
    func insertText(_ text: String)
    func perform(_ command: KeyCommand)
}

/// Shows the video with a status line until the first frame and short toasts,
/// and forwards mouse activity to the input sink.
final class MirrorView: NSView, @preconcurrency NSTextInputClient {
    let renderer = VideoLayerRenderer()
    var input: MirrorInputSink?
    /// Text the input method is still composing (shown underlined in a text
    /// view); sent only once it is committed.
    private var marked = ""

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let toast = NSHostingView(rootView: ToastView(text: ""))
    private let recordingBadge = NSHostingView(rootView: RecordingBadge(text: ""))
    private var toastGeneration = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Rounded like a phone screen, with a faint edge against the glass frame.
        layer?.cornerRadius = 22
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // Below the subviews' layers, so the labels draw over the video.
        layer?.insertSublayer(renderer.layer, at: 0)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        toast.isHidden = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toast)

        recordingBadge.isHidden = true
        recordingBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordingBadge)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),

            toast.centerXAnchor.constraint(equalTo: centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            toast.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),

            recordingBadge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            recordingBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // No implicit animation, or the video lags behind a live resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = bounds
        CATransaction.commit()
    }

    /// Pass nil to hide the status line.
    func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    /// Pass nil to hide the red recording badge.
    func setRecordingBadge(_ text: String?) {
        recordingBadge.rootView = RecordingBadge(text: text ?? "")
        recordingBadge.isHidden = text == nil
    }

    /// Shows a message over the video for a couple of seconds.
    func showToast(_ text: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast.rootView = ToastView(text: text)
        toast.alphaValue = 1
        toast.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            // A newer toast owns the view now.
            guard let self, generation == toastGeneration else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.toast.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, generation == self.toastGeneration else { return }
                    self.toast.isHidden = true
                }
            }
        }
    }

    /// Call with the size of every new video session.
    func setVideoSize(width: Int, height: Int) {
        input?.videoSizeChanged(width: width, height: height)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let command = Self.shortcut(for: event) {
            input?.perform(command)
            return
        }
        // Lets the active input method (Telex, VNI, …) compose characters.
        interpretKeyEvents([event])
    }

    private static func shortcut(for event: NSEvent) -> KeyCommand? {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return .copy
        case "x": return .cut
        case "v": return .paste(NSPasteboard.general.string(forType: .string) ?? "")
        case "a": return .selectAll
        case "z": return event.modifierFlags.contains(.shift) ? .redo : .undo
        default: return nil
        }
    }

    override func doCommand(by selector: Selector) {
        let commands: [Selector: KeyCommand] = [
            #selector(insertNewline(_:)): .enter, #selector(insertLineBreak(_:)): .enter,
            #selector(deleteBackward(_:)): .backspace, #selector(deleteForward(_:)): .forwardDelete,
            #selector(insertTab(_:)): .tab, #selector(cancelOperation(_:)): .escape,
            #selector(moveUp(_:)): .up, #selector(moveDown(_:)): .down,
            #selector(moveLeft(_:)): .left, #selector(moveRight(_:)): .right,
            #selector(moveToBeginningOfLine(_:)): .home, #selector(moveToEndOfLine(_:)): .end,
            #selector(moveToBeginningOfDocument(_:)): .home, #selector(moveToEndOfDocument(_:)): .end,
            #selector(pageUp(_:)): .pageUp, #selector(pageDown(_:)): .pageDown,
            #selector(scrollPageUp(_:)): .pageUp, #selector(scrollPageDown(_:)): .pageDown,
        ]
        if let command = commands[selector] { input?.perform(command) }
    }

    // NSTextInputClient: no text is stored here, the phone owns the field.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // The input method may replace characters it committed earlier.
        if replacementRange.location != NSNotFound, replacementRange.length > 0 {
            for _ in 0..<replacementRange.length { input?.perform(.backspace) }
        }
        marked = ""
        input?.insertText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func unmarkText() {
        marked = ""
    }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Puts the input method's candidate window near the bottom of the screen.
        window?.convertToScreen(convert(NSRect(x: bounds.midX, y: 40, width: 1, height: 20), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Mouse

    override var acceptsFirstResponder: Bool { true }
    // Drags here are touches, not a way to move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        input?.primaryDown(at: location(of: event), in: bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        input?.primaryDragged(to: location(of: event), in: bounds.size)
    }

    override func mouseUp(with event: NSEvent) {
        input?.primaryUp(at: location(of: event), in: bounds.size)
    }

    override func mouseMoved(with event: NSEvent) {
        input?.hover(at: location(of: event), in: bounds.size)
    }

    override func rightMouseDown(with event: NSEvent) {
        input?.secondaryDown(.right)
    }

    override func rightMouseUp(with event: NSEvent) {
        input?.secondaryUp(.right)
    }

    override func otherMouseDown(with event: NSEvent) {
        if let button = Self.secondaryButton(for: event) { input?.secondaryDown(button) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if let button = Self.secondaryButton(for: event) { input?.secondaryUp(button) }
    }

    override func scrollWheel(with event: NSEvent) {
        input?.scroll(at: location(of: event), in: bounds.size, deltaX: event.scrollingDeltaX,
                      deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas)
    }

    /// Top-left origin like the phone's screen. Converted by hand instead of
    /// flipping the view, which would also flip the hosted video layer.
    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private static func secondaryButton(for event: NSEvent) -> MouseTranslator.SecondaryButton? {
        switch event.buttonNumber {
        case 2: return .middle
        case 3: return .fourth
        case 4: return .fifth
        default: return nil
        }
    }
}
