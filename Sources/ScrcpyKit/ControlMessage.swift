import Foundation

public enum KeyAction: UInt8, Sendable {
    case down = 0
    case up = 1
}

/// `MotionEvent` actions.
public enum TouchAction: UInt8, Sendable {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case hoverMove = 7
    case hoverEnter = 9
    case hoverExit = 10
}

/// `MotionEvent` button bits.
public struct MouseButtons: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let primary = MouseButtons(rawValue: 1 << 0)
    public static let secondary = MouseButtons(rawValue: 1 << 1)
    public static let tertiary = MouseButtons(rawValue: 1 << 2)
}

/// Pointer ids with a special meaning for the server. Events are injected as a
/// real mouse only for `mouse` with a hover action or a non-primary button;
/// everything else is injected as a touchscreen finger.
public enum PointerID {
    public static let mouse = UInt64(bitPattern: -1)
    public static let genericFinger = UInt64(bitPattern: -2)
    public static let virtualFinger = UInt64(bitPattern: -3)
}

public struct ScreenPosition: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    /// Must equal the size from the latest session packet, otherwise the
    /// server silently drops the event.
    public var screenWidth: UInt16
    public var screenHeight: UInt16

    public init(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16) {
        self.x = x
        self.y = y
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

public enum CopyKey: UInt8, Sendable {
    case none = 0
    case copy = 1
    case cut = 2
}

/// Client → device messages, serialized as in scrcpy's `control_msg.c`.
public enum ControlMessage: Equatable, Sendable {
    case injectKeycode(action: KeyAction, keycode: UInt32, repeatCount: UInt32 = 0, metaState: UInt32 = 0)
    /// ASCII-ish only: the server maps characters through the device key map.
    case injectText(String)
    case injectTouch(action: TouchAction, pointerID: UInt64, position: ScreenPosition,
                     pressure: Float, actionButton: MouseButtons = [], buttons: MouseButtons = [])
    /// Scroll amounts are clamped to [-16, 16].
    case injectScroll(position: ScreenPosition, horizontal: Float, vertical: Float, buttons: MouseButtons = [])
    case backOrScreenOn(action: KeyAction)
    case expandNotificationPanel
    case expandSettingsPanel
    case collapsePanels
    case getClipboard(copyKey: CopyKey)
    case setClipboard(sequence: UInt64, text: String, paste: Bool)
    case setDisplayPower(on: Bool)
    case rotateDevice
    /// Creates a virtual HID device on the phone (needs /dev/uhid access).
    case uhidCreate(id: UInt16, vendorID: UInt16 = 0, productID: UInt16 = 0, name: String, reportDescriptor: Data)
    case uhidInput(id: UInt16, report: Data)
    case uhidDestroy(id: UInt16)
    /// Restarts capture and encoding; a new session, config and key frame follow.
    case resetVideo

    static let injectTextMaxBytes = 300
    static let messageMaxBytes = 1 << 18

    public func serialized() -> Data {
        var data = Data()
        switch self {
        case .injectKeycode(let action, let keycode, let repeatCount, let metaState):
            data.append(0)
            data.append(action.rawValue)
            data.appendBigEndian(keycode)
            data.appendBigEndian(repeatCount)
            data.appendBigEndian(metaState)
        case .injectText(let text):
            data.append(1)
            data.appendLengthPrefixed(text, maxBytes: Self.injectTextMaxBytes)
        case .injectTouch(let action, let pointerID, let position, let pressure, let actionButton, let buttons):
            data.append(2)
            data.append(action.rawValue)
            data.appendBigEndian(pointerID)
            data.append(position)
            data.appendBigEndian(Self.unsignedFixedPoint16(pressure))
            data.appendBigEndian(actionButton.rawValue)
            data.appendBigEndian(buttons.rawValue)
        case .injectScroll(let position, let horizontal, let vertical, let buttons):
            data.append(3)
            data.append(position)
            data.appendBigEndian(UInt16(bitPattern: Self.signedFixedPoint16(horizontal / 16)))
            data.appendBigEndian(UInt16(bitPattern: Self.signedFixedPoint16(vertical / 16)))
            data.appendBigEndian(buttons.rawValue)
        case .backOrScreenOn(let action):
            data.append(4)
            data.append(action.rawValue)
        case .expandNotificationPanel:
            data.append(5)
        case .expandSettingsPanel:
            data.append(6)
        case .collapsePanels:
            data.append(7)
        case .getClipboard(let copyKey):
            data.append(8)
            data.append(copyKey.rawValue)
        case .setClipboard(let sequence, let text, let paste):
            data.append(9)
            data.appendBigEndian(sequence)
            data.append(paste ? 1 : 0)
            data.appendLengthPrefixed(text, maxBytes: Self.messageMaxBytes - 14)
        case .setDisplayPower(let on):
            data.append(10)
            data.append(on ? 1 : 0)
        case .rotateDevice:
            data.append(11)
        case .uhidCreate(let id, let vendorID, let productID, let name, let reportDescriptor):
            data.append(12)
            data.appendBigEndian(id)
            data.appendBigEndian(vendorID)
            data.appendBigEndian(productID)
            let nameBytes = Array(name.utf8.prefix(127))
            data.append(UInt8(nameBytes.count))
            data.append(contentsOf: nameBytes)
            data.appendBigEndian(UInt16(reportDescriptor.count))
            data.append(reportDescriptor)
        case .uhidInput(let id, let report):
            data.append(13)
            data.appendBigEndian(id)
            data.appendBigEndian(UInt16(report.count))
            data.append(report)
        case .uhidDestroy(let id):
            data.append(14)
            data.appendBigEndian(id)
        case .resetVideo:
            data.append(17)
        }
        return data
    }

    /// [0, 1] → u16 fixed point, with 1.0 saturating to 0xffff.
    static func unsignedFixedPoint16(_ value: Float) -> UInt16 {
        let scaled = UInt32(min(max(value, 0), 1) * 65536)
        return UInt16(min(scaled, 0xffff))
    }

    /// [-1, 1] → i16 fixed point, with 1.0 saturating to 0x7fff.
    static func signedFixedPoint16(_ value: Float) -> Int16 {
        let scaled = Int32(min(max(value, -1), 1) * 32768)
        return Int16(min(scaled, 0x7fff))
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(_ position: ScreenPosition) {
        appendBigEndian(position.x)
        appendBigEndian(position.y)
        appendBigEndian(position.screenWidth)
        appendBigEndian(position.screenHeight)
    }

    /// u32 byte length + UTF-8, truncated on a character boundary.
    mutating func appendLengthPrefixed(_ text: String, maxBytes: Int) {
        var utf8 = Array(text.utf8)
        if utf8.count > maxBytes {
            var end = maxBytes
            while end > 0, utf8[end] & 0xc0 == 0x80 { end -= 1 }
            utf8.removeSubrange(end...)
        }
        appendBigEndian(UInt32(utf8.count))
        append(contentsOf: utf8)
    }
}
