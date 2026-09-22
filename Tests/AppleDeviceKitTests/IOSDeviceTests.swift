import Testing
@testable import AppleDeviceKit

@Suite struct IOSDeviceTests {
    @Test func identityIsTheCoreMediaIOUID() {
        let device = IOSDevice(uid: "54E5A0BC-2C53-4135-8A3B-476C4CFD8A4D", name: "DongNguyen")
        #expect(device.id == device.uid)
    }

    @Test func onlyTheScreenDeviceModelIsRecognised() {
        // The phone's Continuity Camera reports its hardware model instead.
        #expect(ScreenCaptureDevices.screenModel == "iOS Device")
        #expect(ScreenCaptureDevices.screenModel != "iPhone11,6")
    }

    @Test func errorsExplainWhatTheUserCanDo() {
        #expect(IOSMirrorError.cameraAccessDenied.description.contains("Camera"))
        #expect(IOSMirrorError.noFrames.description.contains("Tin cậy"))
    }
}
