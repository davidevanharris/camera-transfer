import Foundation

/// One storage (memory) on the camera. Ricoh: "in" = internal memory, "sd1" = SD card.
struct CameraStorage: Equatable, Sendable {
    let name: String
    let equipped: Bool
    let numberOfPhotos: Int?
    let numberOfMovies: Int?

    var displayName: String {
        switch name {
        case "in": return "Internal memory"
        case "sd1": return "SD card"
        default: return name
        }
    }
}

/// What the camera says about itself. Every field except the model is optional.
struct CameraDeviceInfo: Equatable, Sendable {
    var model: String
    var firmware: String?
    var batteryPercent: Int?
    var storages: [CameraStorage]

    init(model: String, firmware: String? = nil, batteryPercent: Int? = nil, storages: [CameraStorage] = []) {
        self.model = model
        self.firmware = firmware
        self.batteryPercent = batteryPercent
        self.storages = storages
    }

    /// "RICOH GR IV - firmware 1.11 - battery 80%"
    var summary: String {
        var parts = [model]
        if let firmware { parts.append("firmware \(firmware)") }
        if let batteryPercent { parts.append("battery \(batteryPercent)%") }
        return parts.joined(separator: " - ")
    }
}

/// Common interface for cameras that serve their memory card over HTTP.
protocol CameraClient: Sendable {
    /// Checks the camera is reachable and returns a human-readable description (usually the model name).
    func ping() async throws -> String
    /// Retries a cheap request until the camera answers or `timeout` seconds pass (Wi-Fi may still be coming up).
    func waitUntilReachable(timeout: TimeInterval) async throws
    func deviceInfo() async throws -> CameraDeviceInfo
    func listPhotos() async throws -> [RemotePhoto]
    func thumbnailData(for photo: RemotePhoto) async throws -> Data
    func download(_ photo: RemotePhoto, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Best-effort "we are done" call (Ricoh: end the Wi-Fi session). Never throws.
    func finishSession() async
}

extension CameraClient {
    func deviceInfo() async throws -> CameraDeviceInfo {
        CameraDeviceInfo(model: try await ping())
    }

    func finishSession() async {}
}

enum CameraError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "The camera address \"\(value)\" is not a valid URL. Check it in Settings."
        case .httpStatus(let code, let path):
            return "The camera answered HTTP \(code) for \(path)."
        case .badResponse(let detail):
            return "Unexpected response from the camera: \(detail)"
        }
    }

    /// Turns any error into a sentence suitable for showing in the UI.
    static func userMessage(for error: Error, baseURL: URL?) -> String {
        if let urlError = error as? URLError {
            let host = baseURL?.host ?? "the camera"
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return "Could not reach \(host). Make sure the camera's Wi-Fi is switched on, this iPhone is joined to the camera's network in Settings > Wi-Fi, and Local Network access is allowed for this app (Settings > Privacy & Security > Local Network)."
            case .appTransportSecurityRequiresSecureConnection:
                return "iOS blocked the plain-HTTP connection to \(host). The address must be a local IP address or localhost."
            case .cancelled:
                return "Cancelled."
            default:
                return urlError.localizedDescription
            }
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

/// Small HTTP helper shared by the Ricoh and OM System clients.
final class CameraHTTP: @unchecked Sendable {
    let baseURL: URL
    let headers: [String: String]
    let configuration: URLSessionConfiguration
    let session: URLSession

    init(baseURL: URL, headers: [String: String] = [:], requestTimeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.headers = headers
        let configuration = CameraHTTP.makeConfiguration(headers: headers, requestTimeout: requestTimeout)
        self.configuration = configuration
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func makeConfiguration(headers: [String: String], requestTimeout: TimeInterval = 60) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = 60 * 60 * 4
        config.waitsForConnectivity = false
        // Never fall back to cellular: the camera is only reachable over its own Wi-Fi.
        config.allowsCellularAccess = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 2
        if !headers.isEmpty {
            config.httpAdditionalHeaders = headers
        }
        return config
    }

    /// Parses a user-entered base URL ("192.168.0.1", "http://192.168.0.1/", "localhost:8001").
    static func parseBaseURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard let url = URL(string: value), url.host != nil else { return nil }
        return url
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CameraError.invalidBaseURL(baseURL.absoluteString)
        }
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + suffix
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw CameraError.invalidBaseURL(baseURL.absoluteString)
        }
        return url
    }

    func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: makeRequest(url))
        guard let http = response as? HTTPURLResponse else {
            throw CameraError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CameraError.httpStatus(http.statusCode, url.path)
        }
        return data
    }

    /// Polls `path` with short timeouts and backoff until any HTTP answer arrives (even an error status),
    /// or `timeout` seconds have passed. Used right after joining the camera's Wi-Fi.
    func waitUntilReachable(path: String, timeout: TimeInterval) async throws {
        let probe = CameraHTTP(baseURL: baseURL, headers: headers, requestTimeout: 3)
        let url = try self.url(path: path)
        let deadline = Date().addingTimeInterval(timeout)
        var delay: TimeInterval = 0.5
        var lastError: Error = CameraError.badResponse("the camera did not answer")
        while true {
            try Task.checkCancellation()
            do {
                _ = try await probe.get(url)
                return
            } catch CameraError.httpStatus(_, _) {
                // Any HTTP answer means the camera's web server is up.
                return
            } catch {
                lastError = error
            }
            if Date().addingTimeInterval(delay) > deadline {
                throw lastError
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, 3)
        }
    }

    /// Downloads to a hidden ".part" file next to `destination`, then atomically renames it into place.
    func download(from url: URL,
                  to destination: URL,
                  expectedSize: Int64?,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let partURL = directory.appendingPathComponent("." + destination.lastPathComponent + ".part")

        let operation = FileDownloadOperation(request: makeRequest(url),
                                              partURL: partURL,
                                              expectedSize: expectedSize,
                                              progress: progress)
        do {
            try await operation.run(configuration: configuration)
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }

        // rename(2) atomically replaces any existing file at the destination.
        if rename(partURL.path, destination.path) != 0 {
            let message = String(cString: strerror(errno))
            try? fileManager.removeItem(at: partURL)
            throw CameraError.badResponse("could not save file (\(message))")
        }
        progress(1.0)
    }
}

/// Wraps a delegate-based URLSessionDownloadTask so that we get streaming progress,
/// a file on disk (not in memory), and cooperative cancellation.
final class FileDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let partURL: URL
    private let expectedSize: Int64?
    private let progress: @Sendable (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var isCancelled = false
    private var fileWasMoved = false
    private var failure: Error?

    init(request: URLRequest, partURL: URL, expectedSize: Int64?, progress: @escaping @Sendable (Double) -> Void) {
        self.request = request
        self.partURL = partURL
        self.expectedSize = expectedSize
        self.progress = progress
        super.init()
    }

    func run(configuration: URLSessionConfiguration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if self.isCancelled {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                // The session retains its delegate (self) until it is invalidated in didCompleteWithError.
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.downloadTask(with: self.request)
                self.task = task
                self.lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total: Int64
        if totalBytesExpectedToWrite > 0 {
            total = totalBytesExpectedToWrite
        } else {
            total = expectedSize ?? 0
        }
        guard total > 0 else { return }
        progress(min(1.0, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            setFailure(CameraError.httpStatus(http.statusCode, request.url?.path ?? ""))
            return
        }
        // The temporary file is deleted when this method returns, so move it now.
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: partURL.path) {
                try fileManager.removeItem(at: partURL)
            }
            try fileManager.moveItem(at: location, to: partURL)
            lock.lock()
            fileWasMoved = true
            lock.unlock()
        } catch {
            setFailure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let cancelled = isCancelled
        let moved = fileWasMoved
        let failure = self.failure
        lock.unlock()

        session.finishTasksAndInvalidate()

        guard let continuation else { return }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else if let failure {
            continuation.resume(throwing: failure)
        } else if !moved {
            continuation.resume(throwing: CameraError.badResponse("download finished without a file"))
        } else {
            continuation.resume()
        }
    }

    private func setFailure(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }
}
