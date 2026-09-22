import Foundation
import Testing
@testable import MirrorKit

@Suite struct SettledPictureMonitorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    /// Feeds frames at the given millisecond offsets and returns the monitor.
    private func monitor(_ frames: [(ms: Int, size: Int, key: Bool)]) -> SettledPictureMonitor {
        var monitor = SettledPictureMonitor()
        for frame in frames {
            monitor.noteFrame(size: frame.size, isKeyFrame: frame.key, at: start.addingTimeInterval(Double(frame.ms) / 1000))
        }
        return monitor
    }

    private func motion(from ms: Int, count: Int) -> [(ms: Int, size: Int, key: Bool)] {
        (0..<count).map { (ms + $0 * 16, 20_000, false) }
    }

    /// `shouldRefresh` answers at each of these times (seconds), in order.
    private func answers(_ monitor: SettledPictureMonitor, at times: [TimeInterval]) -> [Bool] {
        var monitor = monitor
        return times.map { monitor.shouldRefresh(now: start.addingTimeInterval($0)) }
    }

    @Test func skipFrameRepeatsAfterMotionAskForARefresh() {
        let repeats = (1...10).map { (ms: 160 + $0 * 100, size: 40, key: false) }
        let monitor = monitor(motion(from: 0, count: 10) + repeats)
        // Still settling at 1.0 s, due at 1.5 s, and only once per burst.
        #expect(answers(monitor, at: [1.0, 1.5, 2.0]) == [false, true, false])
    }

    @Test func refiningRepeatsNeedNoRefresh() {
        let repeats = (1...10).map { (ms: 160 + $0 * 100, size: 24_000, key: false) }
        let monitor = monitor(motion(from: 0, count: 10) + repeats)
        #expect(answers(monitor, at: [1.5]) == [false])
    }

    @Test func slowUpdatesAreNotMotion() {
        // An app redrawing twice a second, each redraw followed by tiny repeats.
        let frames = (0..<8).map { (ms: $0 * 500, size: 3000, key: false) }
        #expect(answers(monitor(frames), at: [10]) == [false])
    }

    @Test func aKeyFrameSettlesThePicture() {
        let monitor = monitor(motion(from: 0, count: 10) + [(ms: 400, size: 46_000, key: true)])
        #expect(answers(monitor, at: [5]) == [false])
    }

    @Test func ongoingMotionPostponesTheCheck() {
        let monitor = monitor(motion(from: 0, count: 100)) // 1.6 s of scrolling
        #expect(answers(monitor, at: [2.0, 3.0]) == [false, true])
    }
}
