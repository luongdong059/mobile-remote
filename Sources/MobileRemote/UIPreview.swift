import ADBKit
import AppKit
import AppleDeviceKit
import SwiftUI

/// Development aid (`MobileRemote --render-ui DIR`): draws the SwiftUI parts
/// with sample data into PNGs, for checking layout where the screen cannot be
/// captured. Behind-window blur and glass refraction do not show up in these.
@MainActor
enum UIPreview {
    static func render(into directory: URL) {
        let model = DeviceListModel()
        model.androidDevices = [
            ADBDevice(serial: "RFCW6067EBH", state: .device, properties: ["model": "SM_A346E", "usb": "1"]),
            ADBDevice(serial: "emulator-5554", state: .device, properties: ["model": "Android_SDK_built_for_arm64"]),
            ADBDevice(serial: "R58M123ABC", state: .unauthorized, properties: ["usb": "2"]),
        ]
        model.iosDevices = [IOSDevice(uid: "54E5A0BC", name: "DongNguyen")]
        model.mirroring = ["android:RFCW6067EBH"]
        write(HomeView(model: model), size: NSSize(width: 560, height: 480), to: directory.appendingPathComponent("home.png"))

        let empty = DeviceListModel()
        write(HomeView(model: empty), size: NSSize(width: 560, height: 480),
              to: directory.appendingPathComponent("home-empty.png"))

        let strip = ControlStrip(keys: DeviceKey.allCases, onKey: { _ in }, onScreenshot: {}, onRecord: {})
            .padding(10)
            .background(Color(white: 0.15))
            .environment(\.colorScheme, .dark)
        write(strip, size: NSSize(width: 66, height: 480), to: directory.appendingPathComponent("strip.png"))
        renderSettings(into: directory)
    }

    static func write(_ view: some View, size: NSSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension UIPreview {
    /// Also drawn by `--render-ui`: the settings form.
    static func renderSettings(into directory: URL) {
        write(SettingsView(), size: NSSize(width: 520, height: 460), to: directory.appendingPathComponent("settings.png"))
    }
}
