import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Run as a regular app (Dock icon, menu bar) even when launched without a bundle.
application.setActivationPolicy(.regular)
application.run()
