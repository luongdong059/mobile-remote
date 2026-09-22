import AVFoundation
import CoreMedia
import Foundation
import MirrorKit
import VideoKit

/// Live view of an iPhone's screen over USB, through the same capture
/// device QuickTime records from. Video only: iOS offers no input channel
/// this way. Events arrive on the capture queue.
public final class IOSScreenMirror: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public typealias Event = MirrorPipeline.Event

    private let device: IOSDevice
    private let renderer: VideoLayerRenderer
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "mobile-remote.ios-capture", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var stopped = false
    private var size: (Int, Int)?
    private var frames = 0
    private var windowStart = Date()
    private var observers: [NSObjectProtocol] = []
    private var recorder: ScreenRecorder?
    private var pendingRecordingURL: URL?

    public init(device: IOSDevice, renderer: VideoLayerRenderer, onEvent: @escaping @Sendable (Event) -> Void) {
        self.device = device
        self.renderer = renderer
        self.onEvent = onEvent
    }

    public func start() {
        queue.async { [self] in
            do {
                try open()
            } catch {
                onEvent(.ended(reason: "\(error)"))
            }
        }
    }

    public func stop() {
        if isRecording { stopRecording() }
        lock.withLock { stopped = true }
        observers.forEach(NotificationCenter.default.removeObserver)
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    public var isRecording: Bool { lock.withLock { recorder != nil || pendingRecordingURL != nil } }
    public var recordingElapsed: TimeInterval { lock.withLock { recorder?.elapsed ?? 0 } }

    /// Starts at the next frame, encoding in hardware.
    public func startRecording(to url: URL) {
        lock.withLock { pendingRecordingURL = url }
    }

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

    /// The frame on screen right now, as PNG at the phone's resolution.
    public func screenshotPNG() throws -> Data {
        guard let latest = lock.withLock({ latest }) else { throw IOSMirrorError.noFrames }
        return try FrameDecoder.pngData(latest)
    }

    private func open() throws {
        guard Self.requestCameraAccess() else { throw IOSMirrorError.cameraAccessDenied }
        // The AVFoundation side of the device can lag the CoreMediaIO listing.
        var capture: AVCaptureDevice?
        for _ in 0..<20 where capture == nil {
            capture = AVCaptureDevice(uniqueID: device.uid)
            if capture == nil { Thread.sleep(forTimeInterval: 0.25) }
        }
        guard let capture else { throw IOSMirrorError.deviceGone }

        let input = try AVCaptureDeviceInput(device: capture)
        let output = AVCaptureVideoDataOutput()
        // Same format the Android path decodes to; BGRA is not offered here.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.onEvent(.ended(reason: error.map { "\($0.localizedDescription)" } ?? "Lỗi thu hình"))
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: capture, queue: nil) { [weak self] _ in
                guard let self, !lock.withLock({ stopped }) else { return }
                onEvent(.ended(reason: IOSMirrorError.deviceGone.description))
            },
        ]
        onEvent(.connected(deviceName: device.name))
        session.startRunning()

        // No frame in a while usually means the phone is locked or untrusted.
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, lock.withLock({ latest == nil && !stopped }) else { return }
            onEvent(.ended(reason: IOSMirrorError.noFrames.description))
        }
    }

    /// The screen device counts as a camera for privacy purposes.
    private static func requestCameraAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            final class Answer: @unchecked Sendable { var granted = false }
            let answer = Answer()
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) {
                answer.granted = $0
                semaphore.signal()
            }
            semaphore.wait()
            return answer.granted
        default:
            return false
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer), !lock.withLock({ stopped }) else { return }
        let dimensions = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
        if size == nil || size! != dimensions {
            size = dimensions
            onEvent(.videoSize(width: dimensions.0, height: dimensions.1))
        }
        do {
            try renderer.present(image)
        } catch {
            onEvent(.ended(reason: "\(error)"))
            return
        }
        let recorder: ScreenRecorder? = lock.withLock {
            if let url = pendingRecordingURL {
                pendingRecordingURL = nil
                do {
                    self.recorder = try ScreenRecorder(url: url, source: .pixels(width: dimensions.0, height: dimensions.1))
                    onEvent(.recordingStarted)
                } catch {
                    onEvent(.recordingFailed("\(error)"))
                }
            }
            return self.recorder
        }
        recorder?.append(image, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let first = lock.withLock { () -> Bool in
            defer { latest = image }
            return latest == nil
        }
        if first { onEvent(.firstFrame) }

        frames += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            onEvent(.stats(framesPerSecond: Double(frames) / elapsed, megabitsPerSecond: 0))
            frames = 0
            windowStart = Date()
        }
    }
}
