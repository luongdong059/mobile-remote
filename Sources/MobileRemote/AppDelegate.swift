import ADBKit
import AppKit
import AppleDeviceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.fromCommandLine()
    private let model = DeviceListModel()
    private var watcher: DeviceWatcher?
    private var iosWatcher: IOSDeviceWatcher?
    /// Keyed by `MirrorTarget.id`.
    private var mirrors: [String: MirrorWindowController] = [:]
    /// Ready targets seen in the previous update, to spot newly plugged ones.
    private var readyIDs: Set<String> = []
    private var pendingOpenSerial: String?
    private lazy var home = HomeWindowController(model: model)
    private lazy var settingsWindow = SettingsWindowController()
    private let wifi = WiFiConnections()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = settings.previewDirectory {
            UIPreview.render(into: URL(fileURLWithPath: directory))
            exit(0)
        }

        NSApp.mainMenu = makeMainMenu()
        pendingOpenSerial = settings.openSerial
        // A packaged app gets its icon from the bundle; `swift run` has none.
        if Bundle.main.bundleIdentifier == nil, let logo = AppResources.logo {
            NSApp.applicationIconImage = logo
        }
        model.onOpen = { [weak self] in self?.openMirror(for: $0) }
        model.onShow = { [weak self] in self?.mirrors[$0]?.bringToFront() }
        model.onClose = { [weak self] in self?.mirrors[$0]?.close() }
        model.onSwitchToWiFi = { [weak self] device in
            self?.wifiAction("Đang chuyển \(device.model ?? device.serial) sang Wi-Fi…") { report in
                self?.wifi.switchToWiFi(device, report: report)
            }
        }
        model.onConnect = { [weak self] address in
            self?.wifiAction("Đang kết nối \(address)…") { report in self?.wifi.connect(address, report: report) }
        }
        model.onPair = { [weak self] address, code in
            self?.wifiAction("Đang ghép nối \(address)…") { report in self?.wifi.pair(address, code: code, report: report) }
        }
        model.onDisconnect = { [weak self] address in
            self?.wifiAction("Đang ngắt \(address)…") { report in self?.wifi.disconnect(address, report: report) }
        }
        model.onReconnect = { [weak self] device in
            self?.wifiAction("Đang kết nối \(device.model ?? device.serial)…") { report in
                self?.wifi.reconnect(device, onResult: report)
            }
        }
        model.onForget = { [weak self] device in
            RememberedDevices.forget(device.id)
            self?.model.remembered = RememberedDevices.all
        }
        statusBar = StatusBarController(model: model, showHome: { [weak self] in self?.home.show() },
                                        showSettings: { [weak self] in self?.settingsWindow.show() })
        home.show()
        if settings.showSettings { settingsWindow.show() }

        let watcher = DeviceWatcher { [weak self] update in
            self?.handle(update)
        }
        self.watcher = watcher
        watcher.start()
        wifi.startReconnecting { [weak self] in self?.model.offlineRemembered ?? [] }
        let iosWatcher = IOSDeviceWatcher { [weak self] devices in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleIOS(devices) }
            }
        }
        self.iosWatcher = iosWatcher
        iosWatcher.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The menu bar item keeps the app running with every window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { home.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mirrors.values.forEach { $0.close() }
    }

    private func handle(_ update: DeviceWatcher.Update) {
        switch update {
        case .unavailable(let message):
            model.adbError = "Không kết nối được adb: \(message)"
        case .devices(let devices):
            model.adbError = nil
            model.androidDevices = devices
            // Any Wi-Fi device that shows up is worth remembering.
            for device in devices where device.serial.contains(":") && device.state == .device {
                let known = RememberedDevices.all.first { $0.address == device.serial }
                RememberedDevices.remember(serial: known?.serial, model: device.model ?? known?.model, address: device.serial)
            }
            model.remembered = RememberedDevices.all
            reconcile()
        }
    }

    private func handleIOS(_ devices: [IOSDevice]) {
        model.iosDevices = devices
        reconcile()
    }

    /// Closes windows of devices that went away and opens newly plugged ones.
    private func reconcile() {
        let ready = model.targets.filter(\.isReady)
        let readyNow = Set(ready.map(\.id))
        for (id, mirror) in mirrors where !readyNow.contains(id) {
            // Bring the list back first, so an unplug never quits the app
            // by closing its last window.
            if mirrors.count == 1, !home.isVisible { home.show() }
            mirror.close()
        }
        if model.autoOpen {
            for target in ready where target.isUSB && !readyIDs.contains(target.id) {
                openMirror(for: target)
            }
        }
        if let pending = pendingOpenSerial,
           let requested = ready.first(where: { $0.id.hasSuffix(":" + pending) }) {
            pendingOpenSerial = nil
            openMirror(for: requested)
        }
        readyIDs = readyNow
    }

    private func openMirror(for target: MirrorTarget) {
        if let existing = mirrors[target.id] {
            existing.bringToFront()
            return
        }
        // Re-read so the settings window's changes apply to new sessions.
        let mirror = MirrorWindowController(target: target, settings: AppSettings.fromCommandLine())
        mirror.onClose = { [weak self] in
            self?.mirrors[target.id] = nil
            self?.model.mirroring.remove(target.id)
        }
        mirrors[target.id] = mirror
        model.mirroring.insert(target.id)
    }

    /// Shows progress in the Wi-Fi card, then the outcome.
    private func wifiAction(_ progress: String, _ start: (@escaping @MainActor @Sendable (String, Bool) -> Void) -> Void) {
        model.wifiBusy = true
        model.wifiStatus = progress
        start { [weak self] text, _ in
            self?.model.wifiBusy = false
            self?.model.wifiStatus = text
            self?.model.remembered = RememberedDevices.all
        }
    }

    @objc private func showHome(_ sender: Any?) {
        home.show()
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Cài đặt…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Thoát Mobile Remote", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        main.addItem(submenu: appMenu)

        // Nil targets: these go to the mirror window that has the focus.
        let deviceMenu = NSMenu(title: "Thiết bị")
        let screenshot = deviceMenu.addItem(withTitle: "Chép ảnh màn hình vào clipboard",
                                            action: #selector(MirrorWindowController.copyScreenshot(_:)),
                                            keyEquivalent: "c")
        screenshot.keyEquivalentModifierMask = [.command, .control]
        let record = deviceMenu.addItem(withTitle: "Ghi / dừng ghi màn hình",
                                        action: #selector(MirrorWindowController.toggleRecording(_:)),
                                        keyEquivalent: "r")
        record.keyEquivalentModifierMask = [.command, .control]
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(withTitle: "Mở thư mục ghi hình",
                           action: #selector(MirrorWindowController.revealRecordings(_:)), keyEquivalent: "")
        main.addItem(submenu: deviceMenu)

        let windowMenu = NSMenu(title: "Cửa sổ")
        windowMenu.addItem(withTitle: "Danh sách thiết bị", action: #selector(showHome(_:)), keyEquivalent: "0")
            .target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Đóng", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Thu nhỏ", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        main.addItem(submenu: windowMenu)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
