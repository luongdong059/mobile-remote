import CoreGraphics
import ScrcpyKit
import Testing
@testable import MirrorKit

@Suite struct VideoPointMapperTests {
    let mapper = VideoPointMapper(videoWidth: 1080, videoHeight: 2340)!

    @Test func rejectsSizesTheProtocolCannotCarry() {
        #expect(VideoPointMapper(videoWidth: 0, videoHeight: 100) == nil)
        #expect(VideoPointMapper(videoWidth: 100, videoHeight: 70_000) == nil)
    }

    @Test func exactFitMapsCornersAndCentre() {
        let view = CGSize(width: 540, height: 1170) // half scale, e.g. a Retina window
        #expect(mapper.map(CGPoint(x: 0, y: 0), in: view)?.position.x == 0)
        let centre = mapper.map(CGPoint(x: 270, y: 585), in: view)
        #expect(centre?.position == ScreenPosition(x: 540, y: 1170, screenWidth: 1080, screenHeight: 2340))
        #expect(centre?.isInside == true)
        // The far edge clamps to the last pixel instead of overflowing.
        let corner = mapper.map(CGPoint(x: 540, y: 1170), in: view)
        #expect(corner?.position.x == 1079)
        #expect(corner?.position.y == 2339)
    }

    @Test func letterboxedViewOffsetsTheVideo() {
        // A wide view: the video is 540 pt wide, centred, with 230 pt bars left and right.
        let view = CGSize(width: 1000, height: 1170)
        #expect(mapper.videoRect(in: view) == CGRect(x: 230, y: 0, width: 540, height: 1170))

        let inside = mapper.map(CGPoint(x: 230 + 135, y: 585), in: view)
        #expect(inside?.position.x == 270)
        #expect(inside?.isInside == true)

        let inTheBar = mapper.map(CGPoint(x: 100, y: 585), in: view)
        #expect(inTheBar?.isInside == false)
        #expect(inTheBar?.position.x == 0) // clamped onto the video edge
    }

    @Test func landscapeVideoInATallView() {
        let landscape = VideoPointMapper(videoWidth: 2340, videoHeight: 1080)!
        let view = CGSize(width: 1170, height: 1000)
        #expect(landscape.videoRect(in: view) == CGRect(x: 0, y: 230, width: 1170, height: 540))
        #expect(landscape.map(CGPoint(x: 585, y: 500), in: view)?.position.y == 540)
    }

    @Test func emptyViewMapsNothing() {
        #expect(mapper.map(.zero, in: .zero) == nil)
    }
}

@Suite struct MouseTranslatorTests {
    let view = CGSize(width: 540, height: 1170)

    private func translator() -> MouseTranslator {
        var translator = MouseTranslator()
        translator.mapper = VideoPointMapper(videoWidth: 1080, videoHeight: 2340)
        return translator
    }

    private func position(_ x: Int32, _ y: Int32) -> ScreenPosition {
        ScreenPosition(x: x, y: y, screenWidth: 1080, screenHeight: 2340)
    }

    @Test func nothingIsSentBeforeTheVideoSizeIsKnown() {
        var translator = MouseTranslator()
        #expect(translator.primaryDown(at: CGPoint(x: 10, y: 10), in: view).isEmpty)
        #expect(translator.hover(at: CGPoint(x: 10, y: 10), in: view).isEmpty)
    }

    @Test func clickBecomesTouchDownMoveUp() {
        var translator = translator()
        #expect(translator.primaryDown(at: CGPoint(x: 100, y: 200), in: view) == [
            .injectTouch(action: .down, pointerID: PointerID.mouse, position: position(200, 400),
                         pressure: 1, actionButton: .primary, buttons: .primary),
        ])
        #expect(translator.primaryDragged(to: CGPoint(x: 110, y: 250), in: view) == [
            .injectTouch(action: .move, pointerID: PointerID.mouse, position: position(220, 500),
                         pressure: 1, buttons: .primary),
        ])
        #expect(translator.primaryUp(at: CGPoint(x: 110, y: 250), in: view) == [
            .injectTouch(action: .up, pointerID: PointerID.mouse, position: position(220, 500),
                         pressure: 0, actionButton: .primary),
        ])
        // The touch is over: further drags and releases send nothing.
        #expect(translator.primaryDragged(to: CGPoint(x: 0, y: 0), in: view).isEmpty)
        #expect(translator.primaryUp(at: CGPoint(x: 0, y: 0), in: view).isEmpty)
    }

    @Test func pressInTheLetterboxIsIgnoredButDragsOutsideAreClamped() {
        var translator = translator()
        let wide = CGSize(width: 1000, height: 1170)
        #expect(translator.primaryDown(at: CGPoint(x: 50, y: 500), in: wide).isEmpty)
        #expect(translator.primaryDragged(to: CGPoint(x: 400, y: 500), in: wide).isEmpty)

        _ = translator.primaryDown(at: CGPoint(x: 500, y: 500), in: wide)
        #expect(translator.primaryDragged(to: CGPoint(x: -300, y: 500), in: wide) == [
            .injectTouch(action: .move, pointerID: PointerID.mouse, position: position(0, 1000),
                         pressure: 1, buttons: .primary),
        ])
    }

    @Test func hoverOnlyWhileNoButtonIsDown() {
        var translator = translator()
        #expect(translator.hover(at: CGPoint(x: 100, y: 200), in: view) == [
            .injectTouch(action: .hoverMove, pointerID: PointerID.mouse, position: position(200, 400), pressure: 1),
        ])
        _ = translator.primaryDown(at: CGPoint(x: 100, y: 200), in: view)
        #expect(translator.hover(at: CGPoint(x: 100, y: 200), in: view).isEmpty)
    }

    @Test func cancelReleasesAHeldTouchOnce() {
        var translator = translator()
        #expect(translator.cancelTouch().isEmpty)
        _ = translator.primaryDown(at: CGPoint(x: 100, y: 200), in: view)
        #expect(translator.cancelTouch() == [
            .injectTouch(action: .cancel, pointerID: PointerID.mouse, position: position(0, 0), pressure: 0),
        ])
        #expect(translator.cancelTouch().isEmpty)
    }

    @Test func trackpadScrollIsScaledAndWheelScrollIsNot() {
        let translator = translator()
        let point = CGPoint(x: 100, y: 200)
        #expect(translator.scroll(at: point, in: view, deltaX: 0, deltaY: 80, isPrecise: true) == [
            .injectScroll(position: position(200, 400), horizontal: 0, vertical: 2),
        ])
        // AppKit's horizontal axis is the opposite of Android's.
        #expect(translator.scroll(at: point, in: view, deltaX: 3, deltaY: -1, isPrecise: false) == [
            .injectScroll(position: position(200, 400), horizontal: -3, vertical: -1),
        ])
        #expect(translator.scroll(at: point, in: view, deltaX: 0, deltaY: 0, isPrecise: true).isEmpty)
    }

    @Test func otherButtonsNavigate() {
        let translator = translator()
        #expect(translator.secondaryDown(.right) == [.backOrScreenOn(action: .down)])
        #expect(translator.secondaryUp(.right) == [.backOrScreenOn(action: .up)])
        #expect(translator.secondaryDown(.middle) == [.injectKeycode(action: .down, keycode: 3)])
        #expect(translator.secondaryUp(.middle) == [.injectKeycode(action: .up, keycode: 3)])
        #expect(translator.secondaryDown(.fourth) == [.injectKeycode(action: .down, keycode: 187)])
        #expect(translator.secondaryDown(.fifth) == [.expandNotificationPanel])
        #expect(translator.secondaryUp(.fifth).isEmpty)
    }
}
