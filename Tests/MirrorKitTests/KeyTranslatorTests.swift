import Testing
@testable import MirrorKit
@testable import ScrcpyKit

@Suite struct KeyTranslatorTests {
    @Test func asciiGoesAsText() {
        var sequence: UInt64 = 0
        #expect(KeyTranslator.messages(forTyped: "hello 123!", clipboardSequence: &sequence) == [.injectText("hello 123!")])
        #expect(sequence == 0)
    }

    @Test func vietnameseGoesThroughTheClipboardWithPaste() {
        var sequence: UInt64 = 0
        let messages = KeyTranslator.messages(forTyped: "xin chào", clipboardSequence: &sequence)
        #expect(messages == [.setClipboard(sequence: 1, text: "xin chào", paste: true)])
        _ = KeyTranslator.messages(forTyped: "ệ", clipboardSequence: &sequence)
        #expect(sequence == 2)
    }

    @Test func navigationKeysAreKeyPresses() {
        var sequence: UInt64 = 0
        #expect(KeyTranslator.messages(for: .enter, clipboardSequence: &sequence) == [
            .injectKeycode(action: .down, keycode: 66), .injectKeycode(action: .up, keycode: 66),
        ])
        #expect(KeyTranslator.messages(for: .backspace, clipboardSequence: &sequence).first == .injectKeycode(action: .down, keycode: 67))
        #expect(KeyTranslator.messages(for: .left, clipboardSequence: &sequence).first == .injectKeycode(action: .down, keycode: 21))
    }

    @Test func editingShortcuts() {
        var sequence: UInt64 = 5
        #expect(KeyTranslator.messages(for: .copy, clipboardSequence: &sequence) == [.getClipboard(copyKey: .copy)])
        #expect(KeyTranslator.messages(for: .cut, clipboardSequence: &sequence) == [.getClipboard(copyKey: .cut)])
        #expect(KeyTranslator.messages(for: .paste("abc"), clipboardSequence: &sequence) == [.setClipboard(sequence: 6, text: "abc", paste: true)])
        #expect(KeyTranslator.messages(for: .paste(""), clipboardSequence: &sequence).isEmpty)
        let selectAll = KeyTranslator.messages(for: .selectAll, clipboardSequence: &sequence)
        #expect(selectAll == [.injectKeycode(action: .down, keycode: 29, metaState: 0x3000),
                              .injectKeycode(action: .up, keycode: 29, metaState: 0x3000)])
    }

    @Test func emptyTextSendsNothing() {
        var sequence: UInt64 = 0
        #expect(KeyTranslator.messages(forTyped: "", clipboardSequence: &sequence).isEmpty)
    }
}
