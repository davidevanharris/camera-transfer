import XCTest
@testable import CameraTransfer

final class RicohBLEDecodingTests: XCTestCase {

    func testPlainTextIsDecoded() {
        XCTAssertEqual(RicohBLEDecoding.text(from: Data("RICOH_123456".utf8)), "RICOH_123456")
        // Trailing NUL padding is common in fixed-size GATT values.
        XCTAssertEqual(RicohBLEDecoding.text(from: Data("abcd1234".utf8) + Data([0, 0, 0])), "abcd1234")
    }

    func testNonPrintableIsRejected() {
        XCTAssertNil(RicohBLEDecoding.text(from: Data()))
        XCTAssertNil(RicohBLEDecoding.text(from: Data([0, 0])))
        XCTAssertNil(RicohBLEDecoding.text(from: Data([0x8F, 0x12, 0xC3, 0x28, 0x01])), "invalid UTF-8 / control bytes")
        XCTAssertNil(RicohBLEDecoding.text(from: Data([0x41, 0x01, 0x42])), "embedded control character")
    }

    func testHexFormatting() {
        XCTAssertEqual(RicohBLEDecoding.hex(Data([0x01, 0xAB])), "01 AB")
        XCTAssertTrue(RicohBLEDecoding.hex(Data(repeating: 0, count: 40), limit: 4).hasSuffix("(40 bytes)"))
    }

    func testCameraNameMatching() {
        XCTAssertTrue(RicohBLEDecoding.looksLikeCamera(name: "GR_IV_123"))
        XCTAssertTrue(RicohBLEDecoding.looksLikeCamera(name: "RICOH GR IV"))
        XCTAssertFalse(RicohBLEDecoding.looksLikeCamera(name: "AirPods"))
        XCTAssertFalse(RicohBLEDecoding.looksLikeCamera(name: nil))
    }

    func testPowerState() {
        XCTAssertEqual(RicohBLEDecoding.powerIsOn(Data([0x01])), true)
        XCTAssertEqual(RicohBLEDecoding.powerIsOn(Data([0x00])), false)
        XCTAssertNil(RicohBLEDecoding.powerIsOn(Data()))
    }
}
