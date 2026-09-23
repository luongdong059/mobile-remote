import ADBKit
import Foundation

/// adb-over-Wi-Fi bookkeeping: runs the blocking adb calls off the main
/// thread and remembers addresses so they are reconnected at launch.
final class WiFiConnections: @unchecked Sendable {
    private let adb = ADBClient()
    private let queue = DispatchQueue(label: "mobile-remote.wifi", qos: .userInitiated)
    private static let savedKey = "wifiAddresses"

    static var savedAddresses: [String] {
        get { UserDefaults.standard.stringArray(forKey: savedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: savedKey) }
    }

    /// `report` gets a status line for the UI, on the main queue.
    func switchToWiFi(_ device: ADBDevice, report: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        run(report) { [adb] in
            guard let address = try adb.wifiAddress(serial: device.serial) else {
                return "\(device.model ?? device.serial) không có địa chỉ Wi-Fi. Hãy bật Wi-Fi trên điện thoại."
            }
            try adb.enableTCP(serial: device.serial)
            // adbd restarts on the new port; give it a moment.
            var lastError: Error?
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.5)
                do {
                    try adb.connect(address: address)
                    Self.remember(address)
                    return "Đã kết nối \(device.model ?? device.serial) qua Wi-Fi (\(address)). Có thể rút cáp."
                } catch { lastError = error }
            }
            throw lastError ?? ADBError.serverUnreachable(address)
        }
    }

    func connect(_ address: String, report: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        run(report) { [adb] in
            let reply = try adb.connect(address: address)
            Self.remember(address)
            return reply
        }
    }

    func pair(_ address: String, code: String, report: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        run(report) { [adb] in try adb.pair(address: address, code: code) + ". Giờ nhập địa chỉ kết nối (cổng khác cổng ghép nối) và bấm Kết nối." }
    }

    func disconnect(_ address: String, report: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        run(report) { [adb] in
            let reply = try adb.disconnect(address: address)
            Self.savedAddresses.removeAll { $0 == ADBClient.withPort(address) }
            return reply
        }
    }

    /// Called at launch: addresses used before are tried again quietly.
    func reconnectSaved() {
        let addresses = Self.savedAddresses
        guard !addresses.isEmpty else { return }
        queue.async { [adb] in
            for address in addresses { _ = try? adb.connect(address: address) }
        }
    }

    private static func remember(_ address: String) {
        let full = ADBClient.withPort(address)
        var saved = savedAddresses.filter { $0 != full }
        saved.insert(full, at: 0)
        savedAddresses = Array(saved.prefix(5))
    }

    private func run(_ report: @escaping @MainActor @Sendable (String, Bool) -> Void, _ body: @escaping @Sendable () throws -> String) {
        queue.async {
            let result = Result { try body() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let text): report(text, true)
                    case .failure(let error): report("\(error)", false)
                    }
                }
            }
        }
    }
}
