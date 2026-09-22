import ADBKit
import AppleDeviceKit
import SwiftUI

struct HomeView: View {
    let model: DeviceListModel

    var body: some View {
        ZStack {
            backdrop
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = model.adbError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassCard(cornerRadius: 14)
                }
                devices
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 40) // clears the transparent title bar
            .padding(.bottom, 18)
        }
        .frame(minWidth: 540, minHeight: 440)
        .ignoresSafeArea()
    }

    /// Soft colour behind the glass, in the logo's blue and orange.
    private var backdrop: some View {
        ZStack {
            WindowBackdrop()
            Circle()
                .fill(Color(red: 0.29, green: 0.64, blue: 0.91).opacity(0.35))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: -170, y: -150)
            Circle()
                .fill(Color.orange.opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 100)
                .offset(x: 190, y: 170)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let logo = AppResources.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Mobile Remote").font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let targets = model.targets
        if targets.isEmpty { return "Phản chiếu và điều khiển điện thoại Android, phản chiếu iPhone" }
        return "\(targets.count) thiết bị · \(targets.filter(\.isReady).count) sẵn sàng"
    }

    @ViewBuilder
    private var devices: some View {
        if model.targets.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Chưa có thiết bị nào").font(.headline)
                Text("Cắm điện thoại qua cáp USB. Android cần bật USB debugging; iPhone cần bấm “Tin cậy”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard(cornerRadius: 22)
        } else {
            ScrollView {
                GlassGroup(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(model.targets) { target in
                            DeviceCard(target: target, isMirroring: model.mirroring.contains(target.id), model: model)
                        }
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.never)
        }
    }

    private var footer: some View {
        Toggle("Tự động mở khi cắm máy qua USB",
               isOn: Binding(get: { model.autoOpen }, set: { model.setAutoOpen($0) }))
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: 16)
    }
}

private struct DeviceCard: View {
    let target: MirrorTarget
    let isMirroring: Bool
    let model: DeviceListModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(status.color)
                .frame(width: 40, height: 40)
                .glass(in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(target.title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(status.text, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(status.color)
            }

            Spacer(minLength: 8)

            if isMirroring {
                Button("Hiện cửa sổ") { model.onShow(target.id) }.glassButton()
                Button("Ngắt") { model.onClose(target.id) }.glassButton()
            } else if target.isReady {
                Button("Mở") { model.onOpen(target) }
                    .glassButton(prominent: true)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 20)
    }

    private var symbol: String {
        switch target {
        case .android(let device): return device.isUSB ? "cable.connector" : "wifi"
        case .ios: return "iphone"
        }
    }

    private var subtitle: String {
        switch target {
        case .android(let device): return "\(device.serial) · Android · \(device.isUSB ? "USB" : "Mạng / máy ảo")"
        case .ios: return "iPhone / iPad · USB · chỉ xem, chưa điều khiển được"
        }
    }

    private var status: (text: String, color: Color) {
        if isMirroring { return ("Đang phản chiếu", .blue) }
        switch target {
        case .ios:
            return ("Sẵn sàng", .green)
        case .android(let device):
            switch device.state {
            case .device:
                return ("Sẵn sàng", .green)
            case .unauthorized:
                return ("Chưa cấp quyền: hãy chọn “Cho phép” trong hộp thoại USB debugging trên điện thoại", .orange)
            case .offline:
                return ("Offline: hãy rút cáp và cắm lại", .orange)
            case .other(let raw):
                return (raw, .secondary)
            }
        }
    }
}
