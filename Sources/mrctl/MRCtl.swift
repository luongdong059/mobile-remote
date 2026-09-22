import ADBKit
import AppleDeviceKit
import CoreMedia
import Foundation
import MirrorKit
import ScrcpyKit
import VideoKit

/// Developer CLI for exercising the mirroring stack without the app.
@main
struct MRCtl {
    static let usage = """
        usage: mrctl <command> [options]

          devices                     list devices known to adb
          watch                       print the device list on every plug / unplug
          stream                      run a session and print stream statistics
          snapshot                    decode one frame with VideoToolbox into a PNG
          screencap                   native-resolution PNG taken by the phone itself
          ios                         list cabled iPhones / iPads; with -o, capture the
                                      first one's screen for --seconds and save a PNG
          wda                         iPhone: check WebDriverAgent over USB; with --at X,Y
                                      (points) tap there; --swipe X1,Y1,X2,Y2; --type TEXT;
                                      --button home|volumeUp|volumeDown|lock
          tap                         touch a point, through the app's mouse translator
          swipe                       drag between two points
          scroll                      turn the mouse wheel over a point
          key                         press a navigation or hardware key

        common options:
          -s, --serial SERIAL         device to use (default: the only USB device)
          --codec h264|h265           video codec (default h264)
          --max-size N                longest side in pixels (default: native)
          --max-fps N                 frame rate cap (default 60)
          --bit-rate BPS              video bit rate (default: server's 8000000)
          --log-level LEVEL           server log level: verbose|debug|info|warn|error
          --codec-options OPTS        scrcpy video_codec_options, e.g. video-qp-max=30
          --nudge on|off              wiggle a virtual mouse when a static screen
                                      yields no first frame (default on)

        stream options:
          --seconds N                 how long to run (default 10)
          --reset-at N                send RESET_VIDEO after N seconds
          --dump FILE                 write the raw Annex B stream to FILE
          --record FILE.mp4           stream / ios: record the session to an MP4

        snapshot / screencap options:
          -o, --output FILE           PNG path (default snapshot.png / screencap.png)
          --after N                   snapshot only: decode for N seconds and save
                                      the last frame instead of the first
          --checkpoints T1,T2,...     with --after: also save the frame on screen at
                                      these times (seconds) as FILE-T.png

        input options (coordinates are in video pixels):
          tap   --at X,Y
          swipe --from X,Y --to X,Y [--ms N]   duration, default 300
          scroll --at X,Y [--dy TICKS] [--dx TICKS]   positive dy = wheel away from you
          key   --name back|home|recents|power|volume-up|volume-down
        """

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            var raw = Array(CommandLine.arguments.dropFirst())
            guard !raw.isEmpty else { return print(usage) }
            let command = raw.removeFirst()
            let arguments = try Arguments(raw)
            switch command {
            case "devices": try devices()
            case "watch": try watch()
            case "stream": try stream(arguments)
            case "snapshot": try snapshot(arguments)
            case "screencap": try screencap(arguments)
            case "ios": try ios(arguments)
            case "wda": try wda(arguments)
            case "tap": try tap(arguments)
            case "swipe": try swipe(arguments)
            case "scroll": try scroll(arguments)
            case "key": try key(arguments)
            default: print(usage)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: Commands

    static func devices() throws {
        let adb = ADBClient()
        try adb.ensureServerRunning()
        print("adb server version \(try adb.serverVersion())")
        printDevices(try adb.devices())
    }

    static func watch() throws {
        let adb = ADBClient()
        try adb.ensureServerRunning()
        print("watching devices, ctrl-c to stop")
        try adb.trackDevices { devices in
            print("--- \(Date().formatted(date: .omitted, time: .standard))")
            printDevices(devices)
            return true
        }
    }

    static func stream(_ arguments: Arguments) throws {
        let seconds = Double(try arguments.int("seconds") ?? 10)
        let nudge = try arguments.nudge()
        let dump = try arguments.string("dump").map { path -> FileHandle in
            FileManager.default.createFile(atPath: path, contents: nil)
            return try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        }
        defer { try? dump?.close() }

        let launch = Date()
        let session = try startSession(arguments)
        defer { session.stop() }
        guard let video = session.videoSocket else { return }
        let demuxer = StreamDemuxer(source: video)
        let codec = try demuxer.readCodec()
        print("codec: \(codec)")
        let recordPath = try arguments.string("record")
        let kind: VideoCodecKind? = codec == .h264 ? .h264 : codec == .h265 ? .hevc : nil
        var recorder: ScreenRecorder?
        var recordFormat: CMVideoFormatDescription?
        defer {
            if let recorder, let summary = try? recorder.finish() {
                print(String(format: "recorded %.1f s, %d frames (%d dropped) → %@", summary.duration, summary.frames,
                             summary.droppedFrames, summary.url.path))
            }
        }

        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            session.stop()
        }
        if let resetAt = try arguments.int("reset-at") {
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: Double(resetAt))
                print(String(format: "sending RESET_VIDEO at %.0f ms", since(launch)))
                try? session.send(.resetVideo)
            }
        }

        var frames = 0, bytes = 0, keyFrames = 0
        var windowFrames = 0, windowBytes = 0
        var windowStart = Date()
        var firstFrame: TimeInterval?
        let gotFrame = Gate()
        do {
            while let packet = try demuxer.nextPacket() {
                switch packet {
                case .session(let width, let height, _):
                    print(String(format: "session %dx%d at %.0f ms", width, height, since(launch)))
                    if nudge { FirstFrameNudge.start(on: session) { gotFrame.isOpen } }
                case .media(let media):
                    try dump?.write(contentsOf: media.payload)
                    bytes += media.payload.count
                    windowBytes += media.payload.count
                    if media.isConfig {
                        print(String(format: "config packet (%d bytes) at %.0f ms", media.payload.count, since(launch)))
                        if let kind, recordPath != nil, recordFormat == nil {
                            recordFormat = try SampleBuffers.formatDescription(codec: kind, configPayload: media.payload)
                        }
                        continue
                    }
                    if let recordPath, let kind, let recordFormat {
                        if recorder == nil, media.isKeyFrame {
                            recorder = try ScreenRecorder(url: URL(fileURLWithPath: recordPath), source: .compressed(recordFormat))
                        }
                        let sample = try SampleBuffers.sampleBuffer(codec: kind, payload: media.payload,
                                                                    ptsMicroseconds: media.pts ?? 0, format: recordFormat)
                        recorder?.append(sample, isKeyFrame: media.isKeyFrame)
                    }
                    frames += 1
                    windowFrames += 1
                    if media.isKeyFrame {
                        keyFrames += 1
                        print(String(format: "key frame (%d bytes) at %.0f ms", media.payload.count, since(launch)))
                    }
                    if firstFrame == nil {
                        firstFrame = since(launch)
                        gotFrame.open()
                        print(String(format: "first frame at %.0f ms", firstFrame!))
                    }
                }
                let elapsed = Date().timeIntervalSince(windowStart)
                if elapsed >= 1 {
                    print(String(format: "  %5.1f fps  %5.2f Mbps", Double(windowFrames) / elapsed,
                                 Double(windowBytes) * 8 / elapsed / 1e6))
                    windowFrames = 0
                    windowBytes = 0
                    windowStart = Date()
                }
            }
        } catch ADBError.endOfStream {
            // The timer closed the socket in the middle of a packet.
        }
        let total = since(launch) / 1000
        print(String(format: "done: %d frames (%d key) in %.1f s, %.2f Mbps average, first frame %@",
                     frames, keyFrames, total, Double(bytes) * 8 / total / 1e6,
                     firstFrame.map { String(format: "%.0f ms", $0) } ?? "never"))
    }

    static func snapshot(_ arguments: Arguments) throws {
        let output = URL(fileURLWithPath: try arguments.string("output") ?? "snapshot.png")
        let nudge = try arguments.nudge()
        let session = try startSession(arguments)
        defer { session.stop() }
        guard let video = session.videoSocket else { return }
        let demuxer = StreamDemuxer(source: video)

        let kind: VideoCodecKind
        switch try demuxer.readCodec() {
        case .h264: kind = .h264
        case .h265: kind = .hevc
        case let other: throw ScrcpyError.malformedPacket("snapshot does not support \(other)")
        }

        // With --after, keep decoding and save the frame on screen at that
        // moment instead of the first one: shows what a long-running mirror
        // looks like once the opening key frame is history.
        let after = try arguments.int("after").map(Double.init)
        let launch = Date()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: after ?? 20)
            session.stop()
        }

        var format: CMVideoFormatDescription?
        var decoder: FrameDecoder?
        var last: CVPixelBuffer?
        var recent: [String] = []
        let gotFrame = Gate()
        defer { gotFrame.open() }

        // Checkpoints fire on their own thread: a static screen sends no
        // packets, so the read loop below cannot keep time.
        let shared = LatestFrame()
        let checkpoints = (try arguments.string("checkpoints") ?? "").split(separator: ",").compactMap { Double($0) }
        if !checkpoints.isEmpty {
            Thread.detachNewThread {
                for time in checkpoints.sorted() {
                    Thread.sleep(forTimeInterval: max(0, time - Date().timeIntervalSince(launch)))
                    guard let (image, sizes) = shared.snapshot() else { continue }
                    let url = output.deletingPathExtension().appendingPathExtension("\(Int(time)).png")
                    try? FrameDecoder.writePNG(image, to: url)
                    print(String(format: "checkpoint %3.0f s: last 10 frame sizes %@", time,
                                 sizes.suffix(10).map(String.init).joined(separator: " ")))
                }
            }
        }
        do {
            while let packet = try demuxer.nextPacket() {
                switch packet {
                case .session(let width, let height, _):
                    print("session \(width)x\(height)")
                    if nudge { FirstFrameNudge.start(on: session) { gotFrame.isOpen } }
                case .media(let media) where media.isConfig:
                    format = try SampleBuffers.formatDescription(codec: kind, configPayload: media.payload)
                    decoder = nil
                case .media(let media):
                    guard let format else { continue }
                    let sample = try SampleBuffers.sampleBuffer(
                        codec: kind, payload: media.payload, ptsMicroseconds: media.pts ?? 0, format: format)
                    if decoder == nil { decoder = try FrameDecoder(format: format) }
                    last = try decoder?.decode(sample)
                    if let last { shared.update(last, size: media.payload.count) }
                    gotFrame.open()
                    recent.append(String(format: "%6.0f ms  %7d bytes%@", since(launch), media.payload.count,
                                         media.isKeyFrame ? "  key" : ""))
                }
                if after == nil, last != nil { break }
            }
        } catch ADBError.endOfStream {
            // The timer closed the socket in the middle of a packet.
        }

        guard let last else { throw ScrcpyError.malformedPacket("stream ended before a frame arrived") }
        if after != nil {
            print("\(recent.count) frames; the last ones:")
            recent.suffix(14).forEach { print("  " + $0) }
        }
        try FrameDecoder.writePNG(last, to: output)
        print("decoded \(CVPixelBufferGetWidth(last))x\(CVPixelBufferGetHeight(last)) → \(output.path)")
    }

    static func screencap(_ arguments: Arguments) throws {
        let output = URL(fileURLWithPath: try arguments.string("output") ?? "screencap.png")
        let adb = ADBClient()
        try adb.ensureServerRunning()
        let device = try pickDevice(try adb.devices(), requested: try arguments.string("serial"))
        let started = Date()
        let png = try DeviceScreenshot.capturePNG(adb: adb, serial: device.serial)
        try png.write(to: output)
        print(String(format: "%d bytes in %.0f ms → %@", png.count, since(started), output.path))
    }

    static func ios(_ arguments: Arguments) throws {
        let found = Gate()
        final class Box: @unchecked Sendable { var devices: [IOSDevice] = [] }
        let box = Box()
        let watcher = IOSDeviceWatcher { devices in
            box.devices = devices
            if !devices.isEmpty { found.open() }
        }
        watcher.start()
        let deadline = Date().addingTimeInterval(5)
        while !found.isOpen, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if box.devices.isEmpty { return print("  (no iOS devices; is the phone unlocked and trusted?)") }
        for device in box.devices { print("  \(device.uid)  \(device.name)") }

        guard let path = try arguments.string("output") else { return }
        let seconds = Double(try arguments.int("seconds") ?? 5)
        let renderer = VideoLayerRenderer()
        let launch = Date()
        let done = Gate()
        let mirror = IOSScreenMirror(device: box.devices[0], renderer: renderer) { event in
            switch event {
            case .connected(let name): print("connected: \(name)")
            case .videoSize(let w, let h): print("video \(w)x\(h)")
            case .firstFrame: print(String(format: "first frame at %.0f ms", since(launch)))
            case .stats(let fps, _): print(String(format: "  %5.1f fps", fps))
            case .ended(let reason): print("ended: \(reason ?? "stopped")"); done.open()
            case .recordingStarted: print(String(format: "recording started at %.0f ms", since(launch)))
            case .recordingFinished(let summary):
                print(String(format: "recorded %.1f s, %d frames (%d dropped) → %@", summary.duration, summary.frames,
                             summary.droppedFrames, summary.url.path))
            case .recordingFailed(let reason): print("recording failed: \(reason)")
            }
        }
        mirror.start()
        if let record = try arguments.string("record") { mirror.startRecording(to: URL(fileURLWithPath: record)) }
        let end = Date().addingTimeInterval(seconds)
        while !done.isOpen, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        mirror.stopRecording()
        let png = try mirror.screenshotPNG()
        try png.write(to: URL(fileURLWithPath: path))
        mirror.stop()
        print("\(png.count) bytes → \(path)")
    }

    static func wda(_ arguments: Arguments) throws {
        let devices = try USBMuxClient.listDevices()
        print("usbmuxd devices: \(devices.map(\.udid))")
        guard let udid = try arguments.string("udid") ?? devices.first?.udid else { throw CLIError("no cabled iOS device") }
        let client = WebDriverAgentClient(udid: udid)
        var started = Date()
        guard let status = client.status() else {
            throw CLIError("WebDriverAgent is not answering on port 8100 of \(udid)")
        }
        print(String(format: "status in %.0f ms: ready=%@ ios=%@", since(started), "\(status["ready"] ?? "?")",
                     "\(((status["os"] as? [String: Any])?["version"]) ?? "?")"))
        started = Date()
        let session = try client.createSession()
        print(String(format: "session %@ in %.0f ms", session, since(started)))
        print("screen scale \(try client.screenScale(session: session))")
        if let button = try arguments.string("button") {
            started = Date()
            try client.pressButton(session: session, button)
            print(String(format: "pressed %@ in %.0f ms", button, since(started)))
        }
        if let point = try? arguments.point("at") {
            started = Date()
            try client.performTouch(session: session, actions: [
                ["type": "pointerMove", "duration": 0, "x": point.x, "y": point.y],
                ["type": "pointerDown", "button": 0],
                ["type": "pause", "duration": 50],
                ["type": "pointerUp", "button": 0],
            ])
            print(String(format: "tapped %.0f,%.0f in %.0f ms", point.x, point.y, since(started)))
        }
        if let spec = try arguments.string("swipe") {
            let v = spec.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { throw CLIError("'--swipe' expects X1,Y1,X2,Y2 in points") }
            started = Date()
            try client.performTouch(session: session, actions: [
                ["type": "pointerMove", "duration": 0, "x": v[0], "y": v[1]],
                ["type": "pointerDown", "button": 0],
                ["type": "pointerMove", "duration": 250, "x": v[2], "y": v[3]],
                ["type": "pointerUp", "button": 0],
            ])
            print(String(format: "swiped in %.0f ms", since(started)))
        }
        if let text = try arguments.string("type") {
            started = Date()
            try client.type(session: session, text)
            print(String(format: "typed in %.0f ms", since(started)))
        }
    }

    static func tap(_ arguments: Arguments) throws {
        let point = try arguments.point("at")
        try withControl(arguments) { translator, size, send in
            try send(translator.primaryDown(at: point, in: size))
            Thread.sleep(forTimeInterval: 0.06)
            try send(translator.primaryUp(at: point, in: size))
        }
    }

    static func swipe(_ arguments: Arguments) throws {
        let from = try arguments.point("from"), to = try arguments.point("to")
        let steps = max(1, (try arguments.int("ms") ?? 300) / 10)
        try withControl(arguments) { translator, size, send in
            try send(translator.primaryDown(at: from, in: size))
            for step in 1...steps {
                Thread.sleep(forTimeInterval: 0.01)
                let progress = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
                try send(translator.primaryDragged(to: point, in: size))
            }
            try send(translator.primaryUp(at: to, in: size))
        }
    }

    static func scroll(_ arguments: Arguments) throws {
        let point = try arguments.point("at")
        let deltaX = CGFloat(try arguments.int("dx") ?? 0), deltaY = CGFloat(try arguments.int("dy") ?? 0)
        try withControl(arguments) { translator, size, send in
            try send(translator.scroll(at: point, in: size, deltaX: deltaX, deltaY: deltaY, isPrecise: false))
        }
    }

    static func key(_ arguments: Arguments) throws {
        let names: [String: AndroidKeycode] = [
            "back": .back, "home": .home, "recents": .appSwitch, "power": .power,
            "volume-up": .volumeUp, "volume-down": .volumeDown,
        ]
        guard let name = try arguments.string("name"), let keycode = names[name] else {
            throw CLIError("'--name' expects one of \(names.keys.sorted().joined(separator: ", "))")
        }
        try withControl(arguments) { _, _, send in
            try send(ControlMessage.keyPress(keycode))
        }
    }

    /// Runs `body` with a translator whose view is exactly the video, so view
    /// points are video pixels.
    static func withControl(
        _ arguments: Arguments,
        _ body: (inout MouseTranslator, CGSize, ([ControlMessage]) throws -> Void) throws -> Void
    ) throws {
        let session = try startSession(arguments)
        defer { session.stop() }
        guard let video = session.videoSocket else { return }
        let demuxer = StreamDemuxer(source: video)
        _ = try demuxer.readCodec()

        // Positional events must carry the size announced by the session packet.
        var size: CGSize?
        while size == nil, let packet = try demuxer.nextPacket() {
            if case .session(let width, let height, _) = packet { size = CGSize(width: width, height: height) }
        }
        guard let size else { throw ScrcpyError.malformedPacket("stream ended before a session packet") }
        print("video size \(Int(size.width))x\(Int(size.height))")

        var translator = MouseTranslator()
        translator.mapper = VideoPointMapper(videoWidth: Int(size.width), videoHeight: Int(size.height))
        var sent = 0
        try body(&translator, size) { messages in
            for message in messages {
                try session.send(message)
                sent += 1
            }
        }
        // Closing right away would shut the server down before it injects.
        Thread.sleep(forTimeInterval: 0.3)
        print("sent \(sent) control messages")
    }

    // MARK: Helpers

    static func startSession(_ arguments: Arguments) throws -> ScrcpySession {
        let adb = ADBClient()
        try adb.ensureServerRunning()
        let device = try pickDevice(try adb.devices(), requested: try arguments.string("serial"))

        var options = ScrcpyServerOptions()
        if let codec = try arguments.string("codec") {
            guard let parsed = [StreamCodec.h264, .h265, .av1].first(where: { $0.optionValue == codec }) else {
                throw CLIError("unknown codec '\(codec)'")
            }
            options.videoCodec = parsed
        }
        options.maxSize = try arguments.int("max-size")
        options.videoBitRate = try arguments.int("bit-rate")
        if let maxFps = try arguments.int("max-fps") { options.maxFps = maxFps }
        if let logLevel = try arguments.string("log-level") { options.logLevel = logLevel }
        if let codecOptions = try arguments.string("codec-options") {
            options.extra["video_codec_options"] = codecOptions
        }

        print("device: \(device.model ?? device.serial) [\(device.serial)]")
        print("server: \(options.arguments().joined(separator: " "))")
        let session = try ScrcpySession.start(adb: adb, serial: device.serial, options: options) {
            print("  \($0)")
        }
        print(String(format: "connected to '%@': push %.0f ms, server ready %.0f ms",
                     session.deviceName, session.timeline.push * 1000, session.timeline.serverReady * 1000))
        return session
    }

    static func pickDevice(_ devices: [ADBDevice], requested: String?) throws -> ADBDevice {
        if let requested {
            guard let device = devices.first(where: { $0.serial == requested }) else {
                throw CLIError("device '\(requested)' not found")
            }
            guard device.state == .device else { throw CLIError("device '\(requested)' is \(device.state)") }
            return device
        }
        let ready = devices.filter { $0.state == .device }
        let cabled = ready.filter(\.isUSB)
        if cabled.count == 1 { return cabled[0] }
        if ready.count == 1 { return ready[0] }
        if devices.contains(where: { $0.state == .unauthorized }) {
            throw CLIError("device is unauthorized: accept the USB debugging prompt on the phone")
        }
        throw CLIError(ready.isEmpty ? "no device connected" : "several devices connected, pick one with --serial")
    }

    static func printDevices(_ devices: [ADBDevice]) {
        if devices.isEmpty { print("  (no devices)") }
        for device in devices {
            let link = device.isUSB ? "usb" : "tcp"
            print("  \(device.serial)  \(device.state)  \(link)  \(device.model ?? "-")")
        }
    }

    static func since(_ date: Date) -> TimeInterval {
        Date().timeIntervalSince(date) * 1000
    }
}

/// The newest decoded picture, shared with the checkpoint thread.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CVPixelBuffer?
    private var sizes: [Int] = []

    func update(_ image: CVPixelBuffer, size: Int) {
        lock.withLock {
            self.image = image
            sizes.append(size)
        }
    }

    func snapshot() -> (CVPixelBuffer, [Int])? {
        lock.withLock { image.map { ($0, sizes) } }
    }
}

/// One-way flag shared between the reader loop and the nudging thread.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool { lock.withLock { opened } }
    func open() { lock.withLock { opened = true } }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `--name value` pairs; every option of this tool takes a value.
struct Arguments {
    private var values: [String: String] = [:]
    private static let aliases = ["-s": "serial", "-o": "output"]

    init(_ raw: [String]) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            guard let name = Self.aliases[argument] ?? (argument.hasPrefix("--") ? String(argument.dropFirst(2)) : nil)
            else { throw CLIError("unexpected argument '\(argument)'") }
            guard let value = iterator.next() else { throw CLIError("missing value for '\(argument)'") }
            values[name] = value
        }
    }

    func string(_ name: String) throws -> String? { values[name] }

    func int(_ name: String) throws -> Int? {
        guard let text = values[name] else { return nil }
        guard let value = Int(text) else { throw CLIError("'--\(name)' expects a number, got '\(text)'") }
        return value
    }

    /// `X,Y`
    func point(_ name: String) throws -> CGPoint {
        let parts = (values[name] ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { throw CLIError("'--\(name)' expects X,Y") }
        return CGPoint(x: parts[0], y: parts[1])
    }

    func nudge() throws -> Bool {
        switch values["nudge"] {
        case nil, "on": return true
        case "off": return false
        case let other?: throw CLIError("'--nudge' expects on or off, got '\(other)'")
        }
    }
}
