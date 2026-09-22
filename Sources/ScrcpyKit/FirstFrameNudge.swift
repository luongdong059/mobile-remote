import Foundation

/// Gets a first frame out of a static screen.
///
/// The encoder only emits when the screen changes, and the redraw caused by
/// creating the mirror display lands before the encoder has started, so it is
/// lost (measured on a Galaxy A34: 1–10 s of blank video, or forever).
/// Injected hover / key events do not help because they bypass the system
/// cursor, and `resetVideo` replays the same race. A UHID mouse works: the
/// phone draws a real cursor, which forces a composition.
public enum FirstFrameNudge {
    /// Call when the session packet arrives. If no frame shows up within
    /// `gracePeriod` (an animating screen delivers one in ~200 ms), wiggles a
    /// virtual mouse until `hasFrame` returns true, then removes it again.
    public static func start(
        on session: ScrcpySession, gracePeriod: TimeInterval = 0.25,
        hasFrame: @escaping @Sendable () -> Bool
    ) {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: gracePeriod)
            guard !hasFrame(), (try? session.send(HIDMouse.create)) != nil else { return }
            // The device takes a moment to register and early reports are lost;
            // wiggling back and forth leaves the cursor where it started.
            for attempt in 0..<30 where !hasFrame() {
                let report = HIDMouse.report(dx: attempt % 2 == 0 ? 1 : -1)
                try? session.send(.uhidInput(id: HIDMouse.deviceID, report: report))
                Thread.sleep(forTimeInterval: 0.1)
            }
            try? session.send(.uhidDestroy(id: HIDMouse.deviceID))
        }
    }
}
