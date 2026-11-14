import XCTest
@testable import CameraTransfer

final class RemotePhotoTests: XCTestCase {

    func testFileKindClassification() {
        XCTAssertEqual(FileKind.classify(filename: "R0000001.JPG"), .jpeg)
        XCTAssertEqual(FileKind.classify(filename: "photo.jpeg"), .jpeg)
        XCTAssertEqual(FileKind.classify(filename: "R0000001.DNG"), .raw)
        XCTAssertEqual(FileKind.classify(filename: "DSC00001.ARW"), .raw)
        XCTAssertEqual(FileKind.classify(filename: "P1010001.ORF"), .raw)
        XCTAssertEqual(FileKind.classify(filename: "P1010001.ori"), .raw)
        XCTAssertEqual(FileKind.classify(filename: "C0001.MP4"), .video)
        XCTAssertEqual(FileKind.classify(filename: "R0000002.MOV"), .video)
        XCTAssertEqual(FileKind.classify(filename: "DSC00001.HIF"), .other)
        XCTAssertEqual(FileKind.classify(filename: "README"), .other)
    }

    func testRemotePhotoIdentifier() {
        XCTAssertEqual(RemotePhoto(folder: "100RICOH", filename: "R0000001.JPG").id, "100RICOH/R0000001.JPG")
        XCTAssertEqual(RemotePhoto(folder: "/DCIM/100OMSYS", filename: "P1.ORF").id, "/DCIM/100OMSYS/P1.ORF")
        XCTAssertEqual(RemotePhoto(folder: "/DCIM/", filename: "P1.ORF").id, "/DCIM/P1.ORF")
        XCTAssertEqual(RemotePhoto(folder: "100RICOH", filename: "R0000001.DNG").kind, .raw)
    }

    func testBaseURLParsing() {
        XCTAssertEqual(CameraHTTP.parseBaseURL("192.168.0.1")?.absoluteString, "http://192.168.0.1")
        XCTAssertEqual(CameraHTTP.parseBaseURL(" http://192.168.0.10/ ")?.absoluteString, "http://192.168.0.10")
        XCTAssertEqual(CameraHTTP.parseBaseURL("localhost:8001")?.absoluteString, "http://localhost:8001")
        XCTAssertNil(CameraHTTP.parseBaseURL(""))
    }

    func testURLBuildingKeepsSlashesInQuery() throws {
        let http = CameraHTTP(baseURL: URL(string: "http://192.168.0.10")!)
        let url = try http.url(path: "/get_thumbnail.cgi",
                               query: [URLQueryItem(name: "DIR", value: "/DCIM/100OMSYS/P1010001.JPG")])
        XCTAssertEqual(url.absoluteString, "http://192.168.0.10/get_thumbnail.cgi?DIR=/DCIM/100OMSYS/P1010001.JPG")
        let ricoh = try http.url(path: "/v1/photos/100RICOH/R0000001.JPG", query: [URLQueryItem(name: "size", value: "thumb")])
        XCTAssertEqual(ricoh.absoluteString, "http://192.168.0.10/v1/photos/100RICOH/R0000001.JPG?size=thumb")
    }

    func testLibraryDestinationIsConfined() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(documentsURL: temp, indexDirectory: temp.appendingPathComponent("idx"))
        let photo = RemotePhoto(folder: "/DCIM/100OMSYS", filename: "../../evil.JPG")
        let destination = store.destination(for: photo, camera: .olympus)
        XCTAssertTrue(destination.path.hasPrefix(temp.appendingPathComponent("OM System OM-3").path))
        XCTAssertEqual(destination.lastPathComponent, "evil.JPG")
        XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "100OMSYS")
        try? FileManager.default.removeItem(at: temp)
    }

    func testDownloadIndexRoundTrip() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(documentsURL: temp, indexDirectory: temp.appendingPathComponent("idx"))
        XCTAssertTrue(store.downloadedIDs(for: .ricoh).isEmpty)
        store.markDownloaded("100RICOH/R0000001.JPG", camera: .ricoh)
        let reloaded = LibraryStore(documentsURL: temp, indexDirectory: temp.appendingPathComponent("idx"))
        XCTAssertEqual(reloaded.downloadedIDs(for: .ricoh), ["100RICOH/R0000001.JPG"])
        XCTAssertTrue(reloaded.downloadedIDs(for: .olympus).isEmpty)
        try? FileManager.default.removeItem(at: temp)
    }

    func testExportGroupsJPEGWithRAW() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let items = PhotoExporter.makeItems(from: [
            dir.appendingPathComponent("R1.DNG"),
            dir.appendingPathComponent("R1.JPG"),
            dir.appendingPathComponent("R2.DNG"),
            dir.appendingPathComponent("V1.MOV"),
            dir.appendingPathComponent("notes.txt")
        ])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].primary.lastPathComponent, "R1.JPG")
        XCTAssertEqual(items[0].alternateRAW?.lastPathComponent, "R1.DNG")
        XCTAssertEqual(items[1].primary.lastPathComponent, "R2.DNG")
        XCTAssertNil(items[1].alternateRAW)
        XCTAssertEqual(items[2].kind, .video)
    }

    func testStorageIsPartOfIdentifierAndDestination() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(documentsURL: temp, indexDirectory: temp.appendingPathComponent("idx"))
        let photo = RemotePhoto(folder: "100RICOH", filename: "R0000001.JPG", storage: "sd1")
        XCTAssertEqual(photo.id, "sd1/100RICOH/R0000001.JPG")
        let destination = store.destination(for: photo, camera: .ricoh)
        XCTAssertEqual(destination.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "sd1")
        XCTAssertEqual(RemotePhoto(folder: "/DCIM/100OMSYS", filename: "P1.JPG", storage: "x").id, "x/DCIM/100OMSYS/P1.JPG")
        try? FileManager.default.removeItem(at: temp)
    }

    func testBaselineRoundTrip() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(documentsURL: temp, indexDirectory: temp.appendingPathComponent("idx"))
        XCTAssertNil(store.baselineIDs(for: .ricoh))
        store.setBaseline(["a", "b"], for: .ricoh)
        XCTAssertEqual(store.baselineIDs(for: .ricoh), ["a", "b"])
        XCTAssertNil(store.baselineIDs(for: .olympus))
        store.clearBaselines()
        XCTAssertNil(store.baselineIDs(for: .ricoh))
        try? FileManager.default.removeItem(at: temp)
    }
}
