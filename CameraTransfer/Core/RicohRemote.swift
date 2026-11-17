import Foundation

/// Reads the Ricoh GR's live picture: `GET /v1/liveview` answers with an endless stream of JPEG images.
/// Reported working on the GR IV by a community project; not yet confirmed with this app.
final class MJPEGStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let onFrame: @Sendable (Data) -> Void
    private let onEnd: @Sendable (Error?) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var splitter = MJPEGSplitter()
    private let gate = ResumeGate()
    private var started: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(request: URLRequest,
         onFrame: @escaping @Sendable (Data) -> Void,
         onEnd: @escaping @Sendable (Error?) -> Void) {
        self.request = request
        self.onFrame = onFrame
        self.onEnd = onEnd
        super.init()
    }

    /// Opens the stream. Returns when the camera has answered with HTTP 200, or throws.
    func open() async throws {
        let configuration = CameraHTTP.makeConfiguration(headers: [:], requestTimeout: 15)
        // A live stream has no natural end.
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let newTask = newSession.dataTask(with: request)
        lock.lock()
        session = newSession
        task = newTask
        lock.unlock()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            started = continuation
            lock.unlock()
            newTask.resume()
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = started
        started = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func close() {
        lock.lock()
        let oldTask = task
        let oldSession = session
        task = nil
        session = nil
        lock.unlock()
        oldTask?.cancel()
        oldSession?.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finishStart(.failure(CameraError.httpStatus(http.statusCode, request.url?.path ?? "/v1/liveview")))
            completionHandler(.cancel)
            return
        }
        finishStart(.success(()))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for frame in splitter.append(data) {
            onFrame(frame)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finishStart(.failure(error ?? CameraError.badResponse("the live view ended before it started")))
        session.finishTasksAndInvalidate()
        if gate.claim() {
            onEnd(error)
        }
    }
}

/// Live view and shutter for the Ricoh GR IV.
/// The picture comes over the camera's Wi-Fi; the shutter is fired over Bluetooth, with HTTP as a fallback.
final class RicohRemoteSession: RemoteSession, @unchecked Sendable {
    private let http: CameraHTTP
    private let lock = NSLock()
    private var stream: MJPEGStream?
    private var stopped = false

    init(baseURL: URL) {
        self.http = CameraHTTP(baseURL: baseURL, requestTimeout: 10)
    }

    func start(onFrame: @escaping @Sendable (Data) -> Void,
               onLog: @escaping @Sendable (String) -> Void) async throws {
        let url = try http.url(path: "/v1/liveview")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        let newStream = MJPEGStream(request: request, onFrame: onFrame) { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            let wasStopped = self.stopped
            self.lock.unlock()
            if !wasStopped {
                let detail = error.map { CameraError.userMessage(for: $0, baseURL: url) } ?? "the camera closed it"
                onLog("Live view ended: \(detail)")
            }
        }
        lock.lock()
        stream = newStream
        stopped = false
        lock.unlock()
        onLog("Asking the camera at \(url.host ?? "?") for /v1/liveview...")
        try await newStream.open()
        onLog("The camera accepted the live-view request.")
    }

    func takePhoto() async throws -> String {
        // Bluetooth first: it does not disturb the picture stream.
        do {
            try await RicohBLE.shared.releaseShutter(autofocus: true)
            return "Bluetooth shutter"
        } catch {
            let bluetoothProblem = CameraError.userMessage(for: error, baseURL: nil)
            do {
                try await shootOverHTTP()
                return "Wi-Fi shutter (Bluetooth was not available: \(bluetoothProblem))"
            } catch {
                throw RemoteSessionError.noShutter(
                    "Bluetooth: \(bluetoothProblem) Wi-Fi: \(CameraError.userMessage(for: error, baseURL: http.baseURL))")
            }
        }
    }

    /// `POST /v1/camera/shoot` with a form body (the camera reads the body, not the query).
    private func shootOverHTTP() async throws {
        let url = try http.url(path: "/v1/camera/shoot")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("af=on&pos=50,50".utf8)
        let (_, response) = try await http.session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw CameraError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(status) else {
            throw CameraError.httpStatus(status, url.path)
        }
    }

    func stop() async {
        lock.lock()
        stopped = true
        let oldStream = stream
        stream = nil
        lock.unlock()
        oldStream?.close()
    }
}

/// Live view and shutter for the OM System OM-3 (see OlympusRemote for the commands).
final class OlympusRemoteSession: RemoteSession, @unchecked Sendable {
    private let baseURL: URL
    private let remote: OlympusRemote
    private let lock = NSLock()
    private var receiver: LiveViewReceiver?

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.remote = OlympusRemote(baseURL: baseURL)
    }

    func start(onFrame: @escaping @Sendable (Data) -> Void,
               onLog: @escaping @Sendable (String) -> Void) async throws {
        let newReceiver = LiveViewReceiver(onFrame: onFrame)
        try newReceiver.start(port: OlympusRemote.liveViewPort)
        lock.lock()
        receiver = newReceiver
        lock.unlock()
        onLog("Asking the camera at \(baseURL.host ?? "?") to start live view...")
        do {
            try await remote.startLiveView()
            onLog("The camera accepted the live-view request.")
        } catch {
            if let commands = await remote.commandList() {
                onLog("Commands this camera supports: \(commands.prefix(1500))")
            }
            await stop()
            throw error
        }
    }

    func takePhoto() async throws -> String {
        "command " + (try await remote.takePhoto())
    }

    func stop() async {
        lock.lock()
        let oldReceiver = receiver
        receiver = nil
        lock.unlock()
        guard let oldReceiver else { return }
        oldReceiver.stop()
        await remote.stopLiveView()
        await remote.returnToPlayback()
    }
}
