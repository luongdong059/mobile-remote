import ADBKit
import AppKit

public enum ScreenshotError: Error, CustomStringConvertible {
    /// `screencap` printed something other than a PNG, usually an error message.
    case notAnImage(String)

    public var description: String {
        switch self {
        case .notAnImage(let output):
            return output.isEmpty ? "Điện thoại không trả về ảnh" : "Không chụp được màn hình: \(output)"
        }
    }
}

public enum DeviceScreenshot {
    /// Taken by the phone's own `screencap`, so it is lossless and at native
    /// resolution however the video stream is scaled or compressed.
    public static func capturePNG(adb: ADBClient = ADBClient(), serial: String) throws -> Data {
        let data = try adb.exec(serial: serial, "screencap -p")
        guard data.starts(with: [0x89, 0x50, 0x4e, 0x47]) else {
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            throw ScreenshotError.notAnImage(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// Offers the image as PNG, and as TIFF for apps that only paste classic
    /// image data.
    @discardableResult
    public static func copy(_ png: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        let tiff = NSImage(data: png)?.tiffRepresentation
        pasteboard.clearContents()
        pasteboard.declareTypes(tiff == nil ? [.png] : [.png, .tiff], owner: nil)
        let wrotePNG = pasteboard.setData(png, forType: .png)
        if let tiff { pasteboard.setData(tiff, forType: .tiff) }
        return wrotePNG
    }
}
