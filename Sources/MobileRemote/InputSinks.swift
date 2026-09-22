import AppleDeviceKit
import Foundation
import CoreGraphics
import MirrorKit
import ScrcpyKit

/// Mouse → scrcpy control messages.
@MainActor
final class AndroidInputSink: MirrorInputSink {
    private let pipeline: MirrorPipeline
    private var translator = MouseTranslator()

    init(pipeline: MirrorPipeline) {
        self.pipeline = pipeline
    }

    func videoSizeChanged(width: Int, height: Int) {
        let mapper = VideoPointMapper(videoWidth: width, videoHeight: height)
        // A refreshed session of the same size must not disturb a held touch.
        guard mapper != translator.mapper else { return }
        // A touch held across a rotation would otherwise never be released.
        pipeline.send(translator.cancelTouch())
        translator.mapper = mapper
    }

    func primaryDown(at point: CGPoint, in viewSize: CGSize) {
        pipeline.send(translator.primaryDown(at: point, in: viewSize))
    }

    func primaryDragged(to point: CGPoint, in viewSize: CGSize) {
        pipeline.send(translator.primaryDragged(to: point, in: viewSize))
    }

    func primaryUp(at point: CGPoint, in viewSize: CGSize) {
        pipeline.send(translator.primaryUp(at: point, in: viewSize))
    }

    func hover(at point: CGPoint, in viewSize: CGSize) {
        pipeline.send(translator.hover(at: point, in: viewSize))
    }

    func scroll(at point: CGPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) {
        pipeline.send(translator.scroll(at: point, in: viewSize, deltaX: deltaX, deltaY: deltaY, isPrecise: isPrecise))
    }

    func secondaryDown(_ button: MouseTranslator.SecondaryButton) {
        pipeline.send(translator.secondaryDown(button))
    }

    func secondaryUp(_ button: MouseTranslator.SecondaryButton) {
        pipeline.send(translator.secondaryUp(button))
    }
}

/// Mouse → WebDriverAgent gestures. Right button = Home. No hover: iOS has
/// no pointer to move.
@MainActor
final class IOSInputSink: MirrorInputSink {
    private let controller: IOSInputController
    private var translator = IOSTouchTranslator()
    /// Wheel ticks arrive many times a second and each swipe costs ~1.5 s,
    /// so ticks are pooled for a moment and sent as one swipe.
    private var pendingScroll: (point: CGPoint, viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool)?
    private var scrollFlush: DispatchWorkItem?
    static let scrollPoolInterval: TimeInterval = 0.15

    init(controller: IOSInputController) {
        self.controller = controller
    }

    func videoSizeChanged(width: Int, height: Int) {
        translator.cancel()
        translator.mapper = VideoPointMapper(videoWidth: width, videoHeight: height)
    }

    func primaryDown(at point: CGPoint, in viewSize: CGSize) {
        translator.primaryDown(at: point, in: viewSize)
    }

    func primaryDragged(to point: CGPoint, in viewSize: CGSize) {
        translator.primaryDragged(to: point, in: viewSize)
    }

    func primaryUp(at point: CGPoint, in viewSize: CGSize) {
        if let gesture = translator.primaryUp(at: point, in: viewSize) { controller.performGesture(gesture) }
    }

    func hover(at point: CGPoint, in viewSize: CGSize) {}

    func scroll(at point: CGPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) {
        if var pending = pendingScroll, pending.isPrecise == isPrecise {
            pending.deltaX += deltaX
            pending.deltaY += deltaY
            pending.point = point
            pendingScroll = pending
        } else {
            flushScroll()
            pendingScroll = (point, viewSize, deltaX, deltaY, isPrecise)
        }
        scrollFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushScroll() }
        }
        scrollFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollPoolInterval, execute: flush)
    }

    private func flushScroll() {
        scrollFlush?.cancel()
        scrollFlush = nil
        guard let pending = pendingScroll else { return }
        pendingScroll = nil
        if let gesture = translator.scroll(at: pending.point, in: pending.viewSize, deltaX: pending.deltaX,
                                           deltaY: pending.deltaY, isPrecise: pending.isPrecise) {
            controller.performGesture(gesture)
        }
    }

    func secondaryDown(_ button: MouseTranslator.SecondaryButton) {
        if button == .right { controller.pressButton("home") }
    }

    func secondaryUp(_ button: MouseTranslator.SecondaryButton) {}
}
