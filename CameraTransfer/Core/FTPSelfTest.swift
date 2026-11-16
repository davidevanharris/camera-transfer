import Foundation
import Network

/// Result of the "Check the server" button on the Sony screen.
enum FTPSelfTestState: Equatable, Sendable {
    case idle
    case running
    case passed(String)
    case failed(String)
}

/// How the camera reaches this phone.
enum SonyLink: String, CaseIterable, Identifiable, Sendable {
    case hotspot
    case wifi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hotspot: return "Personal Hotspot"
        case .wifi: return "Same Wi-Fi"
        }
    }
}

enum FTPProbeError: LocalizedError {
    case timeout
    case badPort
    case unexpectedReply(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "No answer in time."
        case .badPort:
            return "The port number is not valid."
        case .unexpectedReply(let text):
            return "Unexpected answer: \(text)"
        }
    }
}

/// Lets exactly one of several racing callbacks win.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// A minimal FTP client used only to check this app's own server: connect, read the greeting, log in, quit.
final class FTPProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "camera-transfer.ftp-probe")

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw FTPProbeError.badPort
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func open(timeout: TimeInterval) async throws {
        let connection = self.connection
        let queue = self.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OnceGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.fire() { continuation.resume() }
                case .failed(let error):
                    if gate.fire() { continuation.resume(throwing: error) }
                case .waiting(let error):
                    if gate.fire() { continuation.resume(throwing: error) }
                case .cancelled:
                    if gate.fire() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if gate.fire() {
                    connection.cancel()
                    continuation.resume(throwing: FTPProbeError.timeout)
                }
            }
        }
    }

    func readReply(timeout: TimeInterval) async throws -> String {
        let connection = self.connection
        let queue = self.queue
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = OnceGate()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    if gate.fire() { continuation.resume(throwing: error) }
                    return
                }
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if gate.fire() { continuation.resume(returning: text) }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if gate.fire() { continuation.resume(throwing: FTPProbeError.timeout) }
            }
        }
    }

    func send(_ line: String) async throws {
        let connection = self.connection
        let data = Data((line + "\r\n").utf8)
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

    func close() {
        connection.cancel()
    }
}

enum FTPSelfTest {
    /// Pure check of a server reply against the expected three-digit code.
    static func reply(_ text: String, hasCode code: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix(code) }
    }

    static func run(host: String, port: UInt16, username: String, password: String) async -> FTPSelfTestState {
        let probe: FTPProbe
        do {
            probe = try FTPProbe(host: host, port: port)
        } catch {
            return .failed(error.localizedDescription)
        }
        defer { probe.close() }
        do {
            try await probe.open(timeout: 5)
            let greeting = try await probe.readReply(timeout: 5)
            guard reply(greeting, hasCode: "220") else {
                throw FTPProbeError.unexpectedReply(greeting)
            }
            try await probe.send("USER \(username)")
            let userReply = try await probe.readReply(timeout: 5)
            guard reply(userReply, hasCode: "331") || reply(userReply, hasCode: "230") else {
                throw FTPProbeError.unexpectedReply(userReply)
            }
            try await probe.send("PASS \(password)")
            let passReply = try await probe.readReply(timeout: 5)
            guard reply(passReply, hasCode: "230") else {
                throw FTPProbeError.unexpectedReply(passReply)
            }
            try? await probe.send("QUIT")
            return .passed("The server answered at \(host), port \(port), and accepted the user name and password.")
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed("The server did not answer at \(host), port \(port). \(detail)")
        }
    }
}
