import XCTest
@testable import CameraTransfer

final class FTPSessionTests: XCTestCase {
    private var root: URL!
    private var session: FTPSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FTPSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        session = FTPSession(root: root, username: "camera", password: "secret")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func replies(_ actions: [FTPAction]) -> [String] {
        actions.compactMap { action in
            if case .reply(let text) = action { return text }
            return nil
        }
    }

    private func code(_ line: String) -> String {
        let text = replies(session.handle(line: line)).last ?? ""
        return String(text.prefix(3))
    }

    private func login() {
        XCTAssertEqual(code("USER camera"), "331")
        XCTAssertEqual(code("PASS secret"), "230")
    }

    private func openPassive() {
        let actions = session.handle(line: "PASV")
        XCTAssertEqual(actions, [.openPassiveListener(extended: false)])
        _ = session.passiveListenerReady(ipv4: "172.20.10.1", port: 50001, extended: false)
    }

    // MARK: Login

    func testCommandsRequireLogin() {
        XCTAssertEqual(code("PWD"), "530")
        XCTAssertEqual(code("LIST"), "530")
        XCTAssertEqual(code("STOR x.jpg"), "530")
        XCTAssertEqual(code("SYST"), "215")
        XCTAssertEqual(code("NOOP"), "200")
    }

    func testLoginSuccessAndFailure() {
        XCTAssertEqual(code("PASS secret"), "503", "PASS before USER")
        XCTAssertEqual(code("USER camera"), "331")
        XCTAssertEqual(code("PASS wrong"), "530")
        XCTAssertFalse(session.isLoggedIn)
        XCTAssertEqual(code("USER someone"), "331")
        XCTAssertEqual(code("PASS secret"), "530", "wrong user name")
        login()
        XCTAssertTrue(session.isLoggedIn)
        XCTAssertEqual(code("PWD"), "257")
    }

    func testCommandParsingIsCaseInsensitiveAndStripsCRLF() {
        XCTAssertEqual(code("user camera\r\n"), "331")
        XCTAssertEqual(code("pass secret\r\n"), "230")
    }

    func testTLSIsRefused() {
        XCTAssertEqual(code("AUTH TLS"), "502")
    }

    func testQuitClosesConnection() {
        let actions = session.handle(line: "QUIT")
        XCTAssertEqual(actions.last, .close)
        XCTAssertEqual(replies(actions).first?.prefix(3), "221")
    }

    func testFeatIsMultiline() {
        let reply = replies(session.handle(line: "FEAT")).first ?? ""
        XCTAssertTrue(reply.hasPrefix("211-"))
        XCTAssertTrue(reply.hasSuffix("211 End"))
        XCTAssertTrue(reply.contains(" EPSV"))
    }

    // MARK: Passive / active

    func testPasvReplyFormat() {
        XCTAssertEqual(FTPSession.pasvReply(ipv4: "192.168.0.5", port: 50001),
                       "227 Entering Passive Mode (192,168,0,5,195,81).")
        XCTAssertEqual(FTPSession.pasvReply(ipv4: "172.20.10.1", port: 2122),
                       "227 Entering Passive Mode (172,20,10,1,8,74).")
        XCTAssertEqual(FTPSession.pasvReply(ipv4: "garbage", port: 256),
                       "227 Entering Passive Mode (0,0,0,0,1,0).")
        login()
        XCTAssertEqual(session.handle(line: "PASV"), [.openPassiveListener(extended: false)])
        let reply = session.passiveListenerReady(ipv4: "10.0.0.2", port: 60000, extended: false)
        XCTAssertEqual(reply, "227 Entering Passive Mode (10,0,0,2,234,96).")
        XCTAssertEqual(session.dataMode, .passive)
    }

    func testEpsvReply() {
        login()
        XCTAssertEqual(session.handle(line: "EPSV"), [.openPassiveListener(extended: true)])
        XCTAssertEqual(session.passiveListenerReady(ipv4: "10.0.0.2", port: 60000, extended: true),
                       "229 Entering Extended Passive Mode (|||60000|)")
        XCTAssertEqual(code("EPSV 2"), "522")
    }

    func testPortAndEprtParsing() {
        login()
        let actions = session.handle(line: "PORT 192,168,0,9,4,1")
        XCTAssertEqual(actions.first, .connectActive(host: "192.168.0.9", port: 1025))
        XCTAssertEqual(replies(actions).first?.prefix(3), "200")
        let eprt = session.handle(line: "EPRT |1|172.20.10.2|6275|")
        XCTAssertEqual(eprt.first, .connectActive(host: "172.20.10.2", port: 6275))
        XCTAssertEqual(code("PORT 1,2,3"), "501")
        XCTAssertEqual(code("PORT 300,1,1,1,1,1"), "501")
        XCTAssertEqual(code("EPRT |2|::1|6275|"), "522")
    }

    // MARK: Paths

    func testPathTraversalIsRejected() {
        login()
        XCTAssertNil(session.resolve(".."))
        XCTAssertNil(session.resolve("../etc/passwd"))
        XCTAssertNil(session.resolve("/a/../../b"))
        XCTAssertNil(session.resolve("a\\..\\b"))
        XCTAssertEqual(code("CWD .."), "550")
        XCTAssertEqual(code("CWD /../.."), "550")
        XCTAssertEqual(code("MKD ../outside"), "550")
        openPassive()
        let actions = session.handle(line: "STOR ../evil.jpg")
        XCTAssertEqual(replies(actions).first?.prefix(3), "553")
        XCTAssertFalse(actions.contains { if case .receiveFile = $0 { return true } else { return false } })
        XCTAssertEqual(code("RNFR ../x"), "550")
        XCTAssertEqual(code("DELE ../x"), "550")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside").path))
    }

    func testDirectoryNavigation() {
        login()
        XCTAssertEqual(code("MKD DCIM"), "257")
        XCTAssertEqual(code("MKD DCIM"), "257", "existing directory is fine")
        XCTAssertEqual(code("CWD DCIM"), "250")
        XCTAssertEqual(session.currentDirectory, "/DCIM")
        XCTAssertEqual(replies(session.handle(line: "PWD")).first, "257 \"/DCIM\" is the current directory.")
        XCTAssertEqual(code("CWD missing"), "550")
        XCTAssertEqual(code("CDUP"), "250")
        XCTAssertEqual(session.currentDirectory, "/")
        XCTAssertEqual(code("CDUP"), "250")
        XCTAssertEqual(session.currentDirectory, "/", "cannot go above root")
        XCTAssertEqual(code("XMKD /A/B"), "257")
        XCTAssertEqual(code("XCWD /A/B"), "250")
        XCTAssertEqual(session.currentDirectory, "/A/B")
    }

    func testStoreRequiresDataConnection() {
        login()
        XCTAssertEqual(code("STOR DSC00001.JPG"), "425")
        XCTAssertEqual(code("LIST"), "425")
    }

    func testStorPathResolutionAndCompletion() throws {
        login()
        XCTAssertEqual(code("MKD 100MSDCF"), "257")
        XCTAssertEqual(code("CWD 100MSDCF"), "250")
        XCTAssertEqual(code("TYPE I"), "200")
        openPassive()

        let actions = session.handle(line: "STOR DSC00001.ARW")
        XCTAssertEqual(replies(actions).first?.prefix(3), "150")
        guard case .receiveFile(let partURL, let finalURL, let append)? = actions.last else {
            return XCTFail("expected receiveFile, got \(actions)")
        }
        let expectedFinal = root.appendingPathComponent("100MSDCF").appendingPathComponent("DSC00001.ARW")
        XCTAssertEqual(finalURL.standardizedFileURL.path, expectedFinal.standardizedFileURL.path)
        XCTAssertEqual(partURL.deletingLastPathComponent().standardizedFileURL.path,
                       expectedFinal.deletingLastPathComponent().standardizedFileURL.path)
        XCTAssertTrue(partURL.lastPathComponent.hasPrefix("."))
        XCTAssertTrue(partURL.lastPathComponent.hasSuffix(".part"))
        XCTAssertFalse(append)

        // Simulate the transport writing the data.
        try Data("hello".utf8).write(to: partURL)
        let result = session.storeFinished(success: true)
        XCTAssertEqual(result.reply.prefix(3), "226")
        XCTAssertEqual(result.savedFile?.lastPathComponent, "DSC00001.ARW")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFinal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertEqual(session.dataMode, .inactive, "data connection is single use")

        XCTAssertEqual(replies(session.handle(line: "SIZE DSC00001.ARW")).first, "213 5")
        XCTAssertEqual(replies(session.handle(line: "SIZE /100MSDCF/DSC00001.ARW")).first, "213 5")
        XCTAssertEqual(code("MDTM DSC00001.ARW"), "213")
        XCTAssertEqual(code("SIZE nothing.jpg"), "550")
    }

    func testAbsoluteStorPathCreatesFolders() {
        login()
        openPassive()
        let actions = session.handle(line: "STOR /DCIM/100MSDCF/DSC00002.JPG")
        guard case .receiveFile(_, let finalURL, _)? = actions.last else {
            return XCTFail("expected receiveFile")
        }
        XCTAssertEqual(finalURL.lastPathComponent, "DSC00002.JPG")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.deletingLastPathComponent().path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testFailedStoreRemovesPartFile() throws {
        login()
        openPassive()
        let actions = session.handle(line: "STOR broken.jpg")
        guard case .receiveFile(let partURL, let finalURL, _)? = actions.last else {
            return XCTFail("expected receiveFile")
        }
        try Data("partial".utf8).write(to: partURL)
        let result = session.storeFinished(success: false)
        XCTAssertEqual(result.reply.prefix(3), "426")
        XCTAssertNil(result.savedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testListing() throws {
        login()
        try Data("abc".utf8).write(to: root.appendingPathComponent("A.JPG"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("SUB"), withIntermediateDirectories: true)
        openPassive()
        let actions = session.handle(line: "LIST -la")
        guard case .sendData(let data)? = actions.last else {
            return XCTFail("expected sendData")
        }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("-rw-r--r-- 1 camera camera 3 "))
        XCTAssertTrue(text.contains(" A.JPG\r\n"))
        XCTAssertTrue(text.contains("drwxr-xr-x"))
        XCTAssertEqual(session.sendFinished(success: true).prefix(3), "226")

        openPassive()
        guard case .sendData(let names)? = session.handle(line: "NLST").last else {
            return XCTFail("expected sendData")
        }
        XCTAssertEqual(String(decoding: names, as: UTF8.self), "A.JPG\r\nSUB\r\n")
    }

    // MARK: Rename and delete

    func testRenameFromTo() throws {
        login()
        try Data("x".utf8).write(to: root.appendingPathComponent("tmp.jpg"))
        XCTAssertEqual(code("RNTO new.jpg"), "503", "RNTO without RNFR")
        XCTAssertEqual(code("RNFR missing.jpg"), "550")
        XCTAssertEqual(code("RNFR tmp.jpg"), "350")
        XCTAssertEqual(code("RNTO final.jpg"), "250")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("final.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tmp.jpg").path))
        XCTAssertEqual(code("RNTO again.jpg"), "503", "RNFR is consumed")
        XCTAssertEqual(code("RNFR final.jpg"), "350")
        XCTAssertEqual(code("RNTO ../escape.jpg"), "553")
    }

    func testDeleteOnlyOwnUploads() throws {
        login()
        try Data("old".utf8).write(to: root.appendingPathComponent("existing.jpg"))
        XCTAssertEqual(code("DELE existing.jpg"), "550")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("existing.jpg").path))

        openPassive()
        guard case .receiveFile(let partURL, _, _)? = session.handle(line: "STOR mine.jpg").last else {
            return XCTFail("expected receiveFile")
        }
        try Data("new".utf8).write(to: partURL)
        _ = session.storeFinished(success: true)
        XCTAssertEqual(code("RNFR mine.jpg"), "350")
        XCTAssertEqual(code("RNTO renamed.jpg"), "250")
        XCTAssertEqual(code("DELE renamed.jpg"), "250", "renamed own upload can still be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.jpg").path))
    }

    func testMiscCommands() {
        login()
        XCTAssertEqual(code("TYPE A"), "200")
        XCTAssertEqual(code("TYPE X"), "504")
        XCTAssertEqual(code("MODE S"), "200")
        XCTAssertEqual(code("MODE B"), "504")
        XCTAssertEqual(code("STRU F"), "200")
        XCTAssertEqual(code("OPTS UTF8 ON"), "200")
        XCTAssertEqual(code("ALLO 1000"), "202")
        XCTAssertEqual(code("REST 0"), "350")
        XCTAssertEqual(code("REST 100"), "502")
        XCTAssertEqual(code("RETR anything"), "550")
        XCTAssertEqual(code("FOO"), "502")
        let abort = session.handle(line: "ABOR")
        XCTAssertEqual(abort.first, .abortTransfer)
        XCTAssertEqual(replies(abort).first?.prefix(3), "226")
    }
}
