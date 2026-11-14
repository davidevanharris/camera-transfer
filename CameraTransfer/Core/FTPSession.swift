import Foundation

/// Something the network transport must do in response to a command.
enum FTPAction: Equatable {
    /// Send a reply line (CRLF is appended by the transport). Multi-line replies contain embedded "\r\n".
    case reply(String)
    /// Open a passive-mode data listener, then call `passiveListenerReady` (or `passiveListenerFailed`).
    case openPassiveListener(extended: Bool)
    /// Active mode: connect out to the client's data port.
    case connectActive(host: String, port: UInt16)
    /// Receive the data connection's bytes into `partURL`; then call `storeFinished`.
    case receiveFile(partURL: URL, finalURL: URL, append: Bool)
    /// Send these bytes over the data connection and close it; then call `sendFinished`.
    case sendData(Data)
    /// Abort any data transfer in progress (no reply needed from the transport); then call `transferAborted`.
    case abortTransfer
    /// Close the control connection after the preceding replies have been sent.
    case close
}

enum FTPDataMode: Equatable {
    case inactive
    case passive
    case active(host: String, port: UInt16)
}

/// Pure FTP command state machine. It touches the file system only inside `root`,
/// and never does any networking: the transport executes the returned actions.
final class FTPSession {
    let root: URL
    let username: String
    let password: String

    private(set) var isLoggedIn = false
    private(set) var currentDirectory = "/"
    private(set) var dataMode: FTPDataMode = .inactive
    /// Standardized paths of files uploaded on this control connection. Only these may be deleted.
    private(set) var ownUploads: Set<String> = []

    private var pendingUser: String?
    private var renameSource: URL?
    private var pendingStore: (part: URL, destination: URL, append: Bool)?
    private let fileManager = FileManager.default

    static let greeting = "220 CameraTransfer FTP server ready."

    init(root: URL, username: String, password: String) {
        self.root = root.standardizedFileURL
        self.username = username
        self.password = password
    }

    // MARK: Command handling

    func handle(line rawLine: String) -> [FTPAction] {
        var line = rawLine
        while line.hasSuffix("\r") || line.hasSuffix("\n") {
            line.removeLast()
        }
        let command: String
        let argument: String
        if let space = line.firstIndex(of: " ") {
            command = String(line[line.startIndex..<space]).uppercased()
            argument = String(line[line.index(after: space)...])
        } else {
            command = line.uppercased()
            argument = ""
        }

        switch command {
        case "":
            return [.reply("500 Empty command.")]
        case "USER":
            pendingUser = argument
            isLoggedIn = false
            return [.reply("331 Password required for \(argument).")]
        case "PASS":
            guard let user = pendingUser else {
                return [.reply("503 Login with USER first.")]
            }
            if user == username && argument == password {
                isLoggedIn = true
                return [.reply("230 User logged in.")]
            }
            pendingUser = nil
            isLoggedIn = false
            return [.reply("530 Login incorrect.")]
        case "QUIT":
            return [.reply("221 Goodbye."), .close]
        case "SYST":
            return [.reply("215 UNIX Type: L8")]
        case "FEAT":
            return [.reply("211-Features:\r\n EPSV\r\n PASV\r\n SIZE\r\n MDTM\r\n MLSD\r\n UTF8\r\n211 End")]
        case "OPTS":
            if argument.uppercased().hasPrefix("UTF8") {
                return [.reply("200 UTF8 mode enabled.")]
            }
            return [.reply("501 Option not supported.")]
        case "NOOP":
            return [.reply("200 OK.")]
        case "AUTH", "PBSZ", "PROT":
            return [.reply("502 TLS is not supported. Turn off the secure protocol setting on the camera.")]
        default:
            break
        }

        guard isLoggedIn else {
            return [.reply("530 Please log in with USER and PASS.")]
        }

        switch command {
        case "PWD", "XPWD":
            return [.reply("257 \"\(quoted(currentDirectory))\" is the current directory.")]
        case "CWD", "XCWD":
            return changeDirectory(argument)
        case "CDUP", "XCUP":
            return changeDirectory("..", allowParent: true)
        case "MKD", "XMKD":
            return makeDirectory(argument)
        case "TYPE":
            let type = argument.uppercased()
            if type.hasPrefix("I") || type.hasPrefix("A") || type.hasPrefix("L") {
                return [.reply("200 Type set to \(type.hasPrefix("A") ? "A" : "I").")]
            }
            return [.reply("504 Type not supported.")]
        case "MODE":
            return [.reply(argument.uppercased() == "S" ? "200 Mode set to S." : "504 Only stream mode is supported.")]
        case "STRU":
            return [.reply(argument.uppercased() == "F" ? "200 Structure set to F." : "504 Only file structure is supported.")]
        case "PASV":
            return [.openPassiveListener(extended: false)]
        case "EPSV":
            let arg = argument.trimmingCharacters(in: .whitespaces).uppercased()
            if arg == "ALL" {
                return [.reply("200 EPSV ALL ok.")]
            }
            if !arg.isEmpty && arg != "1" {
                return [.reply("522 Network protocol not supported, use (1).")]
            }
            return [.openPassiveListener(extended: true)]
        case "PORT":
            guard let parsed = FTPSession.parsePortArgument(argument) else {
                return [.reply("501 Invalid PORT argument.")]
            }
            dataMode = .active(host: parsed.host, port: parsed.port)
            return [.connectActive(host: parsed.host, port: parsed.port), .reply("200 PORT command successful.")]
        case "EPRT":
            guard let parsed = FTPSession.parseEPRTArgument(argument) else {
                return [.reply("522 Network protocol not supported, use (1).")]
            }
            dataMode = .active(host: parsed.host, port: parsed.port)
            return [.connectActive(host: parsed.host, port: parsed.port), .reply("200 EPRT command successful.")]
        case "STOR":
            return store(argument, append: false)
        case "APPE":
            return store(argument, append: true)
        case "RETR":
            return [.reply("550 Downloading from this server is not supported.")]
        case "SIZE":
            guard let target = resolve(argument), let attributes = regularFileAttributes(target.url) else {
                return [.reply("550 Could not get file size.")]
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return [.reply("213 \(size)")]
        case "MDTM":
            guard let target = resolve(argument), let attributes = regularFileAttributes(target.url),
                  let date = attributes[.modificationDate] as? Date else {
                return [.reply("550 Could not get modification time.")]
            }
            return [.reply("213 \(FTPSession.mdtmString(date))")]
        case "LIST", "NLST", "MLSD":
            return list(command: command, argument: argument)
        case "RNFR":
            guard let source = resolve(argument), fileManager.fileExists(atPath: source.url.path),
                  source.url.path != root.path else {
                renameSource = nil
                return [.reply("550 File not found.")]
            }
            renameSource = source.url
            return [.reply("350 Ready for RNTO.")]
        case "RNTO":
            return renameTo(argument)
        case "DELE":
            guard let target = resolve(argument) else {
                return [.reply("550 Invalid path.")]
            }
            let path = target.url.standardizedFileURL.path
            guard ownUploads.contains(path) else {
                return [.reply("550 Permission denied: only files uploaded in this session can be deleted.")]
            }
            do {
                try fileManager.removeItem(at: target.url)
                ownUploads.remove(path)
                return [.reply("250 File deleted.")]
            } catch {
                return [.reply("550 Could not delete file.")]
            }
        case "RMD", "XRMD":
            return [.reply("550 Removing directories is not allowed.")]
        case "ALLO":
            return [.reply("202 No storage allocation necessary.")]
        case "REST":
            if Int64(argument.trimmingCharacters(in: .whitespaces)) == 0 {
                return [.reply("350 Restarting at 0.")]
            }
            return [.reply("502 Resuming transfers is not supported.")]
        case "ABOR":
            return [.abortTransfer, .reply("226 ABOR command successful.")]
        case "STAT":
            return [.reply("211 CameraTransfer FTP server status OK.")]
        case "SITE", "CLNT", "HOST", "ACCT", "SMNT", "REIN":
            return [.reply("502 Command not implemented.")]
        default:
            return [.reply("502 Command not implemented.")]
        }
    }

    // MARK: Transport callbacks

    func passiveListenerReady(ipv4: String, port: UInt16, extended: Bool) -> String {
        dataMode = .passive
        if extended {
            return FTPSession.epsvReply(port: port)
        }
        return FTPSession.pasvReply(ipv4: ipv4, port: port)
    }

    func passiveListenerFailed() -> String {
        dataMode = .inactive
        return "425 Could not open a passive data port."
    }

    /// Called when the data connection of a STOR/APPE has closed.
    /// Returns the reply and, on success, the URL of the saved file.
    func storeFinished(success: Bool) -> (reply: String, savedFile: URL?) {
        dataMode = .inactive
        guard let pending = pendingStore else {
            return ("226 Transfer complete.", nil)
        }
        pendingStore = nil
        guard success else {
            if pending.part != pending.destination {
                try? fileManager.removeItem(at: pending.part)
            }
            return ("426 Connection closed; transfer aborted.", nil)
        }
        if pending.part != pending.destination {
            do {
                if fileManager.fileExists(atPath: pending.destination.path) {
                    try fileManager.removeItem(at: pending.destination)
                }
                try fileManager.moveItem(at: pending.part, to: pending.destination)
            } catch {
                try? fileManager.removeItem(at: pending.part)
                return ("451 Could not save the file.", nil)
            }
        }
        ownUploads.insert(pending.destination.standardizedFileURL.path)
        return ("226 Transfer complete.", pending.destination)
    }

    /// Called when a LIST/NLST/MLSD data transfer has finished.
    func sendFinished(success: Bool) -> String {
        dataMode = .inactive
        return success ? "226 Transfer complete." : "426 Connection closed; transfer aborted."
    }

    /// Called when a transfer was aborted (ABOR, timeout, or the control connection closed).
    func transferAborted() {
        dataMode = .inactive
        if let pending = pendingStore, pending.part != pending.destination {
            try? fileManager.removeItem(at: pending.part)
        }
        pendingStore = nil
    }

    // MARK: Path handling

    /// Resolves an FTP path argument against the current directory, confined to `root`.
    /// Any ".." component is rejected outright.
    func resolve(_ argument: String) -> (virtualPath: String, url: URL)? {
        if argument.contains("\0") || argument.contains("\\") { return nil }
        var components: [String] = argument.hasPrefix("/") ? [] : FTPSession.split(currentDirectory)
        for part in argument.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." { continue }
            if part == ".." { return nil }
            components.append(part)
        }
        var url = root
        for component in components {
            url.appendPathComponent(component)
        }
        let rootPath = root.path
        let resolvedPath = url.standardizedFileURL.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            return nil
        }
        return ("/" + components.joined(separator: "/"), url)
    }

    private static func split(_ virtualPath: String) -> [String] {
        virtualPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func regularFileAttributes(_ url: URL) -> [FileAttributeKey: Any]? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }
        return attributes
    }

    private func quoted(_ path: String) -> String {
        path.replacingOccurrences(of: "\"", with: "\"\"")
    }

    // MARK: Commands with logic

    private func changeDirectory(_ argument: String, allowParent: Bool = false) -> [FTPAction] {
        if allowParent {
            var components = FTPSession.split(currentDirectory)
            if !components.isEmpty { components.removeLast() }
            currentDirectory = "/" + components.joined(separator: "/")
            return [.reply("250 Directory changed to \(currentDirectory).")]
        }
        guard let target = resolve(argument), isDirectory(target.url) else {
            return [.reply("550 No such directory.")]
        }
        currentDirectory = target.virtualPath
        return [.reply("250 Directory changed to \(currentDirectory).")]
    }

    private func makeDirectory(_ argument: String) -> [FTPAction] {
        guard !argument.isEmpty, let target = resolve(argument), target.url.path != root.path else {
            return [.reply("550 Invalid directory name.")]
        }
        if isDirectory(target.url) {
            return [.reply("257 \"\(quoted(target.virtualPath))\" already exists.")]
        }
        do {
            try fileManager.createDirectory(at: target.url, withIntermediateDirectories: true)
            return [.reply("257 \"\(quoted(target.virtualPath))\" created.")]
        } catch {
            return [.reply("550 Could not create directory.")]
        }
    }

    private func store(_ argument: String, append: Bool) -> [FTPAction] {
        guard dataMode != .inactive else {
            return [.reply("425 Use PASV, EPSV or PORT first.")]
        }
        guard !argument.isEmpty, let target = resolve(argument), target.url.path != root.path,
              !isDirectory(target.url) else {
            return [.reply("553 File name not allowed.")]
        }
        let finalURL = target.url
        let directory = finalURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return [.reply("553 Could not create the destination folder.")]
        }
        let partURL: URL
        if append {
            partURL = finalURL
        } else {
            partURL = directory.appendingPathComponent("." + finalURL.lastPathComponent + ".part")
        }
        pendingStore = (partURL, finalURL, append)
        return [
            .reply("150 Opening BINARY mode data connection for \(finalURL.lastPathComponent)."),
            .receiveFile(partURL: partURL, finalURL: finalURL, append: append)
        ]
    }

    private func renameTo(_ argument: String) -> [FTPAction] {
        guard let source = renameSource else {
            return [.reply("503 Bad sequence of commands: send RNFR first.")]
        }
        renameSource = nil
        guard !argument.isEmpty, let target = resolve(argument), target.url.path != root.path else {
            return [.reply("553 File name not allowed.")]
        }
        do {
            if fileManager.fileExists(atPath: target.url.path) {
                guard !isDirectory(target.url) else {
                    return [.reply("553 A directory with that name exists.")]
                }
                try fileManager.removeItem(at: target.url)
            }
            try fileManager.createDirectory(at: target.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target.url)
        } catch {
            return [.reply("550 Rename failed.")]
        }
        let sourcePath = source.standardizedFileURL.path
        if ownUploads.contains(sourcePath) {
            ownUploads.remove(sourcePath)
            ownUploads.insert(target.url.standardizedFileURL.path)
        }
        return [.reply("250 Rename successful.")]
    }

    private func list(command: String, argument: String) -> [FTPAction] {
        guard dataMode != .inactive else {
            return [.reply("425 Use PASV, EPSV or PORT first.")]
        }
        // Ignore ls-style options such as "-la".
        let pathArgument = argument
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.hasPrefix("-") }
            .joined(separator: " ")
        guard let target = resolve(pathArgument), fileManager.fileExists(atPath: target.url.path) else {
            return [.reply("550 No such file or directory.")]
        }

        var urls: [URL] = []
        if isDirectory(target.url) {
            let contents = (try? fileManager.contentsOfDirectory(at: target.url,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
            urls = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            urls = [target.url]
        }

        var lines: [String] = []
        for url in urls {
            let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            let isDir = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attributes[.modificationDate] as? Date) ?? Date()
            let name = url.lastPathComponent
            switch command {
            case "NLST":
                lines.append(name)
            case "MLSD":
                let type = isDir ? "dir" : "file"
                lines.append("type=\(type);size=\(size);modify=\(FTPSession.mdtmString(date)); \(name)")
            default:
                lines.append(FTPSession.listLine(name: name, size: size, date: date, isDirectory: isDir))
            }
        }
        let body = lines.map { $0 + "\r\n" }.joined()
        return [
            .reply("150 Here comes the listing."),
            .sendData(Data(body.utf8))
        ]
    }

    // MARK: Formatting and parsing helpers (static so they are easy to test)

    static func pasvReply(ipv4: String, port: UInt16) -> String {
        var octets = ipv4.split(separator: ".").map(String.init)
        if octets.count != 4 || octets.contains(where: { UInt8($0) == nil }) {
            octets = ["0", "0", "0", "0"]
        }
        let high = Int(port) / 256
        let low = Int(port) % 256
        return "227 Entering Passive Mode (\(octets.joined(separator: ",")),\(high),\(low))."
    }

    static func epsvReply(port: UInt16) -> String {
        "229 Entering Extended Passive Mode (|||\(port)|)"
    }

    /// "h1,h2,h3,h4,p1,p2" -> ("h1.h2.h3.h4", p1 * 256 + p2)
    static func parsePortArgument(_ argument: String) -> (host: String, port: UInt16)? {
        let parts = argument.trimmingCharacters(in: .whitespaces).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 6 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            numbers.append(value)
        }
        let port = numbers[4] * 256 + numbers[5]
        guard port > 0 else { return nil }
        let host = numbers[0..<4].map(String.init).joined(separator: ".")
        return (host, UInt16(port))
    }

    /// "|1|132.235.1.2|6275|" -> ("132.235.1.2", 6275). Only IPv4 (protocol 1) is accepted.
    static func parseEPRTArgument(_ argument: String) -> (host: String, port: UInt16)? {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard let delimiter = trimmed.first else { return nil }
        let parts = trimmed.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        // ["", "1", "host", "port", ""]
        guard parts.count >= 4, parts[1] == "1" else { return nil }
        let host = parts[2]
        let octets = host.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        guard let port = UInt16(parts[3]), port > 0 else { return nil }
        return (host, port)
    }

    static func mdtmString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    static func listLine(name: String, size: Int64, date: Date, isDirectory: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM dd HH:mm"
        let permissions = isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        return "\(permissions) 1 camera camera \(size) \(formatter.string(from: date)) \(name)"
    }
}
