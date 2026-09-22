import ADBKit
import AppKit
import AppleDeviceKit
import MirrorKit
import ScrcpyKit
import SwiftUI
import VideoKit

/// One window mirroring one device: a dark glass frame holding the screen and
/// a strip of controls.
@MainActor
final class MirrorWindowController: NSObject, NSWindowDelegate {
    let target: MirrorTarget
    /// Called once the window is gone, whoever closed it.
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let container = MirrorContainerView()
    private var mirrorView: MirrorView { container.mirrorView }
    private let printStats: Bool
    /// One of these is set, depending on the target.
    private var pipeline: MirrorPipeline?
    private var iosMirror: IOSScreenMirror?
    private var iosInput: IOSInputController?
    private var inputSink: MirrorInputSink?
    private var videoSize: NSSize?
    private var hasPlacedWindow = false
    private var isCapturing = false
    private var recordingTimer: Timer?
    private var controlKeys: [DeviceKey] = []
    private let autoRecordSeconds: Int?

    init(target: MirrorTarget, settings: AppSettings) {
        self.target = target
        printStats = settings.printStats
        autoRecordSeconds = settings.autoRecordSeconds
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()

        let name = target.title
        window.title = name
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The frame is dark glass in both system appearances.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        mirrorView.setStatus("Đang kết nối tới \(name)…")

        let onEvent: @Sendable (MirrorPipeline.Event) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        switch target {
        case .android(let device):
            let pipeline = MirrorPipeline(serial: device.serial, options: settings.serverOptions(),
                                          renderer: mirrorView.renderer,
                                          refreshesWhenSettled: settings.refreshesWhenSettled, onEvent: onEvent)
            self.pipeline = pipeline
            let sink = AndroidInputSink(pipeline: pipeline)
            inputSink = sink
            mirrorView.input = sink
            controlKeys = DeviceKey.allCases
            refreshControls()
            pipeline.start()
        case .ios(let device):
            let mirror = IOSScreenMirror(device: device, renderer: mirrorView.renderer, onEvent: onEvent)
            iosMirror = mirror
            // Control goes through WebDriverAgent, when the phone can be matched.
            var keys: [DeviceKey] = []
            if let udid = device.udid {
                let controller = IOSInputController(udid: udid) { [weak self] state in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.handleInputState(state) }
                    }
                }
                iosInput = controller
                let sink = IOSInputSink(controller: controller)
                inputSink = sink
                mirrorView.input = sink
                keys = [.home, .volumeUp, .volumeDown, .power]
                controller.start()
            }
            controlKeys = keys
            refreshControls()
            mirror.start()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(mirrorView)
    }

    func close() {
        window.close()
    }

    /// Rebuilds the strip; SwiftUI state lives here so the button follows the recording.
    private func refreshControls() {
        container.setControls(ControlStrip(
            keys: controlKeys, isRecording: isRecording,
            onKey: { [weak self] key in self?.press(key) },
            onScreenshot: { [weak self] in self?.copyScreenshot(nil) },
            onRecord: { [weak self] in self?.toggleRecording(nil) }))
    }

    private func press(_ key: DeviceKey) {
        switch target {
        case .android: pipeline?.send(ControlMessage.keyPress(key.androidKeycode))
        case .ios: if let button = key.wdaButton { iosInput?.pressButton(button) }
        }
    }

    // MARK: Recording

    var isRecording: Bool { pipeline?.isRecording ?? iosMirror?.isRecording ?? false }

    /// Starts or stops recording to ~/Movies/Mobile Remote. Reached from the
    /// control strip, and from the Device menu through the responder chain.
    @objc func toggleRecording(_ sender: Any?) {
        if isRecording {
            pipeline?.stopRecording()
            iosMirror?.stopRecording()
        } else {
            let url = ScreenRecorder.defaultURL(deviceName: window.title)
            pipeline?.startRecording(to: url)
            iosMirror?.startRecording(to: url)
            mirrorView.showToast("Đang chờ khung hình để bắt đầu ghi…")
        }
        refreshControls()
    }

    @objc func revealRecordings(_ sender: Any?) {
        let directory = ScreenRecorder.recordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func updateRecordingBadge() {
        let elapsed = pipeline?.recordingElapsed ?? iosMirror?.recordingElapsed ?? 0
        mirrorView.setRecordingBadge(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
    }

    func bringToFront() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Puts a native-resolution screenshot on the clipboard. Reached from the
    /// control strip, and from the Device menu through the responder chain.
    @objc func copyScreenshot(_ sender: Any?) {
        guard !isCapturing else { return }
        isCapturing = true
        let target = target
        let iosMirror = iosMirror
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> Data in
                switch target {
                case .android(let device): return try DeviceScreenshot.capturePNG(serial: device.serial)
                case .ios: return try iosMirror?.screenshotPNG() ?? { throw IOSMirrorError.noFrames }()
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.finishScreenshot(result) }
            }
        }
    }

    private func finishScreenshot(_ result: Result<Data, Error>) {
        isCapturing = false
        switch result {
        case .success(let png):
            DeviceScreenshot.copy(png)
            mirrorView.showToast("Đã chép ảnh màn hình vào clipboard")
        case .failure(let error):
            mirrorView.showToast("\(error)")
        }
    }

    private func handleInputState(_ state: IOSInputController.State) {
        if printStats { print("[\(target.id)] input: \(state)") }
        switch state {
        case .starting: mirrorView.showToast("Đang khởi động điều khiển (WebDriverAgent)…")
        case .ready: mirrorView.showToast("Điều khiển sẵn sàng")
        case .unavailable(let reason): mirrorView.showToast("Không điều khiển được: \(reason)")
        }
    }

    private func handle(_ event: MirrorPipeline.Event) {
        switch event {
        case .connected(let deviceName):
            window.title = deviceName
        case .videoSize(let width, let height):
            mirrorView.setVideoSize(width: width, height: height)
            fitWindow(to: NSSize(width: width, height: height))
        case .firstFrame:
            mirrorView.setStatus(nil)
            if let seconds = autoRecordSeconds, !isRecording {
                toggleRecording(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                    MainActor.assumeIsolated { self?.toggleRecording(nil) }
                }
            }
        case .stats(let framesPerSecond, let megabitsPerSecond):
            if printStats {
                print(String(format: "[%@] %5.1f fps  %5.2f Mbps", target.id, framesPerSecond, megabitsPerSecond))
            }
        case .ended(let reason):
            if let reason { mirrorView.setStatus(reason) }
        case .recordingStarted:
            updateRecordingBadge()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRecordingBadge() }
            }
            refreshControls()
        case .recordingFinished(let summary):
            if printStats {
                print(String(format: "[%@] recorded %.1f s, %d frames (%d dropped) → %@", target.id, summary.duration,
                             summary.frames, summary.droppedFrames, summary.url.path))
            }
            recordingTimer?.invalidate()
            recordingTimer = nil
            mirrorView.setRecordingBadge(nil)
            mirrorView.showToast(String(format: "Đã lưu %@ (%d:%02d)", summary.url.lastPathComponent,
                                        Int(summary.duration) / 60, Int(summary.duration) % 60))
            // Show the file where it landed, so it is never a mystery.
            NSWorkspace.shared.activateFileViewerSelecting([summary.url])
            refreshControls()
        case .recordingFailed(let reason):
            if printStats { print("[\(target.id)] recording failed: \(reason)") }
            recordingTimer?.invalidate()
            recordingTimer = nil
            mirrorView.setRecordingBadge(nil)
            mirrorView.showToast(reason)
            refreshControls()
        }
    }

    // MARK: Sizing

    /// Sizes the window so the video fills most of the screen, keeping the
    /// window's top-left corner in place across rotations.
    private func fitWindow(to videoSize: NSSize) {
        // Sessions restart without a size change (key-frame refreshes): the
        // window the user arranged must stay as it is.
        if let current = self.videoSize, abs(current.width / current.height - videoSize.width / videoSize.height) < 0.01 {
            self.videoSize = videoSize
            return
        }
        self.videoSize = videoSize
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chrome = MirrorContainerView.chromeSize
        let bounds = NSSize(width: visible.width * 0.85 - chrome.width, height: visible.height * 0.9 - chrome.height)
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let content = NSSize(width: (videoSize.width * scale).rounded() + chrome.width,
                             height: (videoSize.height * scale).rounded() + chrome.height)
        window.contentMinSize = NSSize(width: 180 + chrome.width,
                                       height: 180 * videoSize.height / videoSize.width + chrome.height)

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        if hasPlacedWindow {
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        } else {
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            hasPlacedWindow = true
        }
        window.setFrame(frame, display: true, animate: false)
    }

    /// Keeps the video area at the video's aspect ratio. The frame around it
    /// has a fixed thickness, so a plain content aspect ratio cannot do this.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let videoSize else { return frameSize }
        let chrome = MirrorContainerView.chromeSize
        let aspect = videoSize.width / videoSize.height
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size

        // Follow whichever edge the user is dragging more.
        let widthLed = abs(frameSize.width - sender.frame.width) >= abs(frameSize.height - sender.frame.height)
        var video = NSSize(width: proposed.width - chrome.width, height: proposed.height - chrome.height)
        if widthLed {
            video.height = video.width / aspect
        } else {
            video.width = video.height * aspect
        }
        let content = NSSize(width: video.width.rounded() + chrome.width, height: video.height.rounded() + chrome.height)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    func windowWillClose(_ notification: Notification) {
        pipeline?.stop()
        pipeline = nil
        iosMirror?.stop()
        iosMirror = nil
        iosInput?.stop()
        iosInput = nil
        onClose?()
    }
}

/// Lays out the glass frame: the screen, with the control strip to its right.
final class MirrorContainerView: NSView {
    static let edge: CGFloat = 10
    static let stripWidth: CGFloat = 46
    /// Space around the video: the title bar above, the strip on the right.
    static let insets = NSEdgeInsets(top: 36, left: edge, bottom: edge, right: edge + stripWidth + edge)
    static var chromeSize: NSSize {
        NSSize(width: insets.left + insets.right, height: insets.top + insets.bottom)
    }

    let mirrorView = MirrorView(frame: .zero)
    private let background = NSVisualEffectView()
    private var controls: NSView?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 840))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        addSubview(background)
        addSubview(mirrorView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setControls(_ strip: ControlStrip) {
        controls?.removeFromSuperview()
        let host = NSHostingView(rootView: strip)
        addSubview(host)
        controls = host
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let insets = Self.insets
        background.frame = bounds
        let height = bounds.height - insets.top - insets.bottom
        mirrorView.frame = NSRect(x: insets.left, y: insets.bottom,
                                  width: bounds.width - insets.left - insets.right, height: height)
        controls?.frame = NSRect(x: bounds.width - Self.edge - Self.stripWidth, y: insets.bottom,
                                 width: Self.stripWidth, height: height)
    }
}
