import ADBKit
import Foundation

/// An Android device seen over Wi-Fi, kept so it can be reached again
/// without the cable.
struct RememberedDevice: Codable, Equatable, Identifiable, Sendable {
    /// The adb serial the device had over USB (also the start of its mDNS
    /// name), or the address when it was only ever seen over Wi-Fi.
    var serial: String
    var model: String?
    var address: String
    var lastConnected: Date

    var id: String { serial }
}

/// The persisted list, in UserDefaults as JSON.
enum RememberedDevices {
    private static let key = "rememberedDevices"

    static var all: [RememberedDevice] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([RememberedDevice].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    /// Records a device reached at `address`; `serial` is its USB serial
    /// when known, which lets mDNS find it after its port changes.
    static func remember(serial: String?, model: String?, address: String) {
        let full = ADBClient.withPort(address)
        var list = all.filter { $0.serial != (serial ?? full) && $0.address != full }
        list.insert(RememberedDevice(serial: serial ?? full, model: model, address: full, lastConnected: Date()), at: 0)
        all = Array(list.prefix(10))
    }

    static func forget(_ id: String) {
        all = all.filter { $0.id != id }
    }
}
