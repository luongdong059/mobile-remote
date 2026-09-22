import AppKit

enum AppResources {
    /// From Contents/Resources in the packaged app, from the SwiftPM resource
    /// bundle under `swift run`.
    static let logo: NSImage? = {
        let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png")
            ?? Bundle.module.url(forResource: "AppLogo", withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()
}
