import SwiftUI
import UIKit
import Observation

struct FTPLogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let text: String
    let isFile: Bool
}

@MainActor
@Observable
final class FTPServerController {
    var isRunning = false
    var errorMessage: String?
    var addresses: [LocalAddress] = []
    var port = AppDefaults.ftpPort
    var username = AppDefaults.ftpUsername
    var password = ""
    var log: [FTPLogEntry] = []
    var receivedCount = 0
    var receivedBytes: Int64 = 0
    var connectedClients = 0
    /// Set whenever a file arrives so other views (Library) can refresh.
    var lastReceivedAt: Date?
    /// What the user asked for with the toggle. The listener itself may be paused by the auto-transfer policy.
    var wantsRunning = false
    /// Why the policy stopped the listener (nil when not paused).
    var pausedReason: String?
    var photosAdded = 0

    @ObservationIgnored private var server: FTPServer?
    @ObservationIgnored private var policyTask: Task<Void, Never>?

    init() {
        refreshInfo()
    }

    /// Re-checks the phone-side policy: stops the listener when it denies, restarts it when it allows again.
    func evaluatePolicy() {
        guard wantsRunning else { return }
        let mode = AutoTransferSettings.mode()
        if mode == .manual {
            if pausedReason != nil {
                pausedReason = nil
                startServer()
            }
            return
        }
        let decision = PhoneBatteryMonitor.shared.decision(for: .notApplicable, mode: mode)
        if !decision.allowed {
            if isRunning {
                stopServer()
                append("Server paused. \(decision.reason)", isFile: false)
            }
            pausedReason = decision.reason
        } else if pausedReason != nil || !isRunning {
            if pausedReason != nil {
                append("Battery OK again; restarting the server.", isFile: false)
            }
            pausedReason = nil
            if !isRunning { startServer() }
        }
    }

    private func startPolicyLoop() {
        policyTask?.cancel()
        policyTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
                self?.evaluatePolicy()
            }
        }
    }

    func refreshInfo() {
        addresses = NetworkInterfaces.ipv4Addresses()
        if !isRunning {
            port = AppDefaults.ftpPortValue()
            username = AppDefaults.ftpUsernameValue()
            password = AppDefaults.ftpPasswordValue()
        }
    }

    func setRunning(_ shouldRun: Bool) {
        if shouldRun { start() } else { stop() }
    }

    func start() {
        wantsRunning = true
        pausedReason = nil
        startPolicyLoop()
        let decision = PhoneBatteryMonitor.shared.decision(for: .notApplicable)
        if AutoTransferSettings.mode() != .manual && !decision.allowed {
            pausedReason = decision.reason
            append("Server paused. \(decision.reason)", isFile: false)
            return
        }
        startServer()
    }

    func stop() {
        wantsRunning = false
        pausedReason = nil
        policyTask?.cancel()
        policyTask = nil
        stopServer()
    }

    private func startServer() {
        guard server == nil else { return }
        errorMessage = nil
        refreshInfo()
        guard (1024...65535).contains(port), let portValue = UInt16(exactly: port) else {
            errorMessage = FTPServerError.invalidPort(port).errorDescription
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Set an FTP password in Settings first."
            return
        }
        let root = LibraryStore.shared.folder(for: .sony)
        let newServer = FTPServer(port: portValue, root: root, username: username, password: password) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        do {
            try newServer.start()
            server = newServer
            isRunning = true
            connectedClients = 0
            UIApplication.shared.isIdleTimerDisabled = true
            append("Server starting on port \(port)...", isFile: false)
        } catch {
            errorMessage = "Could not start the FTP server: \(error.localizedDescription)"
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        isRunning = false
        connectedClients = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clearLog() {
        log = []
    }

    private func handle(_ event: FTPEvent) {
        switch event {
        case .started(let port):
            append("Listening on port \(port).", isFile: false)
            addresses = NetworkInterfaces.ipv4Addresses()
        case .stopped:
            append("Server stopped.", isFile: false)
        case .failed(let message):
            errorMessage = message
            append(message, isFile: false)
            server = nil
            isRunning = false
            wantsRunning = false
            policyTask?.cancel()
            policyTask = nil
            connectedClients = 0
            UIApplication.shared.isIdleTimerDisabled = false
        case .clientConnected(let host):
            connectedClients += 1
            append("Camera connected from \(host).", isFile: false)
        case .clientDisconnected(let host):
            connectedClients = max(0, connectedClients - 1)
            append("Disconnected: \(host).", isFile: false)
        case .loggedIn(let host):
            append("Logged in: \(host).", isFile: false)
        case .fileReceived(let name, let size, let url):
            receivedCount += 1
            receivedBytes += size
            lastReceivedAt = Date()
            append("Received \(name) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))", isFile: true)
            if AutoTransferSettings.mode() != .manual && FileKind.classify(filename: name) == .jpeg {
                addToPhotos(url)
            }
        case .transferFailed(let message):
            append(message, isFile: false)
        case .log(let message):
            // Keep raw protocol chatter out of the visible log except failures; it is noisy.
            if message.contains("Rejected") || message.contains("failed") {
                append(message, isFile: false)
            }
        }
    }

    /// Auto mode: add a received JPEG to Photos (add-only); delete the local copy unless "keep a copy" is on.
    private func addToPhotos(_ url: URL) {
        Task {
            do {
                let result = try await PhotoExporter.export([url])
                if result.added > 0 && result.failures.isEmpty {
                    self.photosAdded += 1
                    if !AutoTransferSettings.keepCopy() {
                        try? LibraryStore.shared.deleteFile(at: url)
                        self.lastReceivedAt = Date()
                    }
                    self.append("Added \(url.lastPathComponent) to Photos.", isFile: true)
                } else {
                    self.append("Could not add \(url.lastPathComponent) to Photos (kept in the app folder): " + result.failures.joined(separator: "; "), isFile: false)
                }
            } catch {
                self.append("Could not add \(url.lastPathComponent) to Photos (kept in the app folder): \(CameraError.userMessage(for: error, baseURL: nil))", isFile: false)
            }
        }
    }

    private func append(_ text: String, isFile: Bool) {
        log.insert(FTPLogEntry(date: Date(), text: text, isFile: isFile), at: 0)
        if log.count > 300 {
            log.removeLast(log.count - 300)
        }
    }
}

struct SonyFTPView: View {
    @Bindable var controller: FTPServerController
    @AppStorage(AutoTransferSettings.modeKey) private var mode: AutoTransferMode = .manual

    var body: some View {
        List {
            Section {
                AutoTransferModePicker(cameraBattery: .notApplicable)
                if mode != .manual {
                    Text("Auto mode: each JPEG the camera sends is added to Photos (add-only). The camera's battery cannot be read over FTP, so only the phone's battery is checked. Photos added: \(controller.photosAdded).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { controller.wantsRunning },
                                     set: { controller.setRunning($0) })) {
                    Label("FTP server", systemImage: controller.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                }
                if let paused = controller.pausedReason {
                    Label(paused + " The server restarts automatically when the battery allows.", systemImage: "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let error = controller.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if controller.isRunning {
                    LabeledContent("Cameras connected", value: "\(controller.connectedClients)")
                    LabeledContent("Files received",
                                   value: "\(controller.receivedCount) (\(ByteCountFormatter.string(fromByteCount: controller.receivedBytes, countStyle: .file)))")
                }
            } footer: {
                Text("Keep this app open in the foreground while the camera transfers. The screen will not auto-lock while the server runs.")
            }

            Section {
                if controller.addresses.isEmpty {
                    Text("No usable network. Join a Wi-Fi network or turn on Personal Hotspot.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.addresses) { address in
                        LabeledContent("Address (\(address.friendlyName))") {
                            Text(address.address)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                LabeledContent("Port") {
                    Text(String(controller.port)).font(.body.monospaced())
                }
                LabeledContent("User name") {
                    Text(controller.username).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Password") {
                    Text(controller.password).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Passive mode", value: "On")
                LabeledContent("Secure protocol", value: "Off")
                Button("Refresh addresses") { controller.refreshInfo() }
            } header: {
                Text("Enter these on the camera")
            } footer: {
                Text("Port, user name and password can be changed in Settings (stop the server first).")
            }

            Section("Camera setup (A7CR)") {
                ForEach(Array(SonyFTPView.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").bold().monospacedDigit()
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }
            }

            Section {
                if controller.log.isEmpty {
                    Text("Nothing received yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(controller.log) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: entry.isFile ? "checkmark.circle.fill" : "info.circle")
                                .foregroundStyle(entry.isFile ? Color.green : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(entry.text).font(.subheadline)
                                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    if !controller.log.isEmpty {
                        Button("Clear") { controller.clearLog() }
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Sony A7CR")
        .onAppear {
            controller.refreshInfo()
            controller.evaluatePolicy()
        }
        .onChange(of: mode) { _, _ in
            controller.evaluatePolicy()
        }
    }

    static let steps: [String] = [
        "Put the iPhone and camera on the same network: turn on Personal Hotspot on this iPhone and join it from the camera (MENU > Network > Wi-Fi > Access Point Set.), or join both to the same Wi-Fi router.",
        "Turn the FTP server on above. Allow Local Network access if iOS asks.",
        "On the camera: MENU > Network > Transfer/Remote > FTP Transfer Func. > Server Setting (names vary slightly by firmware). Choose a server slot and enter: Host name = an address shown above (use the Personal Hotspot address, usually 172.20.10.1, if the camera is on your hotspot), Port = the port above, User and Password as shown above.",
        "In the same Server Setting: Passive Mode = On, Secure Protocol = Off. Directory can stay empty.",
        "Back in FTP Transfer Func.: turn FTP Function on, select the server slot, then use FTP Transfer to send images (choose target and file type: JPEG, RAW or RAW+JPEG). Auto FTP Transfer can send each shot as you take it.",
        "Received files appear in the Library tab and in Files > On My iPhone > Camera Transfer > Sony A7CR.",
        "For hands-off auto-transfer: turn on the camera's Auto FTP Transfer and set the transfer target / file type to JPEG only, then pick an auto mode above."
    ]
}
