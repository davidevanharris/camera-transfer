import Foundation
import UIKit
import Observation

/// Observes the phone's battery (UIDevice battery monitoring).
@MainActor
@Observable
final class PhoneBatteryMonitor {
    static let shared = PhoneBatteryMonitor()

    /// 0...100, or nil when unknown (the Simulator reports -1).
    private(set) var percent: Int?
    /// Charging or full.
    private(set) var isCharging = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
            observers.append(token)
        }
    }

    func refresh() {
        let level = UIDevice.current.batteryLevel
        percent = level < 0 ? nil : Int((level * 100).rounded())
        let state = UIDevice.current.batteryState
        isCharging = state == .charging || state == .full
    }

    func decision(for camera: CameraBatteryReading, mode: AutoTransferMode? = nil) -> TransferDecision {
        refresh()
        return TransferPolicy.evaluate(mode: mode ?? AutoTransferSettings.mode(),
                                       phonePercent: percent,
                                       phoneCharging: isCharging,
                                       camera: camera,
                                       allowWhenCameraBatteryUnknown: AutoTransferSettings.allowWhenCameraBatteryUnknown())
    }
}

/// Lets the app finish an in-flight file for a short time after going to the background.
@MainActor
final class BackgroundTaskBox {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(_ name: String) {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// What a camera tab provides to its auto-transfer coordinator.
@MainActor
protocol AutoTransferHost: AnyObject {
    /// Wakes / reaches the camera and returns a ready client (Ricoh: BLE wake, join, ping).
    func autoTransferPrepareClient() async throws -> CameraClient
    func autoTransferCameraBattery(info: CameraDeviceInfo?) -> CameraBatteryReading
    func autoTransferFinish(client: CameraClient) async
    func autoTransferDidSave(_ photo: RemotePhoto)
}

/// Polls a camera for new shots and sends their full-size JPEGs to Photos (add-only) while the
/// transfer policy allows. Runs only while the app is active; an in-flight file may finish in the
/// background thanks to a background task, nothing more.
@MainActor
@Observable
final class AutoTransferCoordinator {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case polling
        case transferring(String)
        case paused(String)
        case failed(String)
        case stopped(String)
    }

    let camera: CameraModel
    private(set) var phase: Phase = .idle
    private(set) var isRunning = false
    private(set) var transferredCount = 0
    private(set) var lastError: String?

    @ObservationIgnored weak var host: AutoTransferHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopAfterCurrent = false
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let background = BackgroundTaskBox()

    private static let pollInterval: UInt64 = 3_000_000_000
    private static let maxConsecutiveFailures = 5

    init(camera: CameraModel, store: LibraryStore = .shared) {
        self.camera = camera
        self.store = store
    }

    var statusText: String {
        switch phase {
        case .idle: return "Auto-transfer idle."
        case .preparing(let step): return step
        case .polling: return "Watching for new shots... (\(transferredCount) sent to Photos)"
        case .transferring(let name): return "Sending \(name) to Photos..."
        case .paused(let reason): return reason
        case .failed(let message): return message
        case .stopped(let message): return message
        }
    }

    func start(trigger: String) {
        guard !isRunning else { return }
        guard AutoTransferSettings.mode() != .manual else { return }
        isRunning = true
        stopAfterCurrent = false
        lastError = nil
        phase = .preparing("Starting auto-transfer (\(trigger))...")
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop(_ message: String = "Auto-transfer stopped.") {
        task?.cancel()
        task = nil
        if isRunning {
            phase = .stopped(message)
        }
    }

    /// Called when the app goes to the background: finish the current file, then stop.
    func stopAfterCurrentFile() {
        stopAfterCurrent = true
    }

    private func decision(info: CameraDeviceInfo?) -> TransferDecision {
        let reading = host?.autoTransferCameraBattery(info: info) ?? .unknown
        return PhoneBatteryMonitor.shared.decision(for: reading)
    }

    private func run() async {
        defer {
            isRunning = false
            task = nil
            background.end()
        }
        guard let host = self.host else { return }

        // Check the phone side before waking anything up.
        let early = PhoneBatteryMonitor.shared.decision(for: .notApplicable)
        if !early.allowed {
            phase = .paused(early.reason)
            return
        }

        let client: CameraClient
        do {
            phase = .preparing("Connecting to the \(camera.displayName)...")
            client = try await host.autoTransferPrepareClient()
        } catch {
            if !Task.isCancelled {
                phase = .failed("Auto-transfer could not reach the camera: \(CameraError.userMessage(for: error, baseURL: nil))")
            }
            return
        }

        var info = try? await client.deviceInfo()
        var failures = 0
        var cycle = 0

        polling: while !Task.isCancelled && !stopAfterCurrent {
            if AutoTransferSettings.mode() == .manual {
                phase = .stopped("Auto-transfer turned off.")
                break
            }
            if cycle > 0 && cycle % 10 == 0, let fresh = try? await client.deviceInfo() {
                info = fresh
            }
            cycle += 1

            let gate = decision(info: info)
            if !gate.allowed {
                phase = .paused(gate.reason)
                break
            }

            do {
                let list = try await client.listPhotos()
                let baseline: Set<String>
                if let existing = store.baselineIDs(for: camera) {
                    baseline = existing
                } else {
                    // First listing since arming: everything already on the card is "old".
                    baseline = Set(list.map(\.id))
                    store.setBaseline(baseline, for: camera)
                }
                let downloaded = store.downloadedIDs(for: camera)
                let fresh = list
                    .filter { $0.kind == .jpeg && !baseline.contains($0.id) && !downloaded.contains($0.id) }
                    .sorted { lhs, rhs in
                        if let l = lhs.date, let r = rhs.date, l != r { return l < r }
                        return lhs.id < rhs.id
                    }
                for photo in fresh {
                    if Task.isCancelled { break polling }
                    let fileGate = decision(info: info)
                    if !fileGate.allowed {
                        phase = .paused(fileGate.reason)
                        break polling
                    }
                    phase = .transferring(photo.filename)
                    try await transfer(photo, with: client)
                    if stopAfterCurrent { break polling }
                }
                failures = 0
                phase = .polling
            } catch {
                if Task.isCancelled { break }
                failures += 1
                lastError = CameraError.userMessage(for: error, baseURL: nil)
                if failures >= AutoTransferCoordinator.maxConsecutiveFailures {
                    phase = .failed("Lost the camera: \(lastError ?? "unknown error")")
                    break
                }
                phase = .preparing("Camera not answering, retrying (\(failures))...")
            }

            do {
                try await Task.sleep(nanoseconds: AutoTransferCoordinator.pollInterval)
            } catch {
                break
            }
        }

        if stopAfterCurrent {
            phase = .stopped("Paused while the app is in the background. iOS drops the camera Wi-Fi about a minute after the app leaves the foreground.")
        }
        await host.autoTransferFinish(client: client)
    }

    /// Downloads the full-size JPEG, adds it to Photos (add-only), and deletes the local copy unless
    /// "Keep a copy in the app folder" is on. If adding to Photos fails, the file is kept.
    private func transfer(_ photo: RemotePhoto, with client: CameraClient) async throws {
        background.begin("CameraTransfer.\(camera.rawValue).\(photo.filename)")
        defer { background.end() }

        let destination = store.destination(for: photo, camera: camera)
        try await client.download(photo, to: destination, progress: { _ in })
        store.markDownloaded(photo.id, camera: camera)
        host?.autoTransferDidSave(photo)

        do {
            let result = try await PhotoExporter.export([destination])
            if result.added > 0 && result.failures.isEmpty {
                transferredCount += 1
                if !AutoTransferSettings.keepCopy() {
                    try? store.deleteFile(at: destination)
                }
            } else {
                lastError = "Could not add \(photo.filename) to Photos (kept in the app folder): " + result.failures.joined(separator: "; ")
            }
        } catch {
            lastError = "Could not add \(photo.filename) to Photos (kept in the app folder): \(CameraError.userMessage(for: error, baseURL: nil))"
        }
    }
}
