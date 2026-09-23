import AppKit
import SwiftUI

/// The device list window.
@MainActor
final class HomeWindowController {
    private let window: NSWindow

    init(model: DeviceListModel) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Mobile Remote"
        // The content draws its own header under a see-through title bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HomeView(model: model))
        window.center()
        window.setFrameAutosaveName("home")
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }
}
