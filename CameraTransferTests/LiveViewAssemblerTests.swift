import XCTest
@testable import CameraTransfer

final class LiveViewAssemblerTests: XCTestCase {

    /// Builds one RTP-style packet. `extensionWords` adds an extension header of that many 32-bit words.
    private func packet(first: Bool, last: Bool, sequence: UInt16, extensionWords: Int = 0, payload: [UInt8]) -> Data {
        var bytes: [UInt8] = []
        bytes.append(first ? 0x90 : 0x80)
        bytes.append(last ? 0xE0 : 0x60)
        bytes.append(UInt8(sequence >> 8))
        bytes.append(UInt8(sequence & 0xFF))
        bytes.append(contentsOf: [0, 0, 0, 1])       // frame id
        bytes.append(contentsOf: [0, 0, 0, 9])       // stream id
        if first {
            bytes.append(contentsOf: [0xAB, 0xCD])   // extension profile
            bytes.append(UInt8(extensionWords >> 8))
            bytes.append(UInt8(extensionWords & 0xFF))
            bytes.append(contentsOf: [UInt8](repeating: 0x11, count: extensionWords * 4))
        }
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    func testThreePacketFrameIsReassembled() {
        var assembler = LiveViewAssembler()
        let jpeg: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 4, 5, 6, 7, 8, 0xFF, 0xD9]
        XCTAssertNil(assembler.append(packet: packet(first: true, last: false, sequence: 0, extensionWords: 2, payload: Array(jpeg[0..<4]))))
        XCTAssertNil(assembler.append(packet: packet(first: false, last: false, sequence: 1, payload: Array(jpeg[4..<8]))))
        let frame = assembler.append(packet: packet(first: false, last: true, sequence: 2, payload: Array(jpeg[8...])))
        XCTAssertEqual(frame, Data(jpeg))
    }

    func testMiddlePacketWithoutStartIsIgnored() {
        var assembler = LiveViewAssembler()
        XCTAssertNil(assembler.append(packet: packet(first: false, last: true, sequence: 5, payload: [0xFF, 0xD8, 0xFF, 0xD9])))
    }

    func testSecondFrameDoesNotContainTheFirst() {
        var assembler = LiveViewAssembler()
        let one: [UInt8] = [0xFF, 0xD8, 0xAA, 0xFF, 0xD9]
        let two: [UInt8] = [0xFF, 0xD8, 0xBB, 0xBB, 0xFF, 0xD9]
        XCTAssertNil(assembler.append(packet: packet(first: true, last: false, sequence: 0, payload: Array(one[0..<2]))))
        XCTAssertEqual(assembler.append(packet: packet(first: false, last: true, sequence: 1, payload: Array(one[2...]))), Data(one))
        XCTAssertNil(assembler.append(packet: packet(first: true, last: false, sequence: 2, payload: Array(two[0..<3]))))
        XCTAssertEqual(assembler.append(packet: packet(first: false, last: true, sequence: 3, payload: Array(two[3...]))), Data(two))
    }

    func testLeadingMetadataBeforeTheJPEGIsDropped() {
        let data = Data([0x00, 0x01, 0x02, 0xFF, 0xD8, 0x10, 0xFF, 0xD9, 0x00])
        XCTAssertEqual(LiveViewAssembler.trimToJPEG(data), Data([0xFF, 0xD8, 0x10, 0xFF, 0xD9]))
    }

    func testDataWithoutJPEGMarkersGivesNil() {
        XCTAssertNil(LiveViewAssembler.trimToJPEG(Data([1, 2, 3, 4])))
    }

    func testShortPacketIsIgnored() {
        var assembler = LiveViewAssembler()
        XCTAssertNil(assembler.append(packet: Data([0x90, 0x60, 0, 0])))
    }

    func testSelfTestReplyMatching() {
        XCTAssertTrue(FTPSelfTest.reply("220 Camera Transfer ready", hasCode: "220"))
        XCTAssertTrue(FTPSelfTest.reply("220-Hello\r\n220 Ready", hasCode: "220"))
        XCTAssertFalse(FTPSelfTest.reply("530 Login incorrect.", hasCode: "230"))
    }
}
