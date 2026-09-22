import ADBKit
import Foundation
import Testing
@testable import ScrcpyKit

/// Layouts follow scrcpy v4.1 `app/src/device_msg.c`.
@Suite struct DeviceMessageTests {
    @Test func readsEveryMessageTypeThenEnds() throws {
        let reader = DeviceMessageReader(source: DataByteSource(
            [0x00, 0, 0, 0, 5] + Array("hello".utf8) // clipboard
            + [0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08] // clipboard ack
            + [0x02, 0, 42, 0, 3, 0xaa, 0xbb, 0xcc] // UHID output
        ))
        #expect(try reader.next() == .clipboard("hello"))
        #expect(try reader.next() == .clipboardAcknowledged(sequence: 0x0102_0304_0506_0708))
        #expect(try reader.next() == .uhidOutput(id: 42, data: Data([0xaa, 0xbb, 0xcc])))
        #expect(try reader.next() == nil)
    }

    @Test func clipboardKeepsVietnameseText() throws {
        let text = "Tiếng Việt có dấu"
        let utf8 = Array(text.utf8)
        let reader = DeviceMessageReader(source: DataByteSource([0x00, 0, 0, 0, UInt8(utf8.count)] + utf8))
        #expect(try reader.next() == .clipboard(text))
    }

    @Test func unknownTypesAndAbsurdSizesAreErrors() {
        #expect(throws: ScrcpyError.self) { try DeviceMessageReader(source: DataByteSource([0x09])).next() }
        #expect(throws: ScrcpyError.self) {
            try DeviceMessageReader(source: DataByteSource([0x00, 0x7f, 0xff, 0xff, 0xff])).next()
        }
    }

    @Test func keyPressIsDownThenUp() {
        #expect(ControlMessage.keyPress(.back) == [
            .injectKeycode(action: .down, keycode: 4), .injectKeycode(action: .up, keycode: 4),
        ])
    }
}
