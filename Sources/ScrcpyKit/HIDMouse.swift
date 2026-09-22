import Foundation

/// A relative HID mouse for `uhidCreate`. Unlike injected mouse events, a UHID
/// device goes through Android's input reader, so the phone draws a real cursor.
public enum HIDMouse {
    public static let deviceID: UInt16 = 2
    public static let name = "Mobile Remote Mouse"

    /// 5 buttons, then relative X, Y and wheel as signed bytes.
    public static let reportDescriptor = Data([
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x02, // Usage (Mouse)
        0xa1, 0x01, // Collection (Application)
        0x09, 0x01, //   Usage (Pointer)
        0xa1, 0x00, //   Collection (Physical)
        0x05, 0x09, //     Usage Page (Buttons)
        0x19, 0x01, //     Usage Minimum (1)
        0x29, 0x05, //     Usage Maximum (5)
        0x15, 0x00, //     Logical Minimum (0)
        0x25, 0x01, //     Logical Maximum (1)
        0x95, 0x05, //     Report Count (5)
        0x75, 0x01, //     Report Size (1)
        0x81, 0x02, //     Input (Data, Variable, Absolute)
        0x95, 0x01, //     Report Count (1)
        0x75, 0x03, //     Report Size (3)
        0x81, 0x01, //     Input (Constant): padding
        0x05, 0x01, //     Usage Page (Generic Desktop)
        0x09, 0x30, //     Usage (X)
        0x09, 0x31, //     Usage (Y)
        0x09, 0x38, //     Usage (Wheel)
        0x15, 0x81, //     Logical Minimum (-127)
        0x25, 0x7f, //     Logical Maximum (127)
        0x75, 0x08, //     Report Size (8)
        0x95, 0x03, //     Report Count (3)
        0x81, 0x06, //     Input (Data, Variable, Relative)
        0xc0, //   End Collection
        0xc0, // End Collection
    ])

    public static func report(buttons: UInt8 = 0, dx: Int8 = 0, dy: Int8 = 0, wheel: Int8 = 0) -> Data {
        Data([buttons, UInt8(bitPattern: dx), UInt8(bitPattern: dy), UInt8(bitPattern: wheel)])
    }

    public static var create: ControlMessage {
        .uhidCreate(id: deviceID, name: name, reportDescriptor: reportDescriptor)
    }
}
