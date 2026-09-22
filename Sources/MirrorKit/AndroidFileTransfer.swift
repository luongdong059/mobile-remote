import ADBKit
import Foundation

/// Copies dropped files to an Android device: APKs are installed, anything
/// else lands in Download. Runs synchronously; call off the main thread.
public enum AndroidFileTransfer {
    public struct Outcome: Sendable {
        public let file: String
        public let detail: String
        public let succeeded: Bool
    }

    public static let downloadDirectory = "/sdcard/Download"
    static let stagingDirectory = "/data/local/tmp"

    public static func send(_ url: URL, to serial: String, adb: ADBClient = ADBClient()) -> Outcome {
        let name = url.lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "apk" {
                let staged = "\(stagingDirectory)/\(safeName(name))"
                try adb.push(serial: serial, data: data, to: staged)
                // -r: replace an installed version instead of failing on it.
                let output = try adb.run(serial: serial, "pm install -r \(shellQuoted(staged)); rm -f \(shellQuoted(staged))")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard output.contains("Success") else {
                    return Outcome(file: name, detail: "Cài đặt thất bại: \(output.suffix(160))", succeeded: false)
                }
                return Outcome(file: name, detail: "Đã cài \(name)", succeeded: true)
            }
            let remote = "\(downloadDirectory)/\(safeName(name))"
            try adb.push(serial: serial, data: data, to: remote)
            // Without this the file stays invisible to gallery-style apps.
            _ = try? adb.run(serial: serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(shellQuoted("file://" + remote))")
            return Outcome(file: name, detail: "Đã chép \(name) vào Download", succeeded: true)
        } catch {
            return Outcome(file: name, detail: "\(name): \(error)", succeeded: false)
        }
    }

    /// Keeps the name usable in a shell and on the device's filesystem.
    static func safeName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
    }

    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
