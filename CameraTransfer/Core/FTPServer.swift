import Foundation
import Network

/// Events published by the FTP server for display in the UI.
enum FTPEvent: Sendable {
    case started(port: UInt16)
    case stopped
    case failed(String)
    case clientConnected(String)
    case clientDisconnected(String)
    case loggedIn(String)
    case fileReceived(name: String, size: Int64, url: URL)
    case transferFailed(String)
    case log(String)
}

enum FTPServerError: LocalizedError {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Port \(port) is not valid. Use a number between 1024 and 65535."
        }
    }
}

/// Minimal FTP server (Network.framework transport) that receives files pushed by the Sony
/// "FTP Transfer" feature. All networking happens on one private serial queue.
final class FTPServer: @unchecked Sendable {
    let port: UInt16
    let root: URL
    let username: String
    let password: String

    private let queue = DispatchQueue(label: "CameraTransfer.FTPServer")
    private let onEvent: @Sendable (FTPEvent) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: FTPControlConnection] = [:]

    init(port: UInt16, root: URL, username: String, password: String,
         onEvent: @escaping @Sendable (FTPEvent) -> Void) {
        self.port = port
        self.root = root
        self.username = username
        self.password = password
        self.onEvent = onEvent
    }

    static func ipv4TCPParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        return parameters
    }

    func start() throws {
        guard port >= 1, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw FTPServerError.invalidPort(Int(port))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let listener = try NWListener(using: FTPServer.ipv4TCPParameters(), on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.started(port: self.port))
            case .failed(let error):
                self.emit(.failed("The FTP server stopped: \(error.localizedDescription)"))
                self.stopOnQueue()
            case .waiting(let error):
                self.emit(.log("Waiting for network: \(error.localizedDescription)"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        queue.sync {
            self.listener = listener
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
            self?.emit(.stopped)
        }
    }

    // MARK: Queue-confined internals

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        for connection in open {
            connection.close()
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = FTPSession(root: root, username: username, password: password)
        let control = FTPControlConnection(connection: connection, session: session, queue: queue, server: self)
        connections[ObjectIdentifier(control)] = control
        control.start()
    }

    fileprivate func connectionClosed(_ control: FTPControlConnection) {
        connections.removeValue(forKey: ObjectIdentifier(control))
    }

    fileprivate func emit(_ event: FTPEvent) {
        onEvent(event)
    }
}

/// One FTP control connection plus its (at most one) data connection.
final class FTPControlConnection: @unchecked Sendable {
    private enum PendingTransfer {
        case receive(partURL: URL, append: Bool)
        case send(Data)
    }

    private let connection: NWConnection
    private let session: FTPSession
    private let queue: DispatchQueue
    private weak var server: FTPServer?
    private let remoteName: String

    private var lineBuffer = Data()
    private var isClosed = false
    private var didGreet = false

    private var passiveListener: NWListener?
    private var passiveAnnounced = false
    private var dataConnection: NWConnection?
    private var dataConnectionReady = false
    private var pendingTransfer: PendingTransfer?
    private var transferInProgress = false
    private var transferGeneration = 0
    private var fileHandle: FileHandle?
    private var receivedBytes: Int64 = 0

    private static let maxLineLength = 8 * 1024
    private static let dataConnectionTimeout: TimeInterval = 30

    init(connection: NWConnection, session: FTPSession, queue: DispatchQueue, server: FTPServer) {
        self.connection = connection
        self.session = session
        self.queue = queue
        self.server = server
        switch connection.endpoint {
        case .hostPort(let host, _):
            self.remoteName = NetworkInterfaces.hostKey(host)
        default:
            self.remoteName = "\(connection.endpoint)"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !self.didGreet {
                    self.didGreet = true
                    self.server?.emit(.clientConnected(self.remoteName))
                    self.send(FTPSession.greeting)
                    self.receiveControl()
                }
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        abortDataTransfer()
        connection.cancel()
        server?.emit(.clientDisconnected(remoteName))
        server?.connectionClosed(self)
    }

    // MARK: Control channel

    private func send(_ reply: String) {
        guard !isClosed else { return }
        let data = Data((reply + "\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func receiveControl() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.lineBuffer.append(data)
                self.processLines()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.isClosed {
                self.receiveControl()
            }
        }
    }

    private func processLines() {
        while !isClosed, let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
            let line = String(decoding: lineData, as: UTF8.self)
            handle(line: line)
        }
        if lineBuffer.count > FTPControlConnection.maxLineLength {
            send("500 Line too long.")
            close()
        }
    }

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let upper = trimmed.uppercased()
        if upper.hasPrefix("PASS ") {
            server?.emit(.log("\(remoteName): PASS ****"))
        } else if !trimmed.isEmpty {
            server?.emit(.log("\(remoteName): \(trimmed)"))
        }

        let wasLoggedIn = session.isLoggedIn
        let actions = session.handle(line: trimmed)
        if !wasLoggedIn && session.isLoggedIn {
            server?.emit(.loggedIn(remoteName))
        } else if upper.hasPrefix("PASS ") && !session.isLoggedIn {
            server?.emit(.log("\(remoteName): login rejected"))
        }
        for action in actions {
            perform(action)
        }
    }

    private func perform(_ action: FTPAction) {
        switch action {
        case .reply(let text):
            send(text)
        case .openPassiveListener(let extended):
            openPassiveListener(extended: extended)
        case .connectActive(let host, let port):
            connectActive(host: host, port: port)
        case .receiveFile(let partURL, _, let append):
            queueTransfer(.receive(partURL: partURL, append: append))
        case .sendData(let data):
            queueTransfer(.send(data))
        case .abortTransfer:
            abortDataTransfer()
        case .close:
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed({ [weak self] _ in
                                self?.close()
                            }))
        }
    }

    // MARK: Data channel

    private func resetDataChannel() {
        passiveListener?.cancel()
        passiveListener = nil
        dataConnection?.cancel()
        dataConnection = nil
        dataConnectionReady = false
    }

    private func openPassiveListener(extended: Bool) {
        if transferInProgress {
            abortDataTransfer()
        }
        resetDataChannel()
        let listener: NWListener
        do {
            listener = try NWListener(using: FTPServer.ipv4TCPParameters(), on: .any)
        } catch {
            send(session.passiveListenerFailed())
            return
        }
        passiveListener = listener
        passiveAnnounced = false
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.passiveListener === listener else { return }
            switch state {
            case .ready:
                guard !self.passiveAnnounced else { return }
                self.passiveAnnounced = true
                guard let port = listener.port?.rawValue else {
                    self.send(self.session.passiveListenerFailed())
                    return
                }
                let address = self.localIPv4Address() ?? "0.0.0.0"
                self.send(self.session.passiveListenerReady(ipv4: address, port: port, extended: extended))
            case .failed:
                self.passiveListener = nil
                listener.cancel()
                if !self.passiveAnnounced {
                    self.passiveAnnounced = true
                    self.send(self.session.passiveListenerFailed())
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] incoming in
            guard let self, let listener, self.passiveListener === listener else {
                incoming.cancel()
                return
            }
            // Only accept data connections from the same host as the control connection.
            if case .hostPort(let host, _) = incoming.endpoint,
               NetworkInterfaces.hostKey(host) != self.remoteName {
                self.server?.emit(.log("Rejected data connection from \(NetworkInterfaces.hostKey(host))"))
                incoming.cancel()
                return
            }
            listener.cancel()
            self.passiveListener = nil
            self.adoptDataConnection(incoming)
        }
        listener.start(queue: queue)
    }

    private func connectActive(host: String, port: UInt16) {
        if transferInProgress {
            abortDataTransfer()
        }
        resetDataChannel()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let outgoing = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: FTPServer.ipv4TCPParameters())
        adoptDataConnection(outgoing)
    }

    private func adoptDataConnection(_ newConnection: NWConnection) {
        dataConnection?.cancel()
        dataConnection = newConnection
        dataConnectionReady = false
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.dataConnection === newConnection else { return }
            switch state {
            case .ready:
                self.dataConnectionReady = true
                self.startTransferIfPossible()
            case .failed(let error):
                self.server?.emit(.log("Data connection failed: \(error.localizedDescription)"))
                self.failCurrentTransfer()
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func queueTransfer(_ transfer: PendingTransfer) {
        pendingTransfer = transfer
        transferGeneration += 1
        let generation = transferGeneration
        queue.asyncAfter(deadline: .now() + FTPControlConnection.dataConnectionTimeout) { [weak self] in
            guard let self, self.transferGeneration == generation,
                  self.pendingTransfer != nil, !self.transferInProgress else { return }
            self.pendingTransfer = nil
            self.session.transferAborted()
            self.resetDataChannel()
            self.send("425 Could not open data connection.")
        }
        startTransferIfPossible()
    }

    private func startTransferIfPossible() {
        guard !isClosed, dataConnectionReady, !transferInProgress,
              let data = dataConnection, let transfer = pendingTransfer else { return }
        pendingTransfer = nil
        transferInProgress = true
        let generation = transferGeneration
        switch transfer {
        case .send(let payload):
            data.send(content: payload, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed({ [weak self] error in
                          guard let self, self.transferGeneration == generation else { return }
                          self.finishSend(success: error == nil)
                      }))
        case .receive(let partURL, let append):
            let fileManager = FileManager.default
            if !append || !fileManager.fileExists(atPath: partURL.path) {
                _ = fileManager.createFile(atPath: partURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: partURL) else {
                finishReceive(success: false)
                return
            }
            if append {
                _ = try? handle.seekToEnd()
            }
            fileHandle = handle
            receivedBytes = 0
            receiveChunk(on: data, generation: generation)
        }
    }

    private func receiveChunk(on data: NWConnection, generation: Int) {
        data.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, error in
            guard let self, self.transferGeneration == generation, self.transferInProgress else { return }
            if let content, !content.isEmpty {
                do {
                    try self.fileHandle?.write(contentsOf: content)
                    self.receivedBytes += Int64(content.count)
                } catch {
                    self.server?.emit(.transferFailed("Could not write file: \(error.localizedDescription)"))
                    self.finishReceive(success: false)
                    return
                }
            }
            if let error {
                self.server?.emit(.transferFailed("Upload interrupted: \(error.localizedDescription)"))
                self.finishReceive(success: false)
            } else if isComplete {
                self.finishReceive(success: true)
            } else {
                self.receiveChunk(on: data, generation: generation)
            }
        }
    }

    private func finishReceive(success: Bool) {
        closeFileHandle()
        transferInProgress = false
        resetDataChannel()
        let result = session.storeFinished(success: success)
        send(result.reply)
        if let url = result.savedFile {
            server?.emit(.fileReceived(name: url.lastPathComponent, size: receivedBytes, url: url))
        }
    }

    private func finishSend(success: Bool) {
        transferInProgress = false
        resetDataChannel()
        send(session.sendFinished(success: success))
    }

    private func failCurrentTransfer() {
        if transferInProgress {
            if fileHandle != nil {
                finishReceive(success: false)
            } else {
                finishSend(success: false)
            }
        } else {
            dataConnection?.cancel()
            dataConnection = nil
            dataConnectionReady = false
        }
    }

    /// Silently abandons any transfer in progress (ABOR, new PASV/PORT, or connection closing).
    private func abortDataTransfer() {
        transferGeneration += 1
        let hadTransfer = transferInProgress || pendingTransfer != nil
        transferInProgress = false
        pendingTransfer = nil
        closeFileHandle()
        resetDataChannel()
        if hadTransfer {
            session.transferAborted()
        }
    }

    private func closeFileHandle() {
        if let handle = fileHandle {
            try? handle.synchronize()
            try? handle.close()
        }
        fileHandle = nil
    }

    /// The IPv4 address the camera used to reach us; advertised in the PASV reply.
    private func localIPv4Address() -> String? {
        if let path = connection.currentPath, let local = path.localEndpoint,
           case .hostPort(let host, _) = local,
           let address = NetworkInterfaces.ipv4String(from: host),
           address != "0.0.0.0" {
            return address
        }
        return NetworkInterfaces.preferredIPv4()
    }
}
