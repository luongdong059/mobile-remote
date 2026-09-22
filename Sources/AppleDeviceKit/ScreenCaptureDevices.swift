import CoreMediaIO
import Foundation

/// CoreMediaIO exposes a cabled iPhone's screen as a capture device, the way
/// QuickTime's "Movie Recording" sees it. The device only appears after the
/// process opts in, and then asynchronously.
enum ScreenCaptureDevices {
    /// Model UID CoreMediaIO gives the screen device (the phone's Continuity
    /// Camera shows up separately, with an "iPhoneXX,Y" model).
    static let screenModel = "iOS Device"

    static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func allowScreenCaptureDevices() {
        var address = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func current() -> [IOSDevice] {
        var address = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        var used: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return [] }
        return ids.compactMap { id in
            guard string(id, kCMIODevicePropertyModelUID) == screenModel,
                  let uid = string(id, kCMIODevicePropertyDeviceUID) else { return nil }
            return IOSDevice(uid: uid, name: string(id, kCMIOObjectPropertyName) ?? "iPhone")
        }
    }

    private static func string(_ id: CMIOObjectID, _ selector: Int) -> String? {
        var address = address(selector)
        var size: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectHasProperty(id, &address),
              CMIOObjectGetPropertyDataSize(id, &address, 0, nil, &size) == 0, size > 0 else { return nil }
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(id, &address, 0, nil, size, &used, $0)
        }
        guard status == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
