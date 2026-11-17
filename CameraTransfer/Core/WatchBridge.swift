import Foundation
import UIKit
import WatchConnectivity

/// The words the iPhone app and the Watch app exchange. The Watch target has its own copy of these.
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

/// Lets the Apple Watch app start live view, see the picture and fire the shutter through this iPhone.
/// The iPhone does the talking to the camera; the Watch is a remote for the iPhone app.
@MainActor
final class WatchBridge {
    static let shared = WatchBridge()

    /// Pictures per second sent to the Watch.
    private static let frameInterval: TimeInterval = 0.25
    /// Width of the picture sent to the Watch, in pixels.
    private static let frameWidth: CGFloat = 320

    private var proxy: WatchSessionProxy?
    private var lastFrameSent = Date.distantPast

    /// Call once at launch. Does nothing on a device that cannot pair with a Watch.
    func activate() {
        guard proxy == nil, WCSession.isSupported() else { return }
        let newProxy = WatchSessionProxy()
        proxy = newProxy
        WCSession.default.delegate = newProxy
        WCSession.default.activate()
    }

    private var reachableSession: WCSession? {
        guard proxy != nil else { return nil }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return nil }
        return session
    }

    /// What the Watch shows: which camera, what state, and the last shutter result.
    func statusPayload() -> [String: Any] {
        let control = RemoteControl.shared
        var payload: [String: Any] = [WatchWire.shooting: control.isShooting]
        if let camera = control.camera {
            payload[WatchWire.camera] = camera.rawValue
        }
        switch control.state {
        case .idle:
            payload[WatchWire.state] = WatchWire.idle
        case .starting:
            payload[WatchWire.state] = WatchWire.starting
        case .running:
            payload[WatchWire.state] = WatchWire.running
        case .failed(let message):
            payload[WatchWire.state] = WatchWire.failed
            payload[WatchWire.message] = message
        }
        if let shot = control.shotMessage {
            payload[WatchWire.shot] = shot
        }
        return payload
    }

    /// Tells the Watch about a change, if it is listening.
    func remoteStateChanged() {
        reachableSession?.sendMessage(statusPayload(), replyHandler: nil, errorHandler: nil)
    }

    /// Sends a small copy of the live picture to the Watch, a few times a second at most.
    func offerFrame(_ image: UIImage) {
        guard let session = reachableSession else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameSent) >= WatchBridge.frameInterval else { return }
        lastFrameSent = now
        guard let jpeg = WatchBridge.smallJPEG(from: image) else { return }
        session.sendMessageData(jpeg, replyHandler: nil, errorHandler: nil)
    }

    static func smallJPEG(from image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let width = min(frameWidth, image.size.width)
        let size = CGSize(width: width, height: (width * image.size.height / image.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: 0.5)
    }

    /// Carries out a command from the Watch and returns the status to show.
    func handle(command: String, camera: String?) -> [String: Any] {
        let control = RemoteControl.shared
        switch command {
        case WatchWire.start:
            if let camera, let model = CameraModel(rawValue: camera) {
                control.start(model)
            }
        case WatchWire.stop:
            control.stop()
        case WatchWire.shoot:
            control.shoot()
        default:
            break
        }
        return statusPayload()
    }
}

/// WatchConnectivity calls back on its own queue; this hops to the main actor.
final class WatchSessionProxy: NSObject, WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A different Watch was paired: get ready for it.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let command = message[WatchWire.command] as? String ?? WatchWire.status
        let camera = message[WatchWire.camera] as? String
        Task { @MainActor in
            replyHandler(WatchBridge.shared.handle(command: command, camera: camera))
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let command = message[WatchWire.command] as? String ?? WatchWire.status
        let camera = message[WatchWire.camera] as? String
        Task { @MainActor in
            _ = WatchBridge.shared.handle(command: command, camera: camera)
        }
    }
}
