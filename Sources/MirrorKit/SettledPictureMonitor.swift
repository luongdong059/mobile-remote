import Foundation

/// Decides when the settled picture needs a fresh key frame.
///
/// After a burst of motion the phone's encoder is often over its bit budget.
/// It then codes the last frame coarsely and answers Android's ten 100 ms
/// "repeat previous frame" submissions with empty skip frames, so the blur is
/// never repaired and stays until the screen changes again (seen on a
/// MediaTek HEVC encoder: whole-screen blur, trailing frames of ~40 bytes).
/// A healthy encoder spends tens of kilobytes on those repeats instead.
/// `RESET_VIDEO` restarts the encoder, which sends a clean key frame within
/// ~200 ms, the same thing reopening the mirror does.
struct SettledPictureMonitor {
    /// Frames closer together than this are motion; repeats come 100 ms apart.
    static let motionInterval: TimeInterval = 0.06
    /// Consecutive motion frames before the picture counts as disturbed.
    static let motionRun = 3
    /// The ten repeats are over about a second after the motion stops.
    static let settleDelay: TimeInterval = 1.2
    /// Repeats smaller than this carry no refinement.
    static let refinementBytes = 2048

    private var lastArrival: Date?
    private var run = 0
    private var lastMotion: Date?
    private var refinedSinceMotion = false

    mutating func noteFrame(size: Int, isKeyFrame: Bool, at now: Date) {
        defer { lastArrival = now }
        if isKeyFrame {
            // A key frame is as good as the picture gets.
            lastMotion = nil
            run = 0
            return
        }
        if let lastArrival, now.timeIntervalSince(lastArrival) < Self.motionInterval {
            run += 1
            if run >= Self.motionRun {
                lastMotion = now
                refinedSinceMotion = false
            }
        } else {
            run = 0
            if lastMotion != nil, size >= Self.refinementBytes { refinedSinceMotion = true }
        }
    }

    /// True once per burst, when motion has settled without any refinement.
    mutating func shouldRefresh(now: Date) -> Bool {
        guard let lastMotion, now.timeIntervalSince(lastMotion) >= Self.settleDelay else { return false }
        self.lastMotion = nil
        return !refinedSinceMotion
    }
}
