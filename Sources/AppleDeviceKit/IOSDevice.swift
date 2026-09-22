import Foundation

/// An iPhone or iPad plugged in over USB, as seen through CoreMediaIO.
public struct IOSDevice: Equatable, Sendable, Identifiable {
    /// The CoreMediaIO device UID; stable while the device stays plugged in.
    public let uid: String
    /// The name the user gave the device ("DongNguyen").
    public let name: String
    /// The device identifier usbmuxd knows it by; nil when it could not be
    /// matched (then the device is view-only).
    public let udid: String?

    public var id: String { uid }

    public init(uid: String, name: String, udid: String? = nil) {
        self.uid = uid
        self.name = name
        self.udid = udid
    }
}

public enum IOSMirrorError: Error, CustomStringConvertible {
    case cameraAccessDenied
    case deviceGone
    case noFrames
    case notIOSurfaceBacked

    public var description: String {
        switch self {
        case .cameraAccessDenied:
            return "Cần quyền Camera: iOS đưa màn hình điện thoại tới máy Mac dưới dạng một thiết bị video. Bật trong Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Camera."
        case .deviceGone: return "Thiết bị đã ngắt kết nối"
        case .noFrames: return "Không nhận được hình từ thiết bị. Hãy mở khóa điện thoại và bấm “Tin cậy” nếu được hỏi."
        case .notIOSurfaceBacked: return "Khung hình không hiển thị được"
        }
    }
}
