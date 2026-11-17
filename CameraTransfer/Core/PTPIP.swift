import Foundation
import Network

/// PTP/IP (Picture Transfer Protocol over TCP, port 15740) packet types.
enum PTPIPPacketType: UInt32 {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case commandRequest = 6
    case commandResponse = 7
    case event = 8
    case startData = 9
    case data = 10
    case cancel = 11
    case endData = 12
    case probeRequest = 13
    case probeResponse = 14
}

enum PTPIPError: LocalizedError, Equatable {
    case closed
    case timedOut(String)
    case refused
    case unexpectedPacket(UInt32)
    case badPacketLength(Int)
    case operationFailed(code: UInt16, response: UInt16)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .closed:
            return "The camera closed the connection."
        case .timedOut(let what):
            return "Timed out \(what)."
        case .refused:
            return "The camera refused the connection. This iPhone is not paired with it for remote control yet."
        case .unexpectedPacket(let type):
            return "The camera sent an unexpected reply (packet type \(type))."
        case .badPacketLength(let length):
            return "The camera sent a packet with an impossible length (\(length))."
        case .operationFailed(let code, let response):
            return String(format: "The camera rejected command 0x%04X (response 0x%04X).", code, response)
        case .notConnected:
            return "Not connected to the camera."
        }
    }
}

/// Builds and parses PTP/IP packets. Pure functions, unit tested. All integers are little-endian.
enum PTPIPCodec {
    static let protocolVersion: UInt32 = 0x0001_0000

    static func bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    static func bytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }

    static func u16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func u32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << (8 * UInt32(index))
        }
        return value
    }

    static func u64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        return value
    }

    /// Length (4 bytes, including this 8-byte header), type (4 bytes), payload.
    static func packet(_ type: PTPIPPacketType, _ payload: [UInt8] = []) -> Data {
        var out = bytes(UInt32(payload.count + 8))
        out += bytes(type.rawValue)
        out += payload
        return Data(out)
    }

    /// First packet on the command connection: our identity (remembered by the camera once paired) and name.
    static func initCommandRequest(guid: [UInt8], name: String) -> Data {
        var payload = guid
        for unit in name.utf16 {
            payload += bytes(unit)
        }
        payload += [0, 0]
        payload += bytes(protocolVersion)
        return packet(.initCommandRequest, payload)
    }

    static func initEventRequest(connectionNumber: UInt32) -> Data {
        packet(.initEventRequest, bytes(connectionNumber))
    }

    /// An operation request. `hasDataOut` is true when a data phase from us to the camera follows.
    static func commandRequest(code: UInt16, transactionID: UInt32, parameters: [UInt32], hasDataOut: Bool) -> Data {
        var payload = bytes(UInt32(hasDataOut ? 2 : 1))
        payload += bytes(code)
        payload += bytes(transactionID)
        for parameter in parameters {
            payload += bytes(parameter)
        }
        return packet(.commandRequest, payload)
    }

    /// The data phase for an operation that sends data to the camera: Start Data then End Data carrying it all.
    static func dataOut(transactionID: UInt32, data: [UInt8]) -> Data {
        var start = bytes(transactionID)
        start += bytes(UInt64(data.count))
        var out = packet(.startData, start)
        out.append(packet(.endData, bytes(transactionID) + data))
        return out
    }

    static func probeResponse() -> Data {
        packet(.probeResponse)
    }
}

/// A TCP connection with async send and exact-length reads. One reader at a time.
final class TCPChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private let lock = NSLock()
    private var closed = false

    init(host: String, port: UInt16) {
        let parameters = NWParameters.tcp
        // The camera is on the local network; never try cellular.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 15740)
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        self.queue = DispatchQueue(label: "camera-transfer.tcp.\(host)")
    }

    /// Opens the connection. Throws if it is not ready within `timeout` seconds.
    func connect(timeout: TimeInterval) async throws {
        do {
            try await startConnection(timeout: timeout)
        } catch {
            close()
            throw error
        }
    }

    private func startConnection(timeout: TimeInterval) async throws {
        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume() }
                case .failed(let error):
                    if gate.claim() { continuation.resume(throwing: error) }
                case .waiting(let error):
                    // "Waiting" means no route yet (wrong network, port closed); treat as failure.
                    if gate.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if gate.claim() { continuation.resume(throwing: PTPIPError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    continuation.resume(throwing: PTPIPError.timedOut("connecting"))
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads exactly `count` bytes. If nothing arrives for `timeout` seconds the connection is closed and this throws.
    func read(exactly count: Int, timeout: TimeInterval) async throws -> Data {
        guard count > 0 else { return Data() }
        let watchdog = DispatchWorkItem { [weak self] in
            self?.close()
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        while buffer.count < count {
            let chunk = try await receiveSome()
            buffer.append(chunk)
        }
        let out = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return out
    }

    private func receiveSome() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(throwing: PTPIPError.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        if !alreadyClosed {
            connection.cancel()
        }
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// One PTP/IP session: a command connection and an event connection to the camera.
/// Transactions must be run one at a time (the owner runs them from a single task).
final class PTPIPConnection: @unchecked Sendable {
    static let port: UInt16 = 15740
    static let responseOK: UInt16 = 0x2001

    let host: String
    private var command: TCPChannel?
    private var events: TCPChannel?
    private var eventTask: Task<Void, Never>?
    private var transactionID: UInt32 = 0

    init(host: String) {
        self.host = host
    }

    private func readPacket(_ channel: TCPChannel, timeout: TimeInterval) async throws -> (type: UInt32, body: [UInt8]) {
        let header = [UInt8](try await channel.read(exactly: 8, timeout: timeout))
        guard let length = PTPIPCodec.u32(header, at: 0), let type = PTPIPCodec.u32(header, at: 4) else {
            throw PTPIPError.closed
        }
        guard length >= 8, length <= 64 * 1024 * 1024 else {
            throw PTPIPError.badPacketLength(Int(length))
        }
        let body = [UInt8](try await channel.read(exactly: Int(length) - 8, timeout: timeout))
        return (type, body)
    }

    /// Connects and identifies this app to the camera. `promptTimeout` is long because the camera may
    /// show a "connect?" prompt that the user has to confirm the first time.
    func open(guid: [UInt8], name: String, connectTimeout: TimeInterval = 5, promptTimeout: TimeInterval = 90) async throws {
        let commandChannel = TCPChannel(host: host, port: PTPIPConnection.port)
        try await commandChannel.connect(timeout: connectTimeout)
        command = commandChannel
        do {
            try await commandChannel.send(PTPIPCodec.initCommandRequest(guid: guid, name: name))
            let reply = try await readPacket(commandChannel, timeout: promptTimeout)
            if reply.type == PTPIPPacketType.initFail.rawValue {
                throw PTPIPError.refused
            }
            guard reply.type == PTPIPPacketType.initCommandAck.rawValue,
                  let connectionNumber = PTPIPCodec.u32(reply.body, at: 0) else {
                throw PTPIPError.unexpectedPacket(reply.type)
            }

            let eventChannel = TCPChannel(host: host, port: PTPIPConnection.port)
            try await eventChannel.connect(timeout: connectTimeout)
            events = eventChannel
            try await eventChannel.send(PTPIPCodec.initEventRequest(connectionNumber: connectionNumber))
            let eventReply = try await readPacket(eventChannel, timeout: 10)
            guard eventReply.type == PTPIPPacketType.initEventAck.rawValue else {
                throw PTPIPError.unexpectedPacket(eventReply.type)
            }
            startDrainingEvents(eventChannel)
        } catch {
            close()
            throw error
        }
    }

    /// Events are not used, but they must be read, and the camera's keep-alive probes must be answered.
    private func startDrainingEvents(_ channel: TCPChannel) {
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let packet = try? await self.readPacket(channel, timeout: 3600) else { return }
                if packet.type == PTPIPPacketType.probeRequest.rawValue {
                    try? await channel.send(PTPIPCodec.probeResponse())
                }
            }
        }
    }

    /// Runs one operation. Returns the camera's response code and any data it sent back.
    func transact(code: UInt16,
                  parameters: [UInt32] = [],
                  dataOut: [UInt8]? = nil,
                  timeout: TimeInterval = 10) async throws -> (response: UInt16, data: Data) {
        guard let command else { throw PTPIPError.notConnected }
        transactionID &+= 1
        var request = PTPIPCodec.commandRequest(code: code,
                                                transactionID: transactionID,
                                                parameters: parameters,
                                                hasDataOut: dataOut != nil)
        if let dataOut {
            request.append(PTPIPCodec.dataOut(transactionID: transactionID, data: dataOut))
        }
        try await command.send(request)

        var received = Data()
        while true {
            let packet = try await readPacket(command, timeout: timeout)
            switch packet.type {
            case PTPIPPacketType.startData.rawValue:
                if let total = PTPIPCodec.u64(packet.body, at: 4), total < 64 * 1024 * 1024 {
                    received.reserveCapacity(Int(total))
                }
            case PTPIPPacketType.data.rawValue, PTPIPPacketType.endData.rawValue:
                if packet.body.count > 4 {
                    received.append(contentsOf: packet.body[4...])
                }
            case PTPIPPacketType.commandResponse.rawValue:
                guard let response = PTPIPCodec.u16(packet.body, at: 0) else {
                    throw PTPIPError.unexpectedPacket(packet.type)
                }
                return (response, received)
            default:
                // Ignore anything else (for example a stray cancel).
                break
            }
        }
    }

    /// Like `transact`, but throws unless the camera answers OK.
    @discardableResult
    func run(code: UInt16, parameters: [UInt32] = [], dataOut: [UInt8]? = nil) async throws -> Data {
        let result = try await transact(code: code, parameters: parameters, dataOut: dataOut)
        guard result.response == PTPIPConnection.responseOK else {
            throw PTPIPError.operationFailed(code: code, response: result.response)
        }
        return result.data
    }

    func close() {
        eventTask?.cancel()
        eventTask = nil
        command?.close()
        events?.close()
        command = nil
        events = nil
    }
}
