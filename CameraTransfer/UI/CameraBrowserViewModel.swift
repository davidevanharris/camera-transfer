import SwiftUI
import UIKit
import Observation

enum RicohConnectError: LocalizedError {
    case manualJoinRequired(ssid: String, passphrase: String?, reason: String)

    var errorDescription: String? {
        switch self {
        case .manualJoinRequired(let ssid, _, let reason):
            return "Join the camera's Wi-Fi \"\(ssid)\" manually in Settings > Wi-Fi. \(reason)"
        }
    }
}

@MainActor
@Observable
final class CameraBrowserViewModel: AutoTransferHost {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected(String)
        /// Ricoh: Wi-Fi was woken over Bluetooth but iOS could not join automatically.
        case needsManualJoin(ssid: String, passphrase: String?, reason: String)
        case failed(String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case jpeg = "JPEG"
        case raw = "RAW"
        case video = "Video"
        case newOnly = "New only"

        var id: String { rawValue }
    }

    let camera: CameraModel

    var connection: ConnectionState = .idle
    /// The step currently running while connecting (shown under the Connect button).
    var stage: String?
    var cameraInfo: CameraDeviceInfo?
    var photos: [RemotePhoto] = []
    var filter: Filter = .all
    var isSelecting = false
    var selection: Set<String> = []
    var downloadedIDs: Set<String> = []
    var log: [String] = []

    var isDownloading = false
    var currentFileName: String?
    var currentFileProgress: Double = 0
    var completedCount = 0
    var totalCount = 0
    var downloadErrors: [String] = []
    var statusMessage: String?

    let thumbnails = RemoteThumbnailLoader()
    let autoTransfer: AutoTransferCoordinator
    @ObservationIgnored private var client: CameraClient?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var powerTask: Task<Void, Never>?
    private let store: LibraryStore

    init(camera: CameraModel, store: LibraryStore = .shared) {
        self.camera = camera
        self.store = store
        self.autoTransfer = AutoTransferCoordinator(camera: camera, store: store)
        self.downloadedIDs = store.downloadedIDs(for: camera)
        self.autoTransfer.host = self
        if camera == .ricoh {
            listenForRicohPowerOn()
        }
    }

    // MARK: Derived state

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var isBusy: Bool {
        connection == .connecting || isDownloading || autoTransfer.isRunning
    }

    var filteredPhotos: [RemotePhoto] {
        switch filter {
        case .all: return photos
        case .jpeg: return photos.filter { $0.kind == .jpeg }
        case .raw: return photos.filter { $0.kind == .raw }
        case .video: return photos.filter { $0.kind == .video }
        case .newOnly: return photos.filter { !downloadedIDs.contains($0.id) }
        }
    }

    var newPhotos: [RemotePhoto] {
        photos.filter { !downloadedIDs.contains($0.id) }
    }

    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        let value = (Double(completedCount) + min(1, max(0, currentFileProgress))) / Double(totalCount)
        return min(1, value)
    }

    var cameraBatteryReading: CameraBatteryReading {
        autoTransferCameraBattery(info: cameraInfo)
    }

    // MARK: Logging

    func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("\(formatter.string(from: Date())) \(text)")
        if log.count > 300 {
            log.removeFirst(log.count - 300)
        }
    }

    private func setStage(_ text: String?) {
        stage = text
        if let text { appendLog(text) }
    }

    // MARK: Connection

    /// Ricoh: Bluetooth wake -> join -> ping -> list. OM-3: ping -> list (Wi-Fi joined manually).
    func connect() {
        guard !isBusy else { return }
        startConnect(useBluetooth: camera == .ricoh)
    }

    /// Skips Bluetooth (the phone is already on the camera's Wi-Fi, or testing with the mock server).
    func connectWithoutBluetooth() {
        guard !isBusy || connection == .connecting else { return }
        startConnect(useBluetooth: false)
    }

    private func startConnect(useBluetooth: Bool) {
        connectTask?.cancel()
        guard let baseURL = AppDefaults.baseURL(for: camera) else {
            connection = .failed("The camera address in Settings is not a valid URL.")
            return
        }
        connection = .connecting
        selection = []
        downloadedIDs = store.downloadedIDs(for: camera)
        connectTask = Task {
            do {
                let newClient: CameraClient
                if useBluetooth {
                    newClient = try await self.prepareRicohOverBluetooth(baseURL: baseURL)
                } else {
                    newClient = try await self.prepareDirect(baseURL: baseURL)
                }
                try await self.load(newClient)
            } catch RicohConnectError.manualJoinRequired(let ssid, let passphrase, let reason) {
                if Task.isCancelled { return }
                self.setStage(nil)
                self.connection = .needsManualJoin(ssid: ssid, passphrase: passphrase, reason: reason)
            } catch {
                if Task.isCancelled { return }
                let message = CameraError.userMessage(for: error, baseURL: baseURL)
                self.appendLog("Failed: \(message)")
                self.setStage(nil)
                self.photos = []
                self.connection = .failed(message)
            }
        }
    }

    private func makeClient(baseURL: URL) -> CameraClient {
        switch camera {
        case .olympus:
            return OlympusClient(baseURL: baseURL)
        case .ricoh, .sony:
            return RicohClient(baseURL: baseURL)
        }
    }

    private func prepareDirect(baseURL: URL) async throws -> CameraClient {
        let newClient = makeClient(baseURL: baseURL)
        setStage("Waiting for the camera at \(baseURL.host ?? baseURL.absoluteString)...")
        try await newClient.waitUntilReachable(timeout: 20)
        return newClient
    }

    private func prepareRicohOverBluetooth(baseURL: URL) async throws -> CameraClient {
        setStage("Waking the camera's Wi-Fi over Bluetooth...")
        let credentials = try await RicohBLE.shared.wakeWiFi()
        guard let passphrase = credentials.passphrase else {
            throw RicohConnectError.manualJoinRequired(
                ssid: credentials.ssid, passphrase: nil,
                reason: "The Wi-Fi password could not be read over Bluetooth (it may be encrypted). Use the password shown in the camera's Wi-Fi information screen.")
        }
        setStage("Joining \"\(credentials.ssid)\"...")
        let result = await HotspotJoiner.join(ssid: credentials.ssid, passphrase: passphrase)
        if case .failed(let reason) = result {
            appendLog("Automatic join failed: \(reason)")
            throw RicohConnectError.manualJoinRequired(ssid: credentials.ssid, passphrase: passphrase, reason: reason)
        }
        let newClient = makeClient(baseURL: baseURL)
        setStage("Waiting for the camera to answer...")
        try await newClient.waitUntilReachable(timeout: 20)
        return newClient
    }

    private func load(_ newClient: CameraClient) async throws {
        setStage("Reading the camera's details...")
        let info = try await newClient.deviceInfo()
        setStage("Listing files...")
        let list = try await newClient.listPhotos()
        if Task.isCancelled { return }
        client = newClient
        thumbnails.reset(client: newClient)
        cameraInfo = info
        photos = CameraBrowserViewModel.sortedNewestFirst(list)
        if AutoTransferSettings.mode() != .manual && store.baselineIDs(for: camera) == nil {
            store.setBaseline(Set(list.map(\.id)), for: camera)
        }
        setStage(nil)
        connection = .connected(info.summary)
        appendLog("Connected: \(info.summary), \(list.count) files")
    }

    func disconnect() {
        connectTask?.cancel()
        cancelDownloads()
        let finishing = client
        client = nil
        thumbnails.reset(client: nil)
        photos = []
        selection = []
        isSelecting = false
        cameraInfo = nil
        connection = .idle
        let isRicoh = camera == .ricoh
        Task {
            if let finishing { await finishing.finishSession() }
            if isRicoh { await RicohBLE.shared.stopWiFi() }
        }
    }

    static func sortedNewestFirst(_ list: [RemotePhoto]) -> [RemotePhoto] {
        list.sorted { lhs, rhs in
            if let l = lhs.date, let r = rhs.date, l != r { return l > r }
            return lhs.id > rhs.id
        }
    }

    // MARK: Auto-transfer

    /// Called when the app becomes active or the auto mode changes.
    func appBecameActive() {
        guard AutoTransferSettings.mode() != .manual, !isDownloading, connection != .connecting else { return }
        if camera == .ricoh && RicohBLE.shared.rememberedID == nil { return }
        autoTransfer.start(trigger: "app opened")
    }

    func startAutoTransfer() {
        guard !isDownloading, connection != .connecting else { return }
        autoTransfer.start(trigger: "manual start")
    }

    private func listenForRicohPowerOn() {
        let stream = RicohBLE.shared.powerStateStream
        powerTask = Task { [weak self] in
            for await poweredOn in stream {
                guard let self else { break }
                if poweredOn && UIApplication.shared.applicationState == .active {
                    self.appendLog("Camera switched on (Bluetooth notification)")
                    if AutoTransferSettings.mode() != .manual && !self.isDownloading && self.connection != .connecting {
                        self.autoTransfer.start(trigger: "camera switched on")
                    }
                }
            }
        }
    }

    func autoTransferPrepareClient() async throws -> CameraClient {
        guard let baseURL = AppDefaults.baseURL(for: camera) else {
            throw CameraError.invalidBaseURL("Settings")
        }
        if camera == .ricoh && RicohBLE.shared.rememberedID != nil {
            return try await prepareRicohOverBluetooth(baseURL: baseURL)
        }
        return try await prepareDirect(baseURL: baseURL)
    }

    func autoTransferCameraBattery(info: CameraDeviceInfo?) -> CameraBatteryReading {
        if let percent = info?.batteryPercent ?? cameraInfo?.batteryPercent {
            return .percent(percent)
        }
        if camera == .ricoh, let percent = RicohBLE.shared.batteryPercent {
            return .percent(percent)
        }
        return .unknown
    }

    func autoTransferFinish(client finishing: CameraClient) async {
        setStage(nil)
        // Keep a manually opened session alive; otherwise end the camera's Wi-Fi.
        if !isConnected {
            await finishing.finishSession()
            if camera == .ricoh { await RicohBLE.shared.stopWiFi() }
        }
    }

    func autoTransferDidSave(_ photo: RemotePhoto) {
        downloadedIDs.insert(photo.id)
    }

    // MARK: Selection

    func toggleSelection(_ photo: RemotePhoto) {
        if selection.contains(photo.id) {
            selection.remove(photo.id)
        } else {
            selection.insert(photo.id)
        }
    }

    func selectAllVisible() {
        selection = Set(filteredPhotos.map(\.id))
    }

    // MARK: Downloads

    func downloadSelected() {
        let chosen = photos.filter { selection.contains($0.id) }
        startDownloads(chosen)
    }

    func downloadAllNew() {
        startDownloads(newPhotos)
    }

    func cancelDownloads() {
        downloadTask?.cancel()
    }

    private func startDownloads(_ items: [RemotePhoto]) {
        guard !isDownloading, !autoTransfer.isRunning, let client, !items.isEmpty else { return }
        isDownloading = true
        totalCount = items.count
        completedCount = 0
        currentFileProgress = 0
        currentFileName = nil
        downloadErrors = []
        statusMessage = nil
        thumbnails.isPaused = true

        let camera = self.camera
        let store = self.store
        let exportAfterDownload = UserDefaults.standard.bool(forKey: SettingsKey.exportAfterDownload)

        downloadTask = Task {
            var saved: [URL] = []
            var wasCancelled = false
            for photo in items {
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }
                self.currentFileName = photo.filename
                self.currentFileProgress = 0
                let destination = store.destination(for: photo, camera: camera)
                do {
                    try await client.download(photo, to: destination, progress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.currentFileProgress = fraction
                        }
                    })
                    store.markDownloaded(photo.id, camera: camera)
                    self.downloadedIDs.insert(photo.id)
                    self.selection.remove(photo.id)
                    saved.append(destination)
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        wasCancelled = true
                        break
                    }
                    self.downloadErrors.append("\(photo.filename): \(CameraError.userMessage(for: error, baseURL: nil))")
                }
                self.completedCount += 1
                self.currentFileProgress = 0
            }

            var message = wasCancelled
                ? "Cancelled after \(saved.count) of \(items.count) files."
                : "Saved \(saved.count) of \(items.count) files to \(camera.folderName) in the Files app."

            if exportAfterDownload && !saved.isEmpty {
                do {
                    let result = try await PhotoExporter.export(saved)
                    message += " Added \(result.added) to Photos."
                    self.downloadErrors.append(contentsOf: result.failures)
                } catch {
                    message += " " + CameraError.userMessage(for: error, baseURL: nil)
                }
            }

            self.statusMessage = message
            self.isDownloading = false
            self.currentFileName = nil
            self.thumbnails.isPaused = false
            if self.selection.isEmpty {
                self.isSelecting = false
            }
        }
    }
}
