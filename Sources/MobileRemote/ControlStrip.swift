import ScrcpyKit
import SwiftUI

/// Hardware / navigation keys the strip can offer.
enum DeviceKey: CaseIterable {
    case back, home, recents, volumeUp, volumeDown, power, screenOff

    var androidKeycode: AndroidKeycode {
        switch self {
        case .back: return .back
        case .home: return .home
        case .recents: return .appSwitch
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .power: return .power
        case .screenOff: return .power // never sent: handled as a display-power toggle
        }
    }

    /// WebDriverAgent `pressButton` names; nil where iOS has no such key.
    var wdaButton: String? {
        switch self {
        case .home: return "home"
        case .volumeUp: return "volumeUp"
        case .volumeDown: return "volumeDown"
        case .power: return "lock"
        case .back, .recents, .screenOff: return nil
        }
    }
}

/// The vertical glass button strip beside the mirrored screen.
struct ControlStrip: View {
    /// Which keys to show; empty when the device takes no input.
    let keys: [DeviceKey]
    var isRecording = false
    var isScreenOff = false
    let onKey: (DeviceKey) -> Void
    let onScreenshot: () -> Void
    let onRecord: () -> Void

    var body: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                let navigation = keys.filter { [.back, .home, .recents].contains($0) }
                let hardware = keys.filter { [.volumeUp, .volumeDown, .power, .screenOff].contains($0) }
                if !navigation.isEmpty {
                    pill { ForEach(navigation, id: \.self) { key($0) } }
                }
                if !hardware.isEmpty {
                    pill { ForEach(hardware, id: \.self) { key($0) } }
                }
                Spacer(minLength: 0)
                pill {
                    icon("camera", "Chép ảnh màn hình vào clipboard (⌃⌘C)", action: onScreenshot)
                    icon(isRecording ? "stop.circle.fill" : "record.circle",
                         isRecording ? "Dừng ghi màn hình (⌃⌘R)" : "Ghi màn hình (⌃⌘R)", action: onRecord)
                        .foregroundStyle(isRecording ? Color.red : Color.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 2) { content() }
            .padding(.vertical, 6)
            .frame(width: 42)
            .glass(in: Capsule(), interactive: true)
    }

    private func key(_ key: DeviceKey) -> some View {
        let (symbol, label): (String, String) = {
            switch key {
            case .back: return ("arrowtriangle.backward", "Quay lại")
            case .home: return ("circle", "Màn hình chính")
            case .recents: return ("square", "Đa nhiệm")
            case .volumeUp: return ("speaker.plus", "Tăng âm lượng")
            case .volumeDown: return ("speaker.minus", "Giảm âm lượng")
            case .power: return ("power", "Nguồn / khóa")
            case .screenOff: return (isScreenOff ? "sun.max.fill" : "moon", isScreenOff ? "Bật lại màn hình điện thoại" : "Tắt màn hình điện thoại (vẫn phản chiếu)")
            }
        }()
        return icon(symbol, label) { onKey(key) }
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Red dot and elapsed time shown while recording.
struct RecordingBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(text).font(.caption.monospacedDigit().weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glass(in: Capsule())
    }
}

/// Short message floating over the video.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glass(in: Capsule())
            .padding(6) // room for the glass edge highlight
    }
}
