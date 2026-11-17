import Foundation
import SwiftUI
import UIKit
import WatchConnectivity

/// The words the Watch app and the iPhone app exchange (the iPhone target has its own copy).
enum WatchWire {
    static let command = "cmd"
    static let camera = "camera"
    static let state = "state"
    static let message = "message"
    static let shooting = "shooting"
    static let shot = "shot"

    static let start = "start"
    static let stop = "stop"
    static let shoot = "shoot"
    static let status = "status"

    static let idle = "idle"
    static let starting = "starting"
    static let running = "running"
    static let failed = "failed"
}

struct WatchCamera: Identifiable, Hashable {
    let id: String
    let name: String

    static let all = [
        WatchCamera(id: "ricoh", name: "Ricoh GR IV"),
        WatchCamera(id: "sony", name: "Sony A7CR"),
        WatchCamera(id: "olympus", name: "OM System OM-3")
    ]
}

enum WatchRemoteState: Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

/// Sends commands to the iPhone app and receives the status and the live picture from it.
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var state: WatchRemoteState = .idle
    @Published var activeCamera: String?
    @Published var image: UIImage?
    @Published var isShooting = false
    @Published var shotMessage: String?
    @Published var phoneReachable = false
    /// Set when a command could not be delivered (iPhone app closed or out of range).
    @Published var linkProblem: String?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func send(_ command: String, camera: String? = nil) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            linkProblem = "Still connecting to the iPhone. Try again in a moment."
            return
        }
        var message: [String: Any] = [WatchWire.command: command]
        if let camera {
            message[WatchWire.camera] = camera
        }
        session.sendMessage(message, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                self?.linkProblem = nil
                self?.apply(reply)
            }
        }, errorHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.linkProblem = "Could not reach the iPhone. Open Camera Transfer on the iPhone and keep it on screen."
            }
        })
    }

    func start(_ camera: WatchCamera) {
        image = nil
        shotMessage = nil
        state = .starting
        activeCamera = camera.id
        send(WatchWire.start, camera: camera.id)
    }

    func stop() {
        send(WatchWire.stop)
        image = nil
        state = .idle
    }

    func shoot() {
        guard state == .running, !isShooting else { return }
        isShooting = true
        send(WatchWire.shoot)
        // If the iPhone's answer gets lost, do not leave the button disabled forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.isShooting = false
        }
    }

    func refresh() {
        send(WatchWire.status)
    }

    private func apply(_ payload: [String: Any]) {
        activeCamera = payload[WatchWire.camera] as? String ?? activeCamera
        isShooting = payload[WatchWire.shooting] as? Bool ?? false
        shotMessage = payload[WatchWire.shot] as? String
        switch payload[WatchWire.state] as? String {
        case WatchWire.starting:
            state = .starting
        case WatchWire.running:
            state = .running
        case WatchWire.failed:
            state = .failed(payload[WatchWire.message] as? String ?? "The iPhone could not start live view.")
            image = nil
        case WatchWire.idle:
            state = .idle
            image = nil
        default:
            break
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        DispatchQueue.main.async {
            self.phoneReachable = reachable
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async {
            self.phoneReachable = reachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.apply(message)
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let picture = UIImage(data: messageData) else { return }
        DispatchQueue.main.async {
            self.image = picture
            if self.state == .starting {
                self.state = .running
            }
        }
    }
}
