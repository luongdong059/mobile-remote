import CoreMediaIO
import Foundation

/// Reports the cabled iOS devices now and after every plug / unplug.
public final class IOSDeviceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mobile-remote.ios-devices")
    private let onChange: @Sendable ([IOSDevice]) -> Void
    private var last: [IOSDevice]?

    public init(onChange: @escaping @Sendable ([IOSDevice]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        ScreenCaptureDevices.allowScreenCaptureDevices()
        var address = ScreenCaptureDevices.address(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.publish()
        }
        // Devices trickle in over the first seconds after opting in.
        for delay in [0.0, 1.0, 3.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.publish() }
        }
    }

    private func publish() {
        // CoreMediaIO does not expose the UDID; with one cabled device the
        // match is certain, otherwise control is left off for safety.
        let cabled = (try? USBMuxClient.listDevices()) ?? []
        let devices = ScreenCaptureDevices.current().sorted { $0.name < $1.name }.map { device -> IOSDevice in
            IOSDevice(uid: device.uid, name: device.name, udid: cabled.count == 1 ? cabled[0].udid : nil)
        }
        guard devices != last else { return }
        last = devices
        onChange(devices)
    }
}
