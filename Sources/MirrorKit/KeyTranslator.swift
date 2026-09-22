import Foundation
import ScrcpyKit

/// Editing and navigation commands a key press can mean, independent of the
/// platform that will carry them out.
public enum KeyCommand: Hashable, Sendable {
    case enter, backspace, forwardDelete, tab, escape
    case up, down, left, right
    case home, end, pageUp, pageDown
    case copy, cut, selectAll, undo, redo
    /// ⌘V: the Mac clipboard's text goes to the phone and is pasted there.
    case paste(String)
}

/// Turns typed text and key commands into scrcpy control messages.
///
/// scrcpy's INJECT_TEXT only reaches characters the Android key map knows,
/// which excludes Vietnamese. Those go through the clipboard with the paste
/// flag instead, exactly what the user sees when pasting by hand.
public enum KeyTranslator {
    /// android.view.KeyEvent codes.
    static let keycodes: [KeyCommand: UInt32] = [
        .enter: 66, .backspace: 67, .forwardDelete: 112, .tab: 61, .escape: 111,
        .up: 19, .down: 20, .left: 21, .right: 22,
        .home: 122, .end: 123, .pageUp: 92, .pageDown: 93,
    ]
    static let metaCtrl: UInt32 = 0x1000 | 0x2000 // META_CTRL_ON | META_CTRL_LEFT_ON
    static let keycodeA: UInt32 = 29
    static let keycodeZ: UInt32 = 54

    public static func messages(forTyped text: String, clipboardSequence: inout UInt64) -> [ControlMessage] {
        guard !text.isEmpty else { return [] }
        if text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f }) {
            return [.injectText(text)]
        }
        clipboardSequence += 1
        return [.setClipboard(sequence: clipboardSequence, text: text, paste: true)]
    }

    public static func messages(for command: KeyCommand, clipboardSequence: inout UInt64) -> [ControlMessage] {
        if let keycode = keycodes[command] {
            return [.injectKeycode(action: .down, keycode: keycode), .injectKeycode(action: .up, keycode: keycode)]
        }
        switch command {
        case .copy: return [.getClipboard(copyKey: .copy)]
        case .cut: return [.getClipboard(copyKey: .cut)]
        case .paste(let text):
            guard !text.isEmpty else { return [] }
            clipboardSequence += 1
            return [.setClipboard(sequence: clipboardSequence, text: text, paste: true)]
        case .selectAll: return ctrl(keycodeA)
        case .undo: return ctrl(keycodeZ)
        case .redo: return ctrl(keycodeZ, extraMeta: 0x1 | 0x40) // + shift
        default: return []
        }
    }

    private static func ctrl(_ keycode: UInt32, extraMeta: UInt32 = 0) -> [ControlMessage] {
        let meta = metaCtrl | extraMeta
        return [.injectKeycode(action: .down, keycode: keycode, metaState: meta),
                .injectKeycode(action: .up, keycode: keycode, metaState: meta)]
    }
}
