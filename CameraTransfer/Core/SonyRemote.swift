import Foundation
import Network

/// Sony's additions to PTP used by "PC Remote" (the same commands Imaging Edge Desktop sends).
/// Sources: community implementations tested on other Alpha bodies (A7C). Not yet confirmed on the A7CR.
enum SonyPTP {
    static let getDeviceInfo: UInt16 = 0x1001
    static let openSession: UInt16 = 0x1002
    static let getObject: UInt16 = 0x1009
    /// SDIO_Connect: three-phase handshake.
    static let sdioConnect: UInt16 = 0x9201
    static let getExtDeviceInfo: UInt16 = 0x9202
    /// Presses or releases a camera control (shutter button and so on).
    static let controlDevice: UInt16 = 0x9207
    static let getAllExtDevicePropInfo: UInt16 = 0x9209

    /// The live-view picture is read as a pseudo object with this handle.
    static let liveViewHandle: UInt32 = 0xFFFF_C002
    static let protocolVersion: UInt32 = 0x12C

    /// Shutter button half-press (S1) and full press (S2). Value 2 = down, 1 = up.
    static let halfPressControl: UInt32 = 0xD2C1
    static let fullPressControl: UInt32 = 0xD2C2
    static let buttonDown: UInt16 = 2
    static let buttonUp: UInt16 = 1

    static let accessDenied: UInt16 = 0x200F
    /// Sony: live view not ready yet.
    static let invalidObjectHandle: UInt16 = 0xA009

    /// The live-view object starts with the offset and size of the JPEG inside it (two 32-bit numbers).
    static func liveViewJPEG(from object: Data) -> Data? {
        let bytes = [UInt8](object.prefix(8))
        guard let offset = PTPIPCodec.u32(bytes, at: 0), let size = PTPIPCodec.u32(bytes, at: 4) else {
            return nil
        }
        let start = Int(offset)
        let length = Int(size)
        guard length >= 4, start >= 8, start + length <= object.count else { return nil }
        let base = object.startIndex
        let jpeg = object[(base + start)..<(base + start + length)]
        guard jpeg.first == 0xFF, jpeg.dropFirst().first == 0xD8 else { return nil }
        return Data(jpeg)
    }
}

/// Remembers this app's identity for the camera and where the camera was last seen.
enum SonyRemoteSettings {
    static let hostKey = "sonyRemoteHost"
    static let seenHostKey = "sonyLastSeenHost"
    private static let guidKey = "sonyRemoteGUID"
    static let friendlyName = "Camera Transfer"

    /// A random 16-byte identity, created once. The camera stores it when it is paired,
    /// so it must stay the same (a new one means pairing again).
    static func guid(_ defaults: UserDefaults = .standard) -> [UInt8] {
        if let stored = defaults.data(forKey: guidKey), stored.count == 16 {
            return [UInt8](stored)
        }
        var generator = SystemRandomNumberGenerator()
        let fresh = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        defaults.set(Data(fresh), forKey: guidKey)
        return fresh
    }

    /// The address typed in Settings, if any.
    static func manualHost(_ defaults: UserDefaults = .standard) -> String? {
        let value = (defaults.string(forKey: hostKey) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The camera's address the last time it connected to this app (for example to send photos by FTP).
    static func lastSeenHost(_ defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: seenHostKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static func rememberSeenHost(_ host: String, defaults: UserDefaults = .standard) {
        guard IPv4Address(host) != nil else { return }
        defaults.set(host, forKey: seenHostKey)
    }
}

/// Finds the camera on the networks this iPhone is on by looking for its remote-control port.
enum SonyDiscovery {
    /// Addresses worth trying on the same network as `local`, nearest guesses first.
    /// Assumes the usual home-network size (the last number of the address varies).
    static func candidates(onNetworkOf local: String) -> [String] {
        let parts = local.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        let own = parts[3]
        // Personal Hotspot hands out 172.20.10.2 to .14.
        let range: ClosedRange<Int> = (parts[0] == 172 && parts[1] == 20 && parts[2] == 10) ? 2...14 : 1...254
        return range.filter { $0 != own }.map { prefix + String($0) }
    }

    /// True if something accepts connections on the remote-control port at `host`.
    static func isListening(_ host: String, timeout: TimeInterval) async -> Bool {
        let channel = TCPChannel(host: host, port: PTPIPConnection.port)
        do {
            try await channel.connect(timeout: timeout)
            channel.close()
            return true
        } catch {
            return false
        }
    }

    /// Looks for the camera: the address from Settings, then where it was last seen, then a sweep of the local networks.
    static func findCamera(log: @escaping @Sendable (String) -> Void) async -> String? {
        var tried = Set<String>()
        for known in [SonyRemoteSettings.manualHost(), SonyRemoteSettings.lastSeenHost()].compactMap({ $0 }) {
            guard tried.insert(known).inserted else { continue }
            log("Trying the camera at \(known)...")
            if await isListening(known, timeout: 2) {
                return known
            }
        }
        let locals = NetworkInterfaces.ipv4Addresses()
        if locals.isEmpty {
            log("This iPhone has no Wi-Fi or hotspot address.")
            return nil
        }
        for local in locals {
            let hosts = candidates(onNetworkOf: local.address).filter { !tried.contains($0) }
            guard !hosts.isEmpty else { continue }
            log("Searching \(local.friendlyName) (\(local.address)) for the camera...")
            let batchSize = 32
            var index = 0
            while index < hosts.count {
                let batch = Array(hosts[index..<min(index + batchSize, hosts.count)])
                index += batchSize
                let found = await withTaskGroup(of: String?.self) { group -> String? in
                    for host in batch {
                        group.addTask {
                            await isListening(host, timeout: 0.8) ? host : nil
                        }
                    }
                    var hit: String?
                    for await result in group {
                        if let result, hit == nil { hit = result }
                    }
                    return hit
                }
                if let found {
                    return found
                }
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }
}

/// Live view and shutter for the Sony A7CR over PTP/IP ("PC Remote" over Wi-Fi).
///
/// The camera must have PC Remote on, Access Authen. off, and be paired with this iPhone once.
/// A single task owns the connection: it fetches frames in a loop and runs queued commands between frames.
final class SonyRemoteSession: RemoteSession, @unchecked Sendable {
    private typealias Command = @Sendable (PTPIPConnection) async throws -> String

    private struct Queued {
        let command: Command
        let continuation: CheckedContinuation<String, Error>
    }

    private let lock = NSLock()
    private var queue: [Queued] = []
    private var loopTask: Task<Void, Never>?
    private var connection: PTPIPConnection?
    private var running = false

    func start(onFrame: @escaping @Sendable (Data) -> Void,
               onLog: @escaping @Sendable (String) -> Void) async throws {
        guard let host = await SonyDiscovery.findCamera(log: onLog) else {
            throw RemoteSessionError.cameraNotFound(
                "Could not find the camera on this iPhone's network. Check that the camera's Wi-Fi shows as connected to the same network or hotspot, and that PC Remote is On.")
        }
        onLog("Found the camera at \(host). Connecting (confirm on the camera if it asks)...")
        let link = PTPIPConnection(host: host)
        do {
            try await link.open(guid: SonyRemoteSettings.guid(), name: SonyRemoteSettings.friendlyName)
            SonyRemoteSettings.rememberSeenHost(host)
            try await SonyRemoteSession.handshake(link, log: onLog)
        } catch {
            link.close()
            throw error
        }
        lock.lock()
        connection = link
        running = true
        lock.unlock()
        onLog("Remote session open. Asking for the live picture...")
        loopTask = Task { [weak self] in
            await self?.runLoop(link, onFrame: onFrame, onLog: onLog)
        }
    }

    private static func handshake(_ link: PTPIPConnection, log: @Sendable (String) -> Void) async throws {
        try await link.run(code: SonyPTP.getDeviceInfo)
        try await link.run(code: SonyPTP.openSession, parameters: [1])
        try await link.run(code: SonyPTP.sdioConnect, parameters: [1, 0, 0])
        try await link.run(code: SonyPTP.sdioConnect, parameters: [2, 0, 0])
        var ready = false
        for _ in 0..<20 {
            let info = try await link.transact(code: SonyPTP.getExtDeviceInfo, parameters: [SonyPTP.protocolVersion])
            if info.response == PTPIPConnection.responseOK, !info.data.isEmpty {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        guard ready else {
            throw PTPIPError.operationFailed(code: SonyPTP.getExtDeviceInfo, response: 0)
        }
        try await link.run(code: SonyPTP.sdioConnect, parameters: [3, 0, 0])
        // The first full property list. The values are not used, but the camera expects the request.
        let properties = try await link.transact(code: SonyPTP.getAllExtDevicePropInfo)
        log(String(format: "Handshake complete (property list: %d bytes, response 0x%04X).",
                   properties.data.count, properties.response))
    }

    private func nextCommand() -> Queued? {
        lock.lock()
        defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func runLoop(_ link: PTPIPConnection,
                         onFrame: @escaping @Sendable (Data) -> Void,
                         onLog: @escaping @Sendable (String) -> Void) async {
        var notReadyCount = 0
        var failure: Error?
        while isRunning(), !Task.isCancelled {
            while let queued = nextCommand() {
                do {
                    queued.continuation.resume(returning: try await queued.command(link))
                } catch {
                    queued.continuation.resume(throwing: error)
                }
            }
            do {
                let result = try await link.transact(code: SonyPTP.getObject, parameters: [SonyPTP.liveViewHandle])
                if result.response == SonyPTP.accessDenied || result.response == SonyPTP.invalidObjectHandle {
                    notReadyCount += 1
                    if notReadyCount == 100 {
                        onLog(String(format: "The camera keeps answering 0x%04X: live view is not available. Check the camera is in a shooting mode, not playback or a menu.", result.response))
                    }
                    try await Task.sleep(nanoseconds: 30_000_000)
                    continue
                }
                guard result.response == PTPIPConnection.responseOK else {
                    throw PTPIPError.operationFailed(code: SonyPTP.getObject, response: result.response)
                }
                notReadyCount = 0
                if let jpeg = SonyPTP.liveViewJPEG(from: result.data) {
                    onFrame(jpeg)
                }
            } catch {
                failure = error
                break
            }
        }
        if let failure, isRunning() {
            onLog("Live view stopped: \(CameraError.userMessage(for: failure, baseURL: nil))")
        }
        // Fail anything still waiting.
        while let queued = nextCommand() {
            queued.continuation.resume(throwing: failure ?? RemoteSessionError.notStarted)
        }
        lock.lock()
        running = false
        lock.unlock()
    }

    private func enqueue(_ command: @escaping Command) async throws -> String {
        guard isRunning() else { throw RemoteSessionError.notStarted }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.lock()
            if running {
                queue.append(Queued(command: command, continuation: continuation))
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume(throwing: RemoteSessionError.notStarted)
            }
        }
    }

    private static func press(_ link: PTPIPConnection, _ control: UInt32, _ value: UInt16) async throws {
        try await link.run(code: SonyPTP.controlDevice, parameters: [control], dataOut: PTPIPCodec.bytes(value))
    }

    /// Half-press to focus, full press, then release both.
    func takePhoto() async throws -> String {
        try await enqueue { link in
            do {
                try await SonyRemoteSession.press(link, SonyPTP.halfPressControl, SonyPTP.buttonDown)
                try await Task.sleep(nanoseconds: 700_000_000)
                try await SonyRemoteSession.press(link, SonyPTP.fullPressControl, SonyPTP.buttonDown)
                try await Task.sleep(nanoseconds: 300_000_000)
                try await SonyRemoteSession.press(link, SonyPTP.fullPressControl, SonyPTP.buttonUp)
                try await SonyRemoteSession.press(link, SonyPTP.halfPressControl, SonyPTP.buttonUp)
            } catch {
                // Never leave the camera's shutter button "held down".
                try? await SonyRemoteSession.press(link, SonyPTP.fullPressControl, SonyPTP.buttonUp)
                try? await SonyRemoteSession.press(link, SonyPTP.halfPressControl, SonyPTP.buttonUp)
                throw error
            }
            return "shutter half-press, full press, release"
        }
    }

    func stop() async {
        lock.lock()
        running = false
        let link = connection
        connection = nil
        let task = loopTask
        loopTask = nil
        lock.unlock()
        task?.cancel()
        link?.close()
        _ = await task?.value
    }
}
