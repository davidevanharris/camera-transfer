import XCTest
@testable import CameraTransfer

final class RicohParserTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testParsesModelFromProps() {
        let json = #"{"errCode":200,"errMsg":"OK","model":"RICOH GR IV","firmwareVersion":"1.00"}"#
        XCTAssertEqual(RicohParser.parseModel(fromProps: data(json)), "RICOH GR IV")
        XCTAssertNil(RicohParser.parseModel(fromProps: data("not json")))
        XCTAssertNil(RicohParser.parseModel(fromProps: data(#"{"errCode":200}"#)))
    }

    func testParsesStringFileList() throws {
        let json = #"{"errCode":200,"errMsg":"OK","dirs":[{"name":"100RICOH","files":["R0000001.JPG","R0000001.DNG","R0000002.MOV"]},{"name":"101RICOH","files":["R0000003.JPG"]}]}"#
        let photos = try RicohParser.parsePhotoList(data(json))
        XCTAssertEqual(photos.map(\.id), ["100RICOH/R0000001.JPG", "100RICOH/R0000001.DNG", "100RICOH/R0000002.MOV", "101RICOH/R0000003.JPG"])
        XCTAssertEqual(photos.map(\.kind), [.jpeg, .raw, .video, .jpeg])
        XCTAssertNil(photos[0].size)
    }

    func testParsesObjectFileEntries() throws {
        let json = #"{"errCode":200,"dirs":[{"name":"100RICOH","files":[{"n":"R0000010.JPG","s":123456,"d":"2025-06-01T10:20:30"},{"name":"R0000011.DNG","size":"999"},{"x":"ignored"},"R0000012.JPG"]}]}"#
        let photos = try RicohParser.parsePhotoList(data(json))
        XCTAssertEqual(photos.map(\.filename), ["R0000010.JPG", "R0000011.DNG", "R0000012.JPG"])
        XCTAssertEqual(photos[0].size, 123456)
        XCTAssertNotNil(photos[0].date)
        XCTAssertEqual(photos[1].size, 999)
    }

    func testMissingErrCodeAndDirsIsEmpty() throws {
        XCTAssertEqual(try RicohParser.parsePhotoList(data("{}")).count, 0)
        XCTAssertEqual(try RicohParser.parsePhotoList(data(#"{"errCode":200,"dirs":[]}"#)).count, 0)
    }

    func testErrorCodeThrows() {
        XCTAssertThrowsError(try RicohParser.parsePhotoList(data(#"{"errCode":503,"errMsg":"busy"}"#)))
        XCTAssertThrowsError(try RicohParser.parsePhotoList(data("<html>")))
        XCTAssertThrowsError(try RicohParser.parsePhotoList(data("[1,2]")))
    }

    func testRejectsUnsafeNames() throws {
        let json = #"{"dirs":[{"name":"100RICOH","files":["..","a/b.JPG","","R1.JPG"]}]}"#
        XCTAssertEqual(try RicohParser.parsePhotoList(data(json)).map(\.filename), ["R1.JPG"])
    }

    // MARK: GR IV /v1/props and storages

    func testParsesDeviceInfoWithStorages() throws {
        let json = #"{"errCode":200,"model":"RICOH GR IV","firmwareVersion":"1.11","battery":80,"storages":[{"name":"in","equipped":true,"numOfPhotos":3,"numOfMovies":0},{"name":"sd1","equipped":false}]}"#
        let info = try XCTUnwrap(RicohParser.parseDeviceInfo(fromProps: data(json)))
        XCTAssertEqual(info.model, "RICOH GR IV")
        XCTAssertEqual(info.firmware, "1.11")
        XCTAssertEqual(info.batteryPercent, 80)
        XCTAssertEqual(info.storages.map(\.name), ["in", "sd1"])
        XCTAssertEqual(info.storages[0].equipped, true)
        XCTAssertEqual(info.storages[0].numberOfPhotos, 3)
        XCTAssertEqual(info.storages[1].equipped, false)
        XCTAssertEqual(info.storages[0].displayName, "Internal memory")
        XCTAssertEqual(info.summary, "RICOH GR IV - firmware 1.11 - battery 80%")
    }

    func testDeviceInfoIsDefensive() throws {
        let info = try XCTUnwrap(RicohParser.parseDeviceInfo(fromProps: data(#"{"model":"GR","batteryLevel":"55%","battery":true}"#)))
        XCTAssertEqual(info.batteryPercent, 55, "boolean 'battery' is ignored, string percentage is read")
        XCTAssertNil(info.firmware)
        XCTAssertTrue(info.storages.isEmpty)

        let odd = try XCTUnwrap(RicohParser.parseDeviceInfo(fromProps: data(#"{"battery":250,"storages":"nope"}"#)))
        XCTAssertNil(odd.batteryPercent, "out-of-range battery is unknown")
        XCTAssertEqual(odd.model, "Ricoh camera")
        XCTAssertTrue(odd.storages.isEmpty)

        let noEquippedKey = try XCTUnwrap(RicohParser.parseDeviceInfo(fromProps: data(#"{"storages":[{"name":"sd1"}]}"#)))
        XCTAssertEqual(noEquippedKey.storages.first?.equipped, true, "missing 'equipped' means usable")

        XCTAssertNil(RicohParser.parseDeviceInfo(fromProps: data("garbage")))
    }

    func testPhotoListWithStorageMakesDistinctIDs() throws {
        let json = #"{"errCode":200,"dirs":[{"name":"100RICOH","files":["R0000001.JPG"]}]}"#
        let internal = try RicohParser.parsePhotoList(data(json), storage: "in")
        let card = try RicohParser.parsePhotoList(data(json), storage: "sd1")
        XCTAssertEqual(internal.first?.id, "in/100RICOH/R0000001.JPG")
        XCTAssertEqual(card.first?.id, "sd1/100RICOH/R0000001.JPG")
        XCTAssertEqual(card.first?.storage, "sd1")
        XCTAssertEqual(card.first?.folder, "100RICOH")
        XCTAssertEqual(card.first?.cameraPath, "100RICOH/R0000001.JPG")
        XCTAssertNotEqual(internal.first?.id, card.first?.id)
    }
}
