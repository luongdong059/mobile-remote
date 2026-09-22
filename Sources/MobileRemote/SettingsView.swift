import AppKit
import SwiftUI

/// Preferences for new sessions; windows already open keep their settings.
struct SettingsView: View {
    @AppStorage(AppSettings.codecKey) private var codec = "h265"
    @AppStorage(AppSettings.maxSizeKey) private var maxSize = 1600
    @AppStorage(AppSettings.bitRateKey) private var bitRate = 0
    @AppStorage(AppSettings.maxFpsKey) private var maxFps = 60
    @AppStorage(AppSettings.audioKey) private var audio = false
    @AppStorage("autoOpenOnPlug") private var autoOpen = true

    var body: some View {
        Form {
            Section("Video (Android)") {
                Picker("Codec", selection: $codec) {
                    Text("H.265 (HEVC), tự lùi về H.264 nếu cần").tag("h265")
                    Text("H.264").tag("h264")
                }
                Picker("Độ phân giải (cạnh dài)", selection: $maxSize) {
                    Text("Gốc").tag(0)
                    Text("1920 px").tag(1920)
                    Text("1600 px (mặc định)").tag(1600)
                    Text("1280 px").tag(1280)
                    Text("1024 px").tag(1024)
                }
                Picker("Tốc độ khung hình", selection: $maxFps) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                    Text("Không giới hạn").tag(0)
                }
                Picker("Bitrate", selection: $bitRate) {
                    Text("Mặc định (8 Mbps)").tag(0)
                    Text("4 Mbps").tag(4_000_000)
                    Text("12 Mbps").tag(12_000_000)
                    Text("20 Mbps").tag(20_000_000)
                }
                Toggle("Phát âm thanh của điện thoại trên Mac (Android 11+, có ghi vào video)", isOn: $audio)
            }
            Section("Chung") {
                Toggle("Tự động mở khi cắm máy qua USB", isOn: $autoOpen)
                LabeledContent("Thư mục ghi hình") {
                    HStack {
                        Text("~/Movies/Mobile Remote").foregroundStyle(.secondary)
                        Button("Mở") { NSWorkspace.shared.open(VideoKitRecordings.directory) }
                    }
                }
            }
            Text("Cài đặt video áp dụng cho cửa sổ mở sau này.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
    }
}

/// The settings window, created on first use.
@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cài đặt"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }
}
