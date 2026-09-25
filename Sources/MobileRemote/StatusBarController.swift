import ADBKit
import AppKit

/// The menu bar item: a template icon (so it follows the menu bar's light or
/// dark rendering) with a menu of devices, plus the app's main windows.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let model: DeviceListModel
    private let showHome: () -> Void
    private let showSettings: () -> Void

    init(model: DeviceListModel, showHome: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.model = model
        self.showHome = showHome
        self.showSettings = showSettings
        super.init()
        item.button?.image = Self.icon()
        item.button?.toolTip = "Mobile Remote"
        menu.delegate = self
        item.menu = menu
    }

    /// A phone outline drawn as a template image: black pixels + alpha, which
    /// the menu bar tints itself. Height 18 pt is the menu bar's own size.
    static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let body = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 1, width: 9, height: 16), xRadius: 2, yRadius: 2)
            body.lineWidth = 1.5
            NSColor.black.setStroke()
            body.stroke()
            // Screen area, slightly inset, and a home indicator.
            NSBezierPath(rect: NSRect(x: 6, y: 4, width: 6, height: 10)).fill()
            NSBezierPath(rect: NSRect(x: 7.5, y: 2.2, width: 3, height: 0.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Rebuilt every time it opens, so it always shows the live device list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = model.targets
        if targets.isEmpty {
            menu.addItem(withTitle: "Không có thiết bị nào", action: nil, keyEquivalent: "").isEnabled = false
        }
        for target in targets {
            let mirroring = model.mirroring.contains(target.id)
            let title = target.title + (mirroring ? " — đang phản chiếu" : target.isReady ? "" : " — chưa sẵn sàng")
            let entry = NSMenuItem(title: title, action: #selector(open(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = target.id
            entry.isEnabled = target.isReady
            entry.image = NSImage(systemSymbolName: Self.symbol(for: target), accessibilityDescription: nil)
            menu.addItem(entry)
        }
        for device in model.offlineRemembered {
            let entry = NSMenuItem(title: "\(device.model ?? device.serial) — ngoại tuyến, kết nối lại",
                                   action: #selector(reconnect(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = device.id
            entry.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Danh sách thiết bị…", action: #selector(home(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Cài đặt…", action: #selector(settings(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Thoát Mobile Remote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    private static func symbol(for target: MirrorTarget) -> String {
        switch target {
        case .ios: return "iphone"
        case .android(let device): return device.isUSB ? "cable.connector" : "wifi"
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if model.mirroring.contains(id) {
            model.onShow(id)
        } else if let target = model.targets.first(where: { $0.id == id }) {
            model.onOpen(target)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reconnect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let device = model.remembered.first(where: { $0.id == id }) else { return }
        model.onReconnect(device)
        showHome()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func home(_ sender: Any?) {
        showHome()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settings(_ sender: Any?) {
        showSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}
