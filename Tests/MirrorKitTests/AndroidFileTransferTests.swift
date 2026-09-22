import Testing
@testable import MirrorKit

@Suite struct AndroidFileTransferTests {
    @Test func namesAreMadeSafeForTheShell() {
        #expect(AndroidFileTransfer.safeName("báo cáo (final).pdf") == "báo_cáo__final_.pdf")
        #expect(AndroidFileTransfer.safeName("app-1.2_debug.apk") == "app-1.2_debug.apk")
    }

    @Test func quotingHandlesSingleQuotes() {
        #expect(AndroidFileTransfer.shellQuoted("it's") == "'it'\\''s'")
    }
}
