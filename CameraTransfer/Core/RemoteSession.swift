import Foundation

/// A camera that can show a live picture and take a photo on command.
/// One session is one visit to the Remote screen: `start`, any number of `takePhoto`, then `stop`.
protocol RemoteSession: AnyObject, Sendable {
    /// Starts the live picture. `onFrame` receives complete JPEG images; `onLog` receives troubleshooting lines.
    /// Returns once the camera has accepted the request (the first frame may arrive a little later).
    func start(onFrame: @escaping @Sendable (Data) -> Void,
               onLog: @escaping @Sendable (String) -> Void) async throws
    /// Takes one photo. Returns a short note about how the shutter was fired, for the log.
    func takePhoto() async throws -> String
    /// Stops the live picture and hands the camera back. Never throws.
    func stop() async
}

enum RemoteSessionError: LocalizedError, Equatable {
    case invalidAddress
    case cameraNotFound(String)
    case notStarted
    case noShutter(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "The camera address in Settings is not valid."
        case .cameraNotFound(let detail):
            return detail
        case .notStarted:
            return "Live view is not running."
        case .noShutter(let detail):
            return detail
        }
    }
}

enum RemoteSessionFactory {
    @MainActor
    static func make(for camera: CameraModel) throws -> RemoteSession {
        switch camera {
        case .olympus:
            guard let baseURL = AppDefaults.baseURL(for: .olympus) else { throw RemoteSessionError.invalidAddress }
            return OlympusRemoteSession(baseURL: baseURL)
        case .ricoh:
            guard let baseURL = AppDefaults.baseURL(for: .ricoh) else { throw RemoteSessionError.invalidAddress }
            return RicohRemoteSession(baseURL: baseURL)
        case .sony:
            return SonyRemoteSession()
        }
    }
}

/// Cuts a continuous stream of JPEG images (Motion JPEG) into single images.
/// Each image runs from a start marker (FF D8) to the next end marker (FF D9).
struct MJPEGSplitter {
    private var buffer = [UInt8]()
    /// Where the current image starts in `buffer`, once its start marker has been seen.
    private var frameStart: Int?
    /// How far `buffer` has been searched already.
    private var scanned = 0
    static let maxFrameBytes = 4_000_000

    /// Feeds the next piece of the stream. Returns every image completed by it, oldest first.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        var index = max(scanned, 0)
        while index + 1 < buffer.count {
            if buffer[index] == 0xFF {
                let next = buffer[index + 1]
                if frameStart == nil, next == 0xD8 {
                    frameStart = index
                    index += 2
                    continue
                }
                if let start = frameStart, next == 0xD9 {
                    frames.append(Data(buffer[start..<(index + 2)]))
                    buffer.removeFirst(index + 2)
                    frameStart = nil
                    index = 0
                    continue
                }
            }
            index += 1
        }
        scanned = index
        if let start = frameStart {
            if buffer.count - start > MJPEGSplitter.maxFrameBytes {
                // Not a sane image: start over.
                buffer.removeAll(keepingCapacity: true)
                frameStart = nil
                scanned = 0
            } else if start > 0 {
                // Drop the bytes before the image (multipart headers).
                buffer.removeFirst(start)
                frameStart = 0
                scanned -= start
            }
        } else if buffer.count > 1 {
            // Nothing in progress: keep only the last byte, which may be the first half of a marker.
            buffer.removeFirst(buffer.count - 1)
            scanned = 0
        }
        return frames
    }
}
