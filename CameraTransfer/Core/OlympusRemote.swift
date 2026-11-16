import Foundation
import Network

/// Reassembles JPEG frames from the live-view stream of Olympus / OM System cameras.
///
/// The camera sends each frame as several UDP packets with a 12-byte RTP-style header:
/// the first packet of a frame has the extension bit set (0x90), the last has the marker bit set (0x..E0).
/// Documented by the community for E-M / TG bodies; assumed for the OM-3.
struct LiveViewAssembler {
    private var buffer = Data()
    private var collecting = false
    /// Frames larger than this are dropped (a sane upper bound for a live-view JPEG).
    static let maxFrameBytes = 4_000_000

    /// Feeds one UDP packet. Returns a complete JPEG when the packet finishes a frame.
    mutating func append(packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count > 12 else { return nil }
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        let isLast = (bytes[1] & 0x80) != 0

        var offset = 12 + 4 * csrcCount
        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let words = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4 + 4 * words
        }
        guard offset <= bytes.count else { return nil }
        let payload = bytes[offset...]

        if hasExtension {
            // First packet of a frame.
            buffer = Data(payload)
            collecting = true
        } else if collecting {
            buffer.append(contentsOf: payload)
        } else {
            return nil
        }

        if buffer.count > LiveViewAssembler.maxFrameBytes {
            buffer = Data()
            collecting = false
            return nil
        }
        guard isLast else { return nil }
        let frame = LiveViewAssembler.trimToJPEG(buffer)
        buffer = Data()
        collecting = false
        return frame
    }

    /// Cuts the data down to the first JPEG start marker through the last end marker; nil if there is none.
    static func trimToJPEG(_ data: Data) -> Data? {
        let soi = Data([0xFF, 0xD8])
        let eoi = Data([0xFF, 0xD9])
        guard let start = data.range(of: soi),
              let end = data.range(of: eoi, options: .backwards),
              end.lowerBound > start.lowerBound else {
            return nil
        }
        return Data(data[start.lowerBound..<end.upperBound])
    }
}

enum LiveViewError: LocalizedError {
    case badPort

    var errorDescription: String? {
        switch self {
        case .badPort: return "The live-view port is not valid."
        }
    }
}

/// Listens for the camera's live-view packets and hands back complete JPEG frames.
final class LiveViewReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "camera-transfer.liveview")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var assembler = LiveViewAssembler()
    private let onFrame: @Sendable (Data) -> Void

    init(onFrame: @escaping @Sendable (Data) -> Void) {
        self.onFrame = onFrame
    }

    func start(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LiveViewError.badPort
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: parameters, on: endpointPort)
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        newListener.start(queue: queue)
        queue.sync { self.listener = newListener }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, let frame = self.assembler.append(packet: data) {
                self.onFrame(frame)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections {
                connection.cancel()
            }
            self.connections = []
            self.assembler = LiveViewAssembler()
        }
    }
}

/// Remote-control commands of the OI.Share-style HTTP API (documented for older bodies; unconfirmed on the OM-3).
final class OlympusRemote: @unchecked Sendable {
    static let liveViewPort: UInt16 = 40000
    static let liveViewSize = "0640x0480"

    private let http: CameraHTTP

    init(baseURL: URL) {
        self.http = CameraHTTP(baseURL: baseURL,
                               headers: ["User-Agent": OlympusClient.userAgent],
                               requestTimeout: 10)
    }

    private func get(_ path: String, _ query: [(String, String)]) async throws -> Data {
        let items = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return try await http.get(try http.url(path: path, query: items))
    }

    /// The camera's own list of supported commands, for the troubleshooting log.
    func commandList() async -> String? {
        guard let data = try? await get("/get_commandlist.cgi", []) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Switches the camera to shooting mode and asks it to stream live view to `port` on this phone.
    func startLiveView(port: UInt16 = OlympusRemote.liveViewPort) async throws {
        _ = try await get("/switch_cammode.cgi", [("mode", "rec"), ("lvqty", OlympusRemote.liveViewSize)])
        _ = try await get("/exec_takemisc.cgi", [("com", "startliveview"), ("port", String(port))])
    }

    func stopLiveView() async {
        _ = try? await get("/exec_takemisc.cgi", [("com", "stopliveview")])
    }

    /// Back to playback mode so the photo browser works again.
    func returnToPlayback() async {
        _ = try? await get("/switch_cammode.cgi", [("mode", "play")])
    }

    /// Takes one photo. Returns the name of the command that the camera accepted.
    func takePhoto() async throws -> String {
        do {
            _ = try await get("/exec_takemotion.cgi", [("com", "newstarttake")])
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = try? await get("/exec_takemotion.cgi", [("com", "newstoptake")])
            return "newstarttake"
        } catch CameraError.httpStatus(_, _) {
            // Older command names.
            _ = try await get("/exec_takemotion.cgi", [("com", "starttake")])
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = try? await get("/exec_takemotion.cgi", [("com", "stoptake")])
            return "starttake"
        }
    }
}
