import Foundation
import Testing
@testable import ScrcpyKit

/// Expected bytes are copied from scrcpy v4.1 `app/tests/test_control_msg_serialize.c`.
@Suite struct ControlMessageTests {
    private func bytes(_ message: ControlMessage) -> [UInt8] {
        [UInt8](message.serialized())
    }

    @Test func injectKeycode() {
        let message = ControlMessage.injectKeycode(action: .up, keycode: 66, repeatCount: 5, metaState: 0x41)
        #expect(bytes(message) == [
            0x00,
            0x01, // AKEY_EVENT_ACTION_UP
            0x00, 0x00, 0x00, 0x42, // AKEYCODE_ENTER
            0x00, 0x00, 0x00, 0x05, // repeat
            0x00, 0x00, 0x00, 0x41, // AMETA_SHIFT_ON | AMETA_SHIFT_LEFT_ON
        ])
    }

    @Test func injectText() {
        #expect(bytes(.injectText("hello, world!")) == [0x01, 0x00, 0x00, 0x00, 0x0d] + Array("hello, world!".utf8))
    }

    @Test func injectTextIsCappedAt300Bytes() {
        let serialized = bytes(.injectText(String(repeating: "a", count: 400)))
        #expect(serialized.count == 5 + 300)
        #expect(Array(serialized[0..<5]) == [0x01, 0x00, 0x00, 0x01, 0x2c])
    }

    @Test func textIsTruncatedOnACharacterBoundary() {
        // "ệ" is 3 bytes in UTF-8, so 299 × "a" + "ệ" must drop the whole character.
        let serialized = bytes(.injectText(String(repeating: "a", count: 299) + "ệ"))
        #expect(serialized.count == 5 + 299)
        #expect(String(bytes: serialized[5...], encoding: .utf8) != nil)
    }

    @Test func injectTouch() {
        let message = ControlMessage.injectTouch(
            action: .down, pointerID: 0x1234_5678_8765_4321,
            position: ScreenPosition(x: 100, y: 200, screenWidth: 1080, screenHeight: 1920),
            pressure: 1.0, actionButton: .primary, buttons: .primary)
        #expect(bytes(message) == [
            0x02,
            0x00, // ACTION_DOWN
            0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21, // pointer id
            0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xc8, // 100 200
            0x04, 0x38, 0x07, 0x80, // 1080 1920
            0xff, 0xff, // pressure
            0x00, 0x00, 0x00, 0x01, // action button
            0x00, 0x00, 0x00, 0x01, // buttons
        ])
    }

    @Test func injectScroll() {
        let message = ControlMessage.injectScroll(
            position: ScreenPosition(x: 260, y: 1026, screenWidth: 1080, screenHeight: 1920),
            horizontal: 16, vertical: -16, buttons: .primary)
        #expect(bytes(message) == [
            0x03,
            0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02, // 260 1026
            0x04, 0x38, 0x07, 0x80, // 1080 1920
            0x7f, 0xff, // 16
            0x80, 0x00, // -16
            0x00, 0x00, 0x00, 0x01, // buttons
        ])
    }

    @Test func scrollIsClamped() {
        let position = ScreenPosition(x: 0, y: 0, screenWidth: 1, screenHeight: 1)
        let serialized = bytes(.injectScroll(position: position, horizontal: 100, vertical: -100))
        #expect(Array(serialized[13..<17]) == [0x7f, 0xff, 0x80, 0x00])
    }

    @Test func setClipboard() {
        let message = ControlMessage.setClipboard(sequence: 0x0102_0304_0506_0708, text: "hello, world!", paste: true)
        #expect(bytes(message) == [
            0x09,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // sequence
            0x01, // paste
            0x00, 0x00, 0x00, 0x0d, // text length
        ] + Array("hello, world!".utf8))
    }

    @Test func uhid() {
        let create = ControlMessage.uhidCreate(id: 42, vendorID: 0x1234, productID: 0x5678, name: "ABC",
                                               reportDescriptor: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]))
        #expect(bytes(create) == [
            0x0c,
            0, 42, // id
            0x12, 0x34, // vendor id
            0x56, 0x78, // product id
            3, 65, 66, 67, // "ABC"
            0, 11, // report descriptor size
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
        ])
        #expect(bytes(.uhidInput(id: 42, report: Data([1, 2, 3, 4, 5]))) == [0x0d, 0, 42, 0, 5, 1, 2, 3, 4, 5])
        #expect(bytes(.uhidDestroy(id: 42)) == [0x0e, 0, 42])
    }

    @Test func shortMessages() {
        #expect(bytes(.backOrScreenOn(action: .up)) == [0x04, 0x01])
        #expect(bytes(.expandNotificationPanel) == [0x05])
        #expect(bytes(.expandSettingsPanel) == [0x06])
        #expect(bytes(.collapsePanels) == [0x07])
        #expect(bytes(.getClipboard(copyKey: .copy)) == [0x08, 0x01])
        #expect(bytes(.setDisplayPower(on: true)) == [0x0a, 0x01])
        #expect(bytes(.rotateDevice) == [0x0b])
        #expect(bytes(.resetVideo) == [0x11])
    }

    @Test func specialPointerIDs() {
        #expect(PointerID.mouse == 0xffff_ffff_ffff_ffff)
        #expect(PointerID.genericFinger == 0xffff_ffff_ffff_fffe)
        #expect(PointerID.virtualFinger == 0xffff_ffff_ffff_fffd)
    }
}
