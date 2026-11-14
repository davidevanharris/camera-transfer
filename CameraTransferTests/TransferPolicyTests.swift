import XCTest
@testable import CameraTransfer

final class TransferPolicyTests: XCTestCase {

    private func decide(_ mode: AutoTransferMode,
                        phone: Int?,
                        charging: Bool = false,
                        camera: CameraBatteryReading,
                        allowUnknown: Bool = true) -> TransferDecision {
        TransferPolicy.evaluate(mode: mode, phonePercent: phone, phoneCharging: charging,
                                camera: camera, allowWhenCameraBatteryUnknown: allowUnknown)
    }

    func testThresholds() {
        XCTAssertNil(AutoTransferMode.manual.threshold)
        XCTAssertEqual(AutoTransferMode.standard.threshold, 75)
        XCTAssertEqual(AutoTransferMode.batterySaver.threshold, 90)
        XCTAssertEqual(AutoTransferMode.gonnaChargeSoon.threshold, 25)
        XCTAssertEqual(AutoTransferMode.standard.rawValue, "default")
        XCTAssertEqual(AutoTransferMode.gonnaChargeSoon.displayName, "Gonna charge soon")
    }

    func testManualAlwaysDenies() {
        let decision = decide(.manual, phone: 100, camera: .percent(100))
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason.contains("Manual"))
    }

    func testDefaultModeBoundaries() {
        XCTAssertTrue(decide(.standard, phone: 76, camera: .percent(76)).allowed)
        XCTAssertFalse(decide(.standard, phone: 75, camera: .percent(90)).allowed, "exactly 75 must deny")
        XCTAssertFalse(decide(.standard, phone: 90, camera: .percent(75)).allowed, "exactly 75 must deny")
        XCTAssertFalse(decide(.standard, phone: 0, camera: .percent(100)).allowed)
    }

    func testBatterySaverBoundaries() {
        XCTAssertTrue(decide(.batterySaver, phone: 91, camera: .percent(100)).allowed)
        XCTAssertFalse(decide(.batterySaver, phone: 90, camera: .percent(100)).allowed)
        XCTAssertFalse(decide(.batterySaver, phone: 100, camera: .percent(90)).allowed)
    }

    func testGonnaChargeSoonBoundaries() {
        XCTAssertTrue(decide(.gonnaChargeSoon, phone: 26, camera: .percent(26)).allowed)
        XCTAssertFalse(decide(.gonnaChargeSoon, phone: 25, camera: .percent(80)).allowed)
        XCTAssertFalse(decide(.gonnaChargeSoon, phone: 80, camera: .percent(25)).allowed)
    }

    func testDenyReasonIsReadable() {
        XCTAssertEqual(decide(.standard, phone: 62, camera: .percent(100)).reason,
                       "Paused: phone at 62%, Default mode needs above 75%.")
        XCTAssertEqual(decide(.batterySaver, phone: 95, camera: .percent(40)).reason,
                       "Paused: camera at 40%, Battery saver mode needs above 90%.")
    }

    func testUnknownCameraBattery() {
        XCTAssertTrue(decide(.standard, phone: 80, camera: .unknown, allowUnknown: true).allowed)
        let denied = decide(.standard, phone: 80, camera: .unknown, allowUnknown: false)
        XCTAssertFalse(denied.allowed)
        XCTAssertTrue(denied.reason.contains("unknown"))
        // The phone check still applies when the camera is unknown.
        XCTAssertFalse(decide(.standard, phone: 50, camera: .unknown, allowUnknown: true).allowed)
    }

    func testNotApplicableCameraOnlyChecksPhone() {
        XCTAssertTrue(decide(.standard, phone: 80, camera: .notApplicable, allowUnknown: false).allowed)
        XCTAssertFalse(decide(.standard, phone: 70, camera: .notApplicable).allowed)
    }

    func testChargingPhonePassesPhoneCheck() {
        XCTAssertTrue(decide(.batterySaver, phone: 30, charging: true, camera: .percent(95)).allowed)
        XCTAssertFalse(decide(.batterySaver, phone: 30, charging: true, camera: .percent(50)).allowed,
                       "camera check still applies while charging")
    }

    func testUnknownPhoneBatteryIsAllowed() {
        // The Simulator reports -1, which the app maps to nil.
        let decision = decide(.standard, phone: nil, camera: .percent(80))
        XCTAssertTrue(decision.allowed)
        XCTAssertTrue(decision.reason.contains("phone battery unknown"))
    }
}
