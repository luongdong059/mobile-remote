import Foundation

/// `android.view.KeyEvent` key codes used for navigation and hardware buttons.
public enum AndroidKeycode: UInt32, Sendable {
    case home = 3
    case back = 4
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case appSwitch = 187
}

extension ControlMessage {
    /// A full press: key down followed by key up.
    public static func keyPress(_ keycode: AndroidKeycode) -> [ControlMessage] {
        [.injectKeycode(action: .down, keycode: keycode.rawValue),
         .injectKeycode(action: .up, keycode: keycode.rawValue)]
    }
}
