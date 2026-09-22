import ADBKit
import CoreMedia
import Foundation
import ScrcpyKit
import VideoKit

/// One device's mirroring session: starts the server, reads the video stream
/// on its own thread and feeds the renderer. Events arrive on that thread.
public final class MirrorPipeline: @unchecked Sendable {
    public enum Event: Sendable {
        case connected(deviceName: String)
        /// Sent for the first session and again after every rotation / resize.
        case videoSize(width: Int, height: Int)
        case firstFrame
        case stats(framesPerSecond: Double, megabitsPerSecond: Double)
        /// `reason` is nil when the pipeline was stopped on purpose.
        case ended(reason: String?)
        case recordingStarted
        case recordingFinished(ScreenRecorder.Summary)
        /// Recording could not start or was cut short; the message says why.
        case recordingFailed(String)
    }

    private let adb: ADBClient
    private let serial: String
    private let options: ScrcpyServerOptions
    private let renderer: VideoLayerRenderer
    private let refreshesWhenSettled: Bool
    private let onEvent: @Sendable (Event) -> Void

    /// Keeps socket writes off the caller's (main) thread, and in order.
    private let controlQueue = DispatchQueue(label: "mobile-remote.control", qos: .userInteractive)
    private let lock = NSLock()
    private var session: ScrcpySession?
    private var stopped = false
    private var receivedFrame = false
    private var settling = SettledPictureMonitor()
    private var recorder: ScreenRecorder?
    /// Set by `startRecording`; the reader turns it into a recorder at the
    /// next key frame, when it knows the stream format.
    private var pendingRecordingURL: URL?

    /// `refreshesWhenSettled`: see `SettledPictureMonitor`.
    public init(adb: ADBClient = ADBClient(), serial: String, options: ScrcpyServerOptions,
                renderer: VideoLayerRenderer, refreshesWhenSettled: Bool = true,
                onEvent: @escaping @Sendable (Event) -> Void) {
        self.adb = adb
        self.serial = serial
        self.options = options
        self.renderer = renderer
        self.refreshesWhenSettled = refreshesWhenSettled
        self.onEvent = onEvent
    }

    public func start() {
        Thread.detachNewThread { [self] in
            var reason: String?
            do {
                try run()
            } catch {
                reason = "\(error)"
            }
            let wasStopped = lock.withLock { stopped }
            onEvent(.ended(reason: wasStopped ? nil : reason ?? "Thiết bị đã ngắt kết nối"))
        }
    }

    public func stop() {
        let current = lock.withLock { () -> ScrcpySession? in
            stopped = true
            return session
        }
        current?.stop()
    }

    public var isRecording: Bool { lock.withLock { recorder != nil || pendingRecordingURL != nil } }

    /// Seconds recorded so far, for a badge.
    public var recordingElapsed: TimeInterval { lock.withLock { recorder?.elapsed ?? 0 } }

    /// Recording begins at the next key frame, which is asked for right away.
    public func startRecording(to url: URL) {
        lock.withLock { pendingRecordingURL = url }
        send([.resetVideo])
    }

    /// Closes the file; the summary comes back as `recordingFinished`.
    public func stopRecording() {
        let recorder = lock.withLock { () -> ScreenRecorder? in
            pendingRecordingURL = nil
            defer { self.recorder = nil }
            return self.recorder
        }
        guard let recorder else { return }
        do {
            onEvent(.recordingFinished(try recorder.finish()))
        } catch {
            onEvent(.recordingFailed("\(error)"))
        }
    }

    /// Never blocks. Messages sent while no session is connected are dropped.
    public func send(_ messages: [ControlMessage]) {
        guard !messages.isEmpty, let session = lock.withLock({ session }) else { return }
        controlQueue.async {
            for message in messages {
                try? session.send(message)
            }
        }
    }

    // MARK: Reader thread

    private func run() throws {
        do {
            try stream(options)
        } catch where options.videoCodec != .h264 && !lock.withLock({ receivedFrame || stopped }) {
            // Not every phone has a hardware encoder for the preferred codec.
            var fallback = options
            fallback.videoCodec = .h264
            fallback.scid = ScrcpyServerOptions().scid
            try stream(fallback)
        }
    }

    private func stream(_ options: ScrcpyServerOptions) throws {
        let session = try ScrcpySession.start(adb: adb, serial: serial, options: options)
        defer { session.stop() }
        let alreadyStopped = lock.withLock { () -> Bool in
            self.session = session
            return stopped
        }
        guard !alreadyStopped, let video = session.videoSocket else { return }
        onEvent(.connected(deviceName: session.deviceName))
        if refreshesWhenSettled, options.control {
            Thread.detachNewThread { [self] in
                // The reader below blocks while the screen is static, so the
                // settle check needs its own clock.
                while !lock.withLock({ stopped }) {
                    Thread.sleep(forTimeInterval: 0.25)
                    if lock.withLock({ settling.shouldRefresh(now: Date()) }) {
                        try? session.send(.resetVideo)
                    }
                }
            }
        }
        if let control = session.controlSocket {
            Thread.detachNewThread {
                // Nothing consumes these yet, but leaving them unread would
                // eventually block the server's sender.
                let reader = DeviceMessageReader(source: control)
                while (try? reader.next()) != nil {}
            }
        }

        let demuxer = StreamDemuxer(source: video)
        let codec: VideoCodecKind
        switch try demuxer.readCodec() {
        case .h264: codec = .h264
        case .h265: codec = .hevc
        case let other: throw ScrcpyError.malformedPacket("no decoder for \(other)")
        }

        var format: CMVideoFormatDescription?
        var parameterSets = Data()
        var awaitingKeyFrame = false
        var nudged = false
        var frames = 0, bytes = 0
        var windowStart = Date()

        do {
            while let packet = try demuxer.nextPacket() {
                switch packet {
                case .session(let width, let height, _):
                    // A recording cannot follow a resolution change.
                    let sizeChanged = lock.withLock { () -> Bool in
                        guard let format else { return false }
                        let current = CMVideoFormatDescriptionGetDimensions(format)
                        return Int(current.width) != width || Int(current.height) != height
                    }
                    if sizeChanged, isRecording {
                        stopRecording()
                        onEvent(.recordingFailed("Ghi hình dừng vì màn hình đổi kích thước"))
                    }
                    onEvent(.videoSize(width: width, height: height))
                    if !nudged, options.control {
                        nudged = true
                        FirstFrameNudge.start(on: session) { [self] in lock.withLock { receivedFrame } }
                    }
                case .media(let media) where media.isConfig:
                    // Refreshed sessions repeat the same SPS/PPS; keeping one
                    // description object lets a recording continue across them.
                    if media.payload != parameterSets || format == nil {
                        let description = try SampleBuffers.formatDescription(codec: codec, configPayload: media.payload)
                        try renderer.configure(format: description)
                        format = description
                        parameterSets = media.payload
                    }
                case .media(let media):
                    guard let format else { continue }
                    bytes += media.payload.count
                    lock.withLock {
                        settling.noteFrame(size: media.payload.count, isKeyFrame: media.isKeyFrame, at: Date())
                    }
                    if awaitingKeyFrame, !media.isKeyFrame { continue }
                    let sample = try SampleBuffers.sampleBuffer(
                        codec: codec, payload: media.payload, ptsMicroseconds: media.pts ?? 0, format: format)
                    record(sample, isKeyFrame: media.isKeyFrame, format: format)
                    do {
                        try renderer.render(sample)
                        awaitingKeyFrame = false
                        frames += 1
                        if !lock.withLock({ receivedFrame }) {
                            lock.withLock { receivedFrame = true }
                            onEvent(.firstFrame)
                        }
                    } catch {
                        // The decoder lost its reference: skip ahead to a key
                        // frame, and ask the phone for one.
                        if !awaitingKeyFrame { try? session.send(.resetVideo) }
                        awaitingKeyFrame = true
                    }
                }

                let elapsed = Date().timeIntervalSince(windowStart)
                if elapsed >= 1 {
                    onEvent(.stats(framesPerSecond: Double(frames) / elapsed,
                                   megabitsPerSecond: Double(bytes) * 8 / elapsed / 1e6))
                    frames = 0
                    bytes = 0
                    windowStart = Date()
                }
            }
        } catch ADBError.endOfStream {
            // Closed in the middle of a packet: unplugged, or stop() was called.
        }
        if isRecording { stopRecording() }
    }

    private func record(_ sample: CMSampleBuffer, isKeyFrame: Bool, format: CMVideoFormatDescription) {
        let recorder: ScreenRecorder? = lock.withLock {
            if let url = pendingRecordingURL, isKeyFrame {
                pendingRecordingURL = nil
                do {
                    self.recorder = try ScreenRecorder(url: url, source: .compressed(format))
                    onEvent(.recordingStarted)
                } catch {
                    onEvent(.recordingFailed("\(error)"))
                }
            }
            return self.recorder
        }
        recorder?.append(sample, isKeyFrame: isKeyFrame)
    }
}
