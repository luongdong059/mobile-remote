import ADBKit
import AppleDeviceKit
import Foundation
import Observation

/// Something the app can mirror: an Android phone through adb, or an iPhone
/// through its USB screen-capture device.
enum MirrorTarget: Identifiable, Equatable {
    case android(ADBDevice)
    case ios(IOSDevice)

    var id: String {
        switch self {
        case .android(let device): return "android:" + device.serial
        case .ios(let device): return "ios:" + device.uid
        }
    }

    var title: String {
        switch self {
        case .android(let device): return device.model ?? device.serial
        case .ios(let device): return device.name
        }
    }

    var isReady: Bool {
        switch self {
        case .android(let device): return device.state == .device
        case .ios: return true
        }
    }

    var isUSB: Bool {
        switch self {
        case .android(let device): return device.isUSB
        case .ios: return true
        }
    }
}

/// What the home window shows; the app delegate keeps it up to date.
@MainActor
@Observable
final class DeviceListModel {
    var androidDevices: [ADBDevice] = []
    var iosDevices: [IOSDevice] = []
    /// Target ids that currently have a mirror window.
    var mirroring: Set<String> = []
    /// Set while the adb server cannot be reached.
    var adbError: String?
    private(set) var autoOpen = UserDefaults.standard.object(forKey: autoOpenKey) as? Bool ?? true

    @ObservationIgnored var onOpen: (MirrorTarget) -> Void = { _ in }
    @ObservationIgnored var onShow: (String) -> Void = { _ in }
    @ObservationIgnored var onClose: (String) -> Void = { _ in }

    private static let autoOpenKey = "autoOpenOnPlug"

    /// Cabled devices first, iPhones before Android within each group.
    var targets: [MirrorTarget] {
        let all = iosDevices.map(MirrorTarget.ios) + androidDevices.map(MirrorTarget.android)
        return all.sorted { ($0.isUSB ? 0 : 1, $0.title) < ($1.isUSB ? 0 : 1, $1.title) }
    }

    func setAutoOpen(_ value: Bool) {
        autoOpen = value
        UserDefaults.standard.set(value, forKey: Self.autoOpenKey)
    }
}
