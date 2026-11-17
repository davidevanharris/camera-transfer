import XCTest
@testable import CameraTransfer

final class PTPIPCodecTests: XCTestCase {

    func testPacketHeaderIsLengthThenType() {
        let packet = [UInt8](PTPIPCodec.packet(.probeResponse))
        XCTAssertEqual(packet, [8, 0, 0, 0, 14, 0, 0, 0])
    }

    func testInitCommandRequestLayout() {
        let guid = [UInt8](repeating: 0xAB, count: 16)
        let packet = [UInt8](PTPIPCodec.initCommandRequest(guid: guid, name: "Hi"))
        // 8 header + 16 GUID + "Hi" as UTF-16 (4) + terminator (2) + version (4)
        XCTAssertEqual(packet.count, 34)
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 0), 34)
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 4), 1)
        XCTAssertEqual(Array(packet[8..<24]), guid)
        XCTAssertEqual(Array(packet[24..<30]), [0x48, 0, 0x69, 0, 0, 0])
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 30), 0x0001_0000)
    }

    func testCommandRequestWithoutData() {
        let packet = [UInt8](PTPIPCodec.commandRequest(code: 0x1009, transactionID: 7,
                                                       parameters: [0xFFFF_C002], hasDataOut: false))
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 0), 22)
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 4), 6)
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 8), 1)
        XCTAssertEqual(PTPIPCodec.u16(packet, at: 12), 0x1009)
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 14), 7)
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 18), 0xFFFF_C002)
    }

    func testCommandRequestWithDataMarksDataOutPhase() {
        let packet = [UInt8](PTPIPCodec.commandRequest(code: 0x9207, transactionID: 1,
                                                       parameters: [0xD2C2], hasDataOut: true))
        XCTAssertEqual(PTPIPCodec.u32(packet, at: 8), 2)
    }

    func testDataOutIsStartThenEnd() {
        let bytes = [UInt8](PTPIPCodec.dataOut(transactionID: 9, data: [2, 0]))
        // Start Data: 8 header + 4 transaction + 8 length = 20 bytes.
        XCTAssertEqual(PTPIPCodec.u32(bytes, at: 0), 20)
        XCTAssertEqual(PTPIPCodec.u32(bytes, at: 4), 9)
        XCTAssertEqual(PTPIPCodec.u32(bytes, at: 8), 9)
        XCTAssertEqual(PTPIPCodec.u64(bytes, at: 12), 2)
        // End Data: 8 header + 4 transaction + 2 payload = 14 bytes.
        XCTAssertEqual(PTPIPCodec.u32(bytes, at: 20), 14)
        XCTAssertEqual(PTPIPCodec.u32(bytes, at: 24), 12)
        XCTAssertEqual(PTPIPCodec.u32(bytes, at: 28), 9)
        XCTAssertEqual(Array(bytes[32...]), [2, 0])
    }

    func testReadsOutOfRangeReturnNil() {
        XCTAssertNil(PTPIPCodec.u32([1, 2, 3], at: 0))
        XCTAssertNil(PTPIPCodec.u16([1, 2], at: 1))
        XCTAssertNil(PTPIPCodec.u64([UInt8](repeating: 0, count: 8), at: 1))
    }
}

final class SonyRemoteTests: XCTestCase {

    private func liveViewObject(offset: UInt32, jpeg: [UInt8], declaredSize: UInt32? = nil) -> Data {
        var bytes = PTPIPCodec.bytes(offset) + PTPIPCodec.bytes(declaredSize ?? UInt32(jpeg.count))
        bytes += [UInt8](repeating: 0, count: Int(offset) - 8)
        bytes += jpeg
        return Data(bytes)
    }

    func testLiveViewJPEGIsCutOutOfTheObject() {
        let jpeg: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]
        let object = liveViewObject(offset: 136, jpeg: jpeg)
        XCTAssertEqual(SonyPTP.liveViewJPEG(from: object).map { [UInt8]($0) }, jpeg)
    }

    func testLiveViewJPEGWorksOnADataSlice() {
        let jpeg: [UInt8] = [0xFF, 0xD8, 9, 0xFF, 0xD9]
        let padded = Data([0, 0, 0]) + liveViewObject(offset: 16, jpeg: jpeg)
        let slice = padded.dropFirst(3)
        XCTAssertEqual(SonyPTP.liveViewJPEG(from: slice).map { [UInt8]($0) }, jpeg)
    }

    func testLiveViewRejectsWrongSizeOrNonJPEG() {
        XCTAssertNil(SonyPTP.liveViewJPEG(from: Data([1, 2, 3])))
        XCTAssertNil(SonyPTP.liveViewJPEG(from: liveViewObject(offset: 16, jpeg: [0xFF, 0xD8, 0, 0], declaredSize: 400)))
        XCTAssertNil(SonyPTP.liveViewJPEG(from: liveViewObject(offset: 16, jpeg: [0, 1, 2, 3, 4])))
    }

    func testHotspotCandidatesAreTheHotspotRange() {
        let hosts = SonyDiscovery.candidates(onNetworkOf: "172.20.10.1")
        XCTAssertEqual(hosts.first, "172.20.10.2")
        XCTAssertEqual(hosts.last, "172.20.10.14")
        XCTAssertEqual(hosts.count, 13)
    }

    func testHomeNetworkCandidatesSkipThePhoneItself() {
        let hosts = SonyDiscovery.candidates(onNetworkOf: "192.168.1.23")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains("192.168.1.23"))
        XCTAssertTrue(hosts.contains("192.168.1.1"))
        XCTAssertTrue(hosts.contains("192.168.1.254"))
    }

    func testCandidatesForNonsenseAddressAreEmpty() {
        XCTAssertTrue(SonyDiscovery.candidates(onNetworkOf: "not an address").isEmpty)
    }

    func testRemoteIdentityIsStable() {
        let name = "SonyRemoteTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            return XCTFail("no defaults")
        }
        defer { defaults.removePersistentDomain(forName: name) }
        let first = SonyRemoteSettings.guid(defaults)
        XCTAssertEqual(first.count, 16)
        XCTAssertEqual(SonyRemoteSettings.guid(defaults), first)
    }
}

final class MJPEGSplitterTests: XCTestCase {
    private let frameA: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]
    private let frameB: [UInt8] = [0xFF, 0xD8, 7, 0xFF, 0x00, 8, 0xFF, 0xD9]

    func testTwoFramesInOneChunkWithHeadersBetween() {
        var splitter = MJPEGSplitter()
        let stream = Array("--b\r\nContent-Type: image/jpeg\r\n\r\n".utf8) + frameA
            + Array("\r\n--b\r\n\r\n".utf8) + frameB
        let frames = splitter.append(Data(stream)).map { [UInt8]($0) }
        XCTAssertEqual(frames, [frameA, frameB])
    }

    func testFrameSplitAcrossChunksIncludingInsideAMarker() {
        var splitter = MJPEGSplitter()
        var frames: [[UInt8]] = []
        // Cut right between FF and D9.
        frames += splitter.append(Data(frameA.prefix(6))).map { [UInt8]($0) }
        XCTAssertTrue(frames.isEmpty)
        frames += splitter.append(Data(frameA.suffix(1) + frameB.prefix(1))).map { [UInt8]($0) }
        XCTAssertEqual(frames, [frameA])
        frames += splitter.append(Data(frameB.dropFirst(1))).map { [UInt8]($0) }
        XCTAssertEqual(frames, [frameA, frameB])
    }

    func testByteAtATime() {
        var splitter = MJPEGSplitter()
        var frames: [[UInt8]] = []
        let leading: [UInt8] = [0x00, 0x11]
        let between: [UInt8] = [0x22]
        let stream: [UInt8] = leading + frameA + between + frameB
        for byte in stream {
            frames += splitter.append(Data([byte])).map { [UInt8]($0) }
        }
        XCTAssertEqual(frames, [frameA, frameB])
    }

    func testGarbageWithoutAStartMarkerProducesNothing() {
        var splitter = MJPEGSplitter()
        XCTAssertTrue(splitter.append(Data([1, 2, 0xFF, 0xD9, 3, 4])).isEmpty)
        XCTAssertEqual(splitter.append(Data(frameA)).map { [UInt8]($0) }, [frameA])
    }
}
