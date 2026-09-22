import CoreGraphics
import Foundation
import MirrorKit

/// Drives an iPhone through WebDriverAgent: a signed XCUITest runner built
/// by scripts/install-wda.sh. It only gets UI-testing rights inside an Xcode
/// test session, so it is run through `xcodebuild test-without-building`,
/// which stays alive as a child process for as long as the mirror is open.
/// The runner serves HTTP on port 8100; requests reach it over usbmuxd.
public final class IOSInputController: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case ready
        /// WebDriverAgent could not be reached; the message says why.
        case unavailable(String)
    }

    public static let runnerBundleID = "com.nldong.WebDriverAgentRunner.xctrunner"
    /// Where scripts/install-wda.sh leaves the build; `MOBILE_REMOTE_WDA_XCTESTRUN`
    /// points at a specific .xctestrun instead.
    public static let buildDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/mobile-remote/wda/build/Build/Products")

    public let udid: String
    private let client: WebDriverAgentClient
    private let onState: @Sendable (State) -> Void
    /// Gestures run one after another, in order, off the main thread.
    private let queue = DispatchQueue(label: "mobile-remote.ios-input", qos: .userInteractive)
    private let lock = NSLock()
    private var session: String?
    /// Points per video pixel; set once the session and video size are known.
    private var pointsPerPixel = 1.0 / 3.0
    private var stopped = false
    private var runner: Process?

    public init(udid: String, onState: @escaping @Sendable (State) -> Void) {
        self.udid = udid
        client = WebDriverAgentClient(udid: udid)
        self.onState = onState
    }

    public func start() {
        onState(.starting)
        queue.async { [self] in
            do {
                if client.status() == nil {
                    let process = try Self.launchRunner(udid: udid)
                    lock.withLock { runner = process }
                    // xcodebuild takes ~10 s to install and start the runner,
                    // longer on a first run.
                    let deadline = Date().addingTimeInterval(90)
                    while client.status() == nil {
                        guard process.isRunning else {
                            throw WebDriverAgentClient.Error.wda(Self.explainExit(process))
                        }
                        guard Date() < deadline, !lock.withLock({ stopped }) else {
                            throw WebDriverAgentClient.Error.wda("WebDriverAgent không phản hồi sau 90 giây")
                        }
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
                let id = try client.createSession()
                try? client.tuneForLowLatency(session: id)
                let scale = try client.screenScale(session: id)
                lock.withLock {
                    session = id
                    pointsPerPixel = 1 / scale
                }
                onState(.ready)
            } catch {
                onState(.unavailable(Self.explain(error)))
            }
        }
    }

    /// Ends the Xcode test session, which also quits the runner on the phone.
    public func stop() {
        let process = lock.withLock { () -> Process? in
            stopped = true
            return runner
        }
        if let process, process.isRunning { process.terminate() }
    }

    /// `pixels` is in video (screen) pixels; WebDriverAgent wants points.
    private func point(_ pixels: CGPoint) -> CGPoint {
        let scale = lock.withLock { pointsPerPixel }
        return CGPoint(x: pixels.x * scale, y: pixels.y * scale)
    }

    /// A whole gesture: pointer down at the first sample, moves, and up.
    /// `samples` carry the time since the previous sample, so the phone
    /// replays the drag at the speed the mouse made it.
    public func performGesture(_ samples: [(pixels: CGPoint, delay: TimeInterval)]) {
        guard let first = samples.first else { return }
        var actions: [[String: Any]] = [
            ["type": "pointerMove", "duration": 0, "x": point(first.pixels).x, "y": point(first.pixels).y],
            ["type": "pointerDown", "button": 0],
        ]
        for sample in samples.dropFirst() {
            let p = point(sample.pixels)
            actions.append(["type": "pointerMove", "duration": Int(max(sample.delay, 0.001) * 1000), "x": p.x, "y": p.y])
        }
        if samples.count == 1 { actions.append(["type": "pause", "duration": 50]) }
        actions.append(["type": "pointerUp", "button": 0])
        guard let encoded = try? WebDriverAgentClient.encodeTouch(actions) else { return }
        run { session in try self.client.performTouch(session: session, encodedActions: encoded) }
    }

    public func pressButton(_ name: String) {
        run { session in try self.client.pressButton(session: session, name) }
    }

    public func type(_ text: String) {
        run { session in try self.client.type(session: session, text) }
    }

    private func run(_ body: @escaping @Sendable (String) throws -> Void) {
        queue.async { [self] in
            guard let session = lock.withLock({ session }) else { return }
            do {
                try body(session)
            } catch {
                // The session may have died with the runner; report and let
                // the next start() recover.
                lock.withLock { self.session = nil }
                onState(.unavailable(Self.explain(error)))
            }
        }
    }

    /// The .xctestrun produced by scripts/install-wda.sh.
    public static func xctestrunURL() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["MOBILE_REMOTE_WDA_XCTESTRUN"] {
            return URL(fileURLWithPath: explicit)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: buildDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "xctestrun" && $0.lastPathComponent.contains("iphoneos") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    /// Starts the Xcode test session that hosts the runner. Output goes to a
    /// log file, since xcodebuild is chatty and never ends by itself.
    static func launchRunner(udid: String) throws -> Process {
        guard let xctestrun = xctestrunURL() else {
            throw WebDriverAgentClient.Error.wda("WebDriverAgent chưa được build. Chạy scripts/install-wda.sh một lần.")
        }
        // A shell wrapper ties xcodebuild to this process: it dies when we
        // ask (SIGTERM) and also when we vanish without asking.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            xcrun xcodebuild test-without-building -xctestrun "$1" -destination "id=$2" & child=$!
            trap 'kill $child 2>/dev/null' TERM INT
            while kill -0 $child 2>/dev/null && kill -0 $3 2>/dev/null; do sleep 1; done
            kill $child 2>/dev/null; wait $child
            """, "wda", xctestrun.path, udid, String(ProcessInfo.processInfo.processIdentifier)]
        let logURL = buildDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("wda-\(udid).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        try process.run()
        return process
    }

    private static func explainExit(_ process: Process) -> String {
        let udid = process.arguments.map { $0[$0.count - 2] } ?? ""
        let logURL = buildDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("wda-\(udid).log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if log.contains("profile") && (log.contains("expired") || log.contains("has expired") || log.contains("no longer valid")) ||
            log.contains("Provisioning profile") && log.contains("expired") {
            return "Hồ sơ ký của WebDriverAgent đã hết hạn. Chạy lại scripts/install-wda.sh."
        }
        if log.contains("not trusted") {
            return "iPhone chưa tin cậy nhà phát triển: Cài đặt › Cài đặt chung › VPN & Quản lý thiết bị."
        }
        if log.contains("locked") {
            return "iPhone đang khóa. Hãy mở khóa rồi bấm Mở lại."
        }
        return "xcodebuild đã thoát (mã \(process.terminationStatus)); xem \(logURL.path)"
    }

    private static func explain(_ error: Error) -> String {
        if let error = error as? USBMuxClient.Error, case .connectRefused = error {
            return "WebDriverAgent không chạy trên iPhone"
        }
        return "\(error)"
    }
}
