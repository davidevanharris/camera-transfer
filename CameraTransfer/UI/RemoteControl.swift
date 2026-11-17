import SwiftUI
import UIKit
import Observation

/// Holds the newest frame until the main thread is ready for it, so a fast camera never builds up a backlog.
final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Data?
    private var scheduled = false

    /// Stores `frame`. Returns true if the caller should schedule a pickup (none is pending yet).
    func put(_ frame: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        latest = frame
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        let frame = latest
        latest = nil
        return frame
    }
}

/// The one live-view / remote-shutter session of the app. The Remote screen and the Apple Watch both drive it.
@MainActor
@Observable
final class RemoteControl {
    static let shared = RemoteControl()

    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)

        var isActive: Bool { self == .starting || self == .running }
    }

    private(set) var state: State = .idle
    private(set) var camera: CameraModel?
    private(set) var image: UIImage?
    private(set) var frameCount = 0
    private(set) var isShooting = false
    private(set) var shotMessage: String?
    private(set) var log: [String] = []

    @ObservationIgnored private var session: RemoteSession?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Increases with every start and stop, so late callbacks from an old session are ignored.
    @ObservationIgnored private var generation = 0

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        WatchBridge.shared.remoteStateChanged()
    }

    private func note(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("\(formatter.string(from: Date())) \(text)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    /// Seconds to wait for the first picture before giving up. Sony is long because of the pairing prompt.
    private func firstFrameTimeout(for camera: CameraModel) -> UInt64 {
        camera == .sony ? 20 : 10
    }

    func start(_ camera: CameraModel) {
        if state.isActive {
            if self.camera == camera { return }
            stop()
        }
        generation += 1
        let current = generation
        self.camera = camera
        frameCount = 0
        image = nil
        shotMessage = nil
        setState(.starting)

        let newSession: RemoteSession
        do {
            newSession = try RemoteSessionFactory.make(for: camera)
        } catch {
            setState(.failed(CameraError.userMessage(for: error, baseURL: nil)))
            return
        }
        session = newSession
        UIApplication.shared.isIdleTimerDisabled = true
        note("Starting live view for the \(camera.displayName)...")

        let box = LatestFrameBox()
        let onFrame: @Sendable (Data) -> Void = { [weak self] jpeg in
            guard box.put(jpeg) else { return }
            Task { @MainActor in
                guard let frame = box.take(), let self, self.generation == current else { return }
                self.show(frame)
            }
        }
        let onLog: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.note(line)
            }
        }
        Task {
            do {
                try await newSession.start(onFrame: onFrame, onLog: onLog)
                guard self.generation == current else { return }
                self.startWatchdog(camera: camera, generation: current)
            } catch {
                guard self.generation == current else { return }
                let message = CameraError.userMessage(for: error, baseURL: AppDefaults.baseURL(for: camera))
                self.note("Start failed: \(message)")
                self.teardown()
                self.setState(.failed(message))
            }
        }
    }

    private func show(_ jpeg: Data) {
        guard state.isActive, let picture = UIImage(data: jpeg) else { return }
        image = picture
        frameCount += 1
        if state != .running {
            note("First picture received (\(Int(picture.size.width)) x \(Int(picture.size.height))).")
            setState(.running)
            if let camera {
                UserDefaults.standard.set(true, forKey: RemoteControl.workedKey(camera))
            }
        }
        WatchBridge.shared.offerFrame(picture)
    }

    /// True once live view has shown a picture from this camera at least once (used to fold away the setup steps).
    static func workedKey(_ camera: CameraModel) -> String {
        "remoteWorked." + camera.rawValue
    }

    /// If the camera accepts the request but no picture arrives, say so instead of waiting forever.
    private func startWatchdog(camera: CameraModel, generation current: Int) {
        watchdog?.cancel()
        let seconds = firstFrameTimeout(for: camera)
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.generation == current else { return }
            if self.state == .starting {
                self.note("No picture after \(seconds) seconds.")
                self.teardown()
                self.setState(.failed("The camera accepted the request but sent no picture. Check the camera is in a shooting mode (not playback or a menu), and that iOS allows this app on the local network: Settings > Privacy & Security > Local Network."))
            }
        }
    }

    func shoot() {
        guard let session, state == .running, !isShooting else { return }
        isShooting = true
        shotMessage = nil
        let current = generation
        Task {
            do {
                let how = try await session.takePhoto()
                if self.generation == current {
                    self.note("Shutter fired (\(how)).")
                    self.shotMessage = "Shutter fired. Check the camera took the photo."
                }
            } catch {
                if self.generation == current {
                    let message = CameraError.userMessage(for: error, baseURL: nil)
                    self.note("Shutter failed: \(message)")
                    self.shotMessage = "The shutter did not fire: \(message)"
                }
            }
            self.isShooting = false
            WatchBridge.shared.remoteStateChanged()
        }
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        let finishing = session
        session = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if let finishing {
            Task { await finishing.stop() }
        }
    }

    func stop() {
        generation += 1
        teardown()
        image = nil
        isShooting = false
        if state.isActive {
            note("Live view stopped.")
        }
        setState(.idle)
    }
}
