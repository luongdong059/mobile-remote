import ADBKit
import Foundation

/// adb-over-Wi-Fi bookkeeping: runs the blocking adb calls off the main
/// thread and remembers addresses so they are reconnected at launch.
final class WiFiConnections: @unchecked Sendable {
    private let adb = ADBClient()
    private let queue = DispatchQueue(label: "mobile-remote.wifi", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    /// Serials of remembered devices the app is currently trying to reach.
    private let lock = NSLock()
    private var reconnecting: Set<String> = []

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
                    RememberedDevices.remember(serial: device.serial, model: device.model, address: address)
                    return "Đã kết nối \(device.model ?? device.serial) qua Wi-Fi (\(address)). Có thể rút cáp."
                } catch { lastError = error }
            }
            throw lastError ?? ADBError.serverUnreachable(address)
        }
    }

    func connect(_ address: String, report: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        run(report) { [adb] in
            let reply = try adb.connect(address: address)
            let full = ADBClient.withPort(address)
            let model = (try? adb.devices())?.first { $0.serial == full }?.model
            RememberedDevices.remember(serial: nil, model: model, address: full)
            return reply
        }
    }

    func pair(_ address: String, code: String, report: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        run(report) { [adb] in try adb.pair(address: address, code: code) + ". Giờ nhập địa chỉ kết nối (cổng khác cổng ghép nối) và bấm Kết nối." }
    }

    func disconnect(_ address: String, report: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        run(report) { [adb] in try adb.disconnect(address: address) }
    }

    /// Tries a remembered device now: by its saved address, or by the mDNS
    /// service that carries its serial (wireless debugging picks a new port
    /// after every reboot). `onResult` runs on the main queue.
    func reconnect(_ device: RememberedDevice, onResult: (@MainActor @Sendable (String, Bool) -> Void)? = nil) {
        let inProgress = lock.withLock { !reconnecting.insert(device.serial).inserted }
        guard !inProgress else { return }
        queue.async { [self] in
            defer { lock.withLock { _ = reconnecting.remove(device.serial) } }
            let result = Result { try attempt(device) }
            guard let onResult else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let text): onResult(text, true)
                    case .failure(let error): onResult("\(error)", false)
                    }
                }
            }
        }
    }

    private func attempt(_ device: RememberedDevice) throws -> String {
        let services = (try? adb.mdnsServices()) ?? []
        // Prefer whatever mDNS says now: the address may have changed.
        for service in services where service.name.contains(device.serial) || service.address == device.address {
            if let reply = try? adb.connect(address: service.address) {
                RememberedDevices.remember(serial: device.serial, model: device.model, address: service.address)
                return reply
            }
        }
        // A dead address costs the adb server over a minute; probe first.
        guard ADBClient.isReachable(device.address) else {
            throw ADBError.serverUnreachable("\(device.address) không phản hồi. Máy có đang bật, cùng Wi-Fi, và chưa khởi động lại?")
        }
        let reply = try adb.connect(address: device.address)
        RememberedDevices.remember(serial: device.serial, model: device.model, address: device.address)
        return reply
    }

    /// Keeps trying remembered devices that are offline, every 20 s.
    /// `offline` is asked on the main queue for the current list.
    func startReconnecting(offline: @escaping @MainActor @Sendable () -> [RememberedDevice]) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 20)
        timer.setEventHandler { [weak self] in
            // The timer fires on the main queue, where `offline` may be asked.
            let devices = MainActor.assumeIsolated { offline() }
            guard let self else { return }
            for device in devices { reconnect(device) }
        }
        timer.resume()
        self.timer = timer
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
