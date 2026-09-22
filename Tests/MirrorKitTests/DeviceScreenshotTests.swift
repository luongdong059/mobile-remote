import AppKit
import Testing
@testable import MirrorKit

/// NSPasteboard is not thread-safe and Swift Testing runs suites in
/// parallel; these tests must not overlap each other or anything else.
@Suite(.serialized) @MainActor struct DeviceScreenshotTests {
    /// A 2x1 PNG, rendered here so the test does not depend on a device.
    private func samplePNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func copiesPNGAndTIFFToThePasteboard() throws {
        // A private pasteboard: the user's clipboard is left alone.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let png = try samplePNG()

        #expect(DeviceScreenshot.copy(png, to: pasteboard))
        #expect(pasteboard.data(forType: .png) == png)
        let pasted = try #require(NSImage(pasteboard: pasteboard))
        #expect(pasted.representations.first?.pixelsWide == 2)
        #expect(pasteboard.types?.contains(.tiff) == true)
    }

    @Test func replacesWhateverWasOnThePasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("cũ", forType: .string)

        DeviceScreenshot.copy(try samplePNG(), to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
