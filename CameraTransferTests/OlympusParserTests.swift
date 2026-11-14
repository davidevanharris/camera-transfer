import XCTest
@testable import CameraTransfer

final class OlympusParserTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    func testParsesModel() {
        let xml = "<?xml version=\"1.0\"?><caminfo><model>OM-3</model><version>1.0</version></caminfo>"
        XCTAssertEqual(OlympusParser.parseModel(fromCamInfo: Data(xml.utf8)), "OM-3")
        XCTAssertNil(OlympusParser.parseModel(fromCamInfo: Data("<caminfo/>".utf8)))
    }

    func testFATDateDecoding() throws {
        // 2024-03-15 10:30:44
        let date = ((2024 - 1980) << 9) | (3 << 5) | 15
        let time = (10 << 11) | (30 << 5) | (44 / 2)
        XCTAssertEqual(date, 22639)
        XCTAssertEqual(time, 21462)
        let decoded = try XCTUnwrap(OlympusParser.decodeFATDateTime(date: date, time: time, timeZone: utc))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: decoded)
        XCTAssertEqual(c.year, 2024)
        XCTAssertEqual(c.month, 3)
        XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.hour, 10)
        XCTAssertEqual(c.minute, 30)
        XCTAssertEqual(c.second, 44)
    }

    func testInvalidFATDateIsNil() {
        XCTAssertNil(OlympusParser.decodeFATDateTime(date: 0, time: 0, timeZone: utc))
        XCTAssertNil(OlympusParser.decodeFATDateTime(date: (44 << 9) | (13 << 5) | 1, time: 0, timeZone: utc))
    }

    func testParsesRootListingWithDirectories() {
        let text = "VER_100\r\n/DCIM,100OMSYS,0,16,22639,21462\r\n/DCIM,101OMSYS,0,16,22639,21462\r\n"
        let entries = OlympusParser.parseImageList(text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy(\.isDirectory))
        XCTAssertEqual(entries.map(\.path), ["/DCIM/100OMSYS", "/DCIM/101OMSYS"])
    }

    func testParsesFileListing() {
        let text = """
        VER_100
        /DCIM/100OMSYS,P1010001.JPG,4123456,0,22639,21462
        /DCIM/100OMSYS,P1010001.ORF,20123456,32,22639,21462

        /DCIM/100OMSYS,P1010002.MOV,99999999,0,22639,21463
        garbage line
        /DCIM/100OMSYS,BAD.JPG,notanumber,0,1,1
        """
        let entries = OlympusParser.parseImageList(text)
        XCTAssertEqual(entries.map(\.name), ["P1010001.JPG", "P1010001.ORF", "P1010002.MOV"])
        XCTAssertFalse(entries[1].isDirectory, "attribute 32 (archive) is not a directory")
        let photos = entries.map { OlympusParser.photo(from: $0, timeZone: utc) }
        XCTAssertEqual(photos[0].id, "/DCIM/100OMSYS/P1010001.JPG")
        XCTAssertEqual(photos[0].folder, "/DCIM/100OMSYS")
        XCTAssertEqual(photos[1].kind, .raw)
        XCTAssertEqual(photos[2].kind, .video)
        XCTAssertEqual(photos[1].size, 20123456)
        XCTAssertNotNil(photos[0].date)
    }

    func testEmptyListing() {
        XCTAssertTrue(OlympusParser.parseImageList("VER_100\r\n").isEmpty)
        XCTAssertTrue(OlympusParser.parseImageList("").isEmpty)
    }
}
