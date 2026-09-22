import CoreGraphics
import Testing
@testable import AppleDeviceKit
@testable import MirrorKit

@Suite struct IOSTouchTranslatorTests {
    let view = CGSize(width: 621, height: 1344) // 1242x2688 at exactly a half

    private func translator() -> IOSTouchTranslator {
        var translator = IOSTouchTranslator()
        translator.mapper = VideoPointMapper(videoWidth: 1242, videoHeight: 2688)
        return translator
    }

    @Test func tapIsASingleSample() {
        var translator = translator()
        translator.primaryDown(at: CGPoint(x: 100, y: 200), in: view)
        let gesture = translator.primaryUp(at: CGPoint(x: 100, y: 200), in: view)
        #expect(gesture?.map(\.pixels) == [CGPoint(x: 200, y: 400)])
    }

    @Test func dragKeepsItsPathAndEndsAtTheReleasePoint() {
        var translator = translator()
        translator.primaryDown(at: CGPoint(x: 100, y: 400), in: view)
        translator.primaryDragged(to: CGPoint(x: 100, y: 380), in: view)
        translator.primaryDragged(to: CGPoint(x: 100, y: 381), in: view) // below the minimum step: dropped
        translator.primaryDragged(to: CGPoint(x: 100, y: 300), in: view)
        let gesture = translator.primaryUp(at: CGPoint(x: 100, y: 250), in: view)!
        // Three recorded moves fit within maxMoves, so the path is kept whole.
        #expect(gesture.map(\.pixels) == [CGPoint(x: 200, y: 800), CGPoint(x: 200, y: 760),
                                           CGPoint(x: 200, y: 600), CGPoint(x: 200, y: 500)])
        #expect(gesture.first?.delay == 0)
    }

    @Test func releaseWithoutPressSendsNothing() {
        var translator = translator()
        #expect(translator.primaryUp(at: .zero, in: view) == nil)
        translator.primaryDown(at: CGPoint(x: -10, y: 10), in: view) // outside the video
        #expect(translator.primaryUp(at: CGPoint(x: 10, y: 10), in: view) == nil)
    }

    @Test func longDragsAreThinnedToAFewWaypoints() {
        var translator = translator()
        translator.primaryDown(at: CGPoint(x: 100, y: 600), in: view)
        for step in 1...40 { translator.primaryDragged(to: CGPoint(x: 100, y: 600 - step * 10), in: view) }
        let gesture = translator.primaryUp(at: CGPoint(x: 100, y: 200), in: view)!
        #expect(gesture.count == 1 + IOSTouchTranslator.maxMoves)
        #expect(gesture.first?.pixels == CGPoint(x: 200, y: 1200))
        #expect(gesture.last?.pixels == CGPoint(x: 200, y: 400))
        // Waypoints stay on the path, in order.
        #expect(gesture.map(\.pixels.y) == gesture.map(\.pixels.y).sorted(by: >))
        #expect(gesture.dropFirst().allSatisfy { $0.delay <= IOSTouchTranslator.maxGestureDuration })
    }

    @Test func thinningKeepsTheTotalDuration() {
        let samples = (0..<20).map { (pixels: CGPoint(x: CGFloat($0), y: 0), delay: $0 == 0 ? 0 : 0.05) }
        let thinned = IOSTouchTranslator.thinned(samples)
        #expect(thinned.count == 1 + IOSTouchTranslator.maxMoves)
        #expect(abs(thinned.dropFirst().reduce(0) { $0 + $1.delay } - 0.95) < 0.001)
        let slow = (0..<20).map { (pixels: CGPoint(x: CGFloat($0), y: 0), delay: $0 == 0 ? 0 : 0.5) }
        #expect(abs(IOSTouchTranslator.thinned(slow).dropFirst().reduce(0) { $0 + $1.delay } - 1.5) < 0.001)
    }

    @Test func wheelScrollBecomesAShortSwipe() {
        let translator = translator()
        let gesture = translator.scroll(at: CGPoint(x: 200, y: 400), in: view, deltaX: 0, deltaY: -2, isPrecise: false)
        #expect(gesture?.first?.pixels == CGPoint(x: 400, y: 800))
        #expect(gesture?.last?.pixels == CGPoint(x: 400, y: 800 - 360))
        #expect(translator.scroll(at: CGPoint(x: 200, y: 400), in: view, deltaX: 0, deltaY: 0, isPrecise: true) == nil)
    }

    @Test func scrollIsClampedToTheScreen() {
        let translator = translator()
        let gesture = translator.scroll(at: CGPoint(x: 200, y: 10), in: view, deltaX: 0, deltaY: -100, isPrecise: false)
        #expect(gesture?.last?.pixels.y == 0)
    }
}
