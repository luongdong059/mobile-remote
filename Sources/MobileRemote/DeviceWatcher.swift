import ADBKit
import Foundation

/// Follows `host:track-devices` on a background thread and reports every
/// change on the main actor, reconnecting if the adb server goes away.
final class DeviceWatcher: @unchecked Sendable {
    enum Update: Sendable {
        case devices([ADBDevice])
        case unavailable(String)
    }

    private let adb = ADBClient()
    private let onUpdate: @MainActor @Sendable (Update) -> Void

    init(onUpdate: @escaping @MainActor @Sendable (Update) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                do {
                    try adb.ensureServerRunning()
                    try adb.trackDevices { devices in
                        deliver(.devices(devices))
                        return true
                    }
                } catch {
                    deliver(.unavailable("\(error)"))
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private func deliver(_ update: Update) {
        DispatchQueue.main.async { [onUpdate] in
            MainActor.assumeIsolated { onUpdate(update) }
        }
    }
}
