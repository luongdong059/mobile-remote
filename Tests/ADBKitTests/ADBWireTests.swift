import Foundation
import Testing
@testable import ADBKit

@Suite struct ADBWireTests {
    @Test func requestsAreHexLengthPrefixed() {
        #expect(String(decoding: ADBWire.request("host:version"), as: UTF8.self) == "000chost:version")
        #expect(String(decoding: ADBWire.request("host:transport:RFCW6067EBH"), as: UTF8.self)
            == "001ahost:transport:RFCW6067EBH")
    }

    @Test func parsesHexLengths() throws {
        #expect(try ADBWire.parseHexLength(Data("00a4".utf8)) == 164)
        #expect(throws: ADBError.self) { try ADBWire.parseHexLength(Data("zzzz".utf8)) }
    }

    @Test func syncHeadersAreLittleEndian() {
        #expect([UInt8](ADBWire.syncHeader("DATA", 0x0001_0000)) == [0x44, 0x41, 0x54, 0x41, 0x00, 0x00, 0x01, 0x00])
    }

    @Test func syncSendCarriesPathAndRegularFileMode() {
        let packet = ADBWire.syncSend(remotePath: "/data/local/tmp/x.jar", mode: 0o644)
        let spec = "/data/local/tmp/x.jar,33188"
        #expect([UInt8](packet.prefix(8)) == [0x53, 0x45, 0x4e, 0x44, UInt8(spec.utf8.count), 0, 0, 0])
        #expect(String(decoding: packet.dropFirst(8), as: UTF8.self) == spec)
    }
}

@Suite struct ADBDeviceTests {
    @Test func parsesDevicesLongListing() {
        let listing = """
            RFCW6067EBH            device usb:1048576X product:a34xdxx model:SM_A346E device:a34x transport_id:2
            emulator-5554          device product:sdk_gphone_arm64 model:Android_SDK_built_for_arm64 device:generic_arm64 transport_id:1
            R58M123ABC             unauthorized usb:1114112X transport_id:3

            """
        let devices = ADBDevice.parseList(listing)
        #expect(devices.map(\.serial) == ["RFCW6067EBH", "emulator-5554", "R58M123ABC"])
        #expect(devices.map(\.state) == [.device, .device, .unauthorized])
        #expect(devices.map(\.isUSB) == [true, false, true])
        #expect(devices[0].model == "SM A346E")
        #expect(devices[0].properties["transport_id"] == "2")
        #expect(devices[2].model == nil)
    }

    @Test func emptyListing() {
        #expect(ADBDevice.parseList("").isEmpty)
    }
}
