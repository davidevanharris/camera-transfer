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

    // Setup progress, shown as a checklist so it is obvious which step a failed setup stopped at.
    var sawConnection = false
    var sawLogin = false
    var loginRejected = false
    /// The camera asked for encryption (its Secure Protocol setting is on), which this server does not offer.
    var sawSecureAttempt = false
    var lastFileName: String?
    var selfTest: FTPSelfTestState = .idle
    /// Every command the camera sent (passwords masked), newest last. For troubleshooting.
    var protocolLog: [String] = []

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
            if isOwnAddress(host) {
                return
            }
            sawConnection = true
            append("Camera connected from \(host).", isFile: false)
        case .clientDisconnected(let host):
            connectedClients = max(0, connectedClients - 1)
            append("Disconnected: \(host).", isFile: false)
        case .loggedIn(let host):
            if isOwnAddress(host) {
                return
            }
            sawLogin = true
            loginRejected = false
            // Remember where the camera is, so remote control can find it without searching.
            SonyRemoteSettings.rememberSeenHost(host)
            append("Camera logged in (\(host)).", isFile: false)
        case .fileReceived(let name, let size, let url):
            receivedCount += 1
            receivedBytes += size
            lastReceivedAt = Date()
            lastFileName = name
            append("Received \(name) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))", isFile: true)
            if AutoTransferSettings.mode() != .manual && FileKind.classify(filename: name) == .jpeg {
                addToPhotos(url)
            }
        case .transferFailed(let message):
            append(message, isFile: false)
        case .log(let message):
            recordProtocol(message)
            if message.hasSuffix("login rejected") {
                if !isOwnAddress(message) {
                    loginRejected = true
                    append("The camera's user name or password was wrong.", isFile: false)
                }
            } else if message.contains(": AUTH") {
                sawSecureAttempt = true
            } else if message.contains("Rejected") || message.contains("failed") {
                // Keep raw protocol chatter out of the visible log except failures; it is noisy.
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

    /// True when `text` starts with one of this phone's own addresses (the built-in self-test connects to itself).
    private func isOwnAddress(_ text: String) -> Bool {
        if text.hasPrefix("127.0.0.1") || text.hasPrefix("::1") { return true }
        return addresses.contains { text.hasPrefix($0.address) }
    }

    private func recordProtocol(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        protocolLog.append("\(formatter.string(from: Date())) \(message)")
        if protocolLog.count > 300 {
            protocolLog.removeFirst(protocolLog.count - 300)
        }
    }

    /// Forgets the setup progress so the checklist starts again.
    func resetProgress() {
        sawConnection = false
        sawLogin = false
        loginRejected = false
        sawSecureAttempt = false
        selfTest = .idle
    }

    /// Connects to this phone's own FTP server and logs in, to prove the server and its password work.
    func runSelfTest() {
        guard isRunning, selfTest != .running else { return }
        refreshInfo()
        guard let portValue = UInt16(exactly: port) else { return }
        let host = addresses.first?.address ?? "127.0.0.1"
        let user = username
        let pass = password
        selfTest = .running
        Task {
            let result = await FTPSelfTest.run(host: host, port: portValue, username: user, password: pass)
            self.selfTest = result
        }
    }

    /// The address the camera should use for the chosen way of connecting, if the phone has one right now.
    func address(for link: SonyLink) -> String? {
        switch link {
        case .hotspot:
            return addresses.first { $0.interface.hasPrefix("bridge") }?.address
        case .wifi:
            return addresses.first { $0.interface == "en0" }?.address
        }
    }

    private func append(_ text: String, isFile: Bool) {
        log.insert(FTPLogEntry(date: Date(), text: text, isFile: isFile), at: 0)
        if log.count > 300 {
            log.removeLast(log.count - 300)
        }
    }
}

/// Guided setup for the Sony A7CR. The camera pushes photos to an FTP server inside this app, so the screen
/// walks through the camera's menus one step at a time and shows how far the camera has got.
struct SonyFTPView: View {
    @Bindable var controller: FTPServerController
    @AppStorage(AutoTransferSettings.modeKey) private var mode: AutoTransferMode = .manual
    @AppStorage("sonyLink") private var link: SonyLink = .hotspot
    @AppStorage("sonySetupDone") private var setupDone = false
    @State private var showSteps = true
    @State private var copiedValue: String?

    var body: some View {
        List {
            statusSection
            if showSteps || !setupDone {
                networkSection
                cameraSettingsSection
                sendSection
            } else {
                Section {
                    Button("Show the setup steps again") { showSteps = true }
                }
            }
            progressSection
            troubleshootingSection
            detailsSection
        }
        .navigationTitle("Sony A7CR")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            controller.refreshInfo()
            controller.evaluatePolicy()
            showSteps = !setupDone
        }
        .onChange(of: mode) { _, _ in
            controller.evaluatePolicy()
        }
        .onChange(of: controller.receivedCount) { _, count in
            if count > 0 { setupDone = true }
        }
        .task {
            // The hotspot address only appears once a device has joined, so keep looking while the screen is open.
            while !Task.isCancelled {
                controller.refreshInfo()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.title)
                        .foregroundStyle(statusColor)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.headline)
                        Text(statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    controller.setRunning(!controller.wantsRunning)
                } label: {
                    Text(controller.wantsRunning ? "Stop receiving" : "Start receiving")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.wantsRunning ? Color.gray : Color.accentColor)
                .controlSize(.large)
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let paused = controller.pausedReason {
                    Label(paused + " Receiving restarts when the battery allows.", systemImage: "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Keep this app open while the camera sends. The screen stays awake while receiving is on.")
        }
    }

    private var statusIcon: String {
        if !controller.wantsRunning { return "tray" }
        if controller.pausedReason != nil { return "pause.circle.fill" }
        if controller.receivedCount > 0 { return "checkmark.circle.fill" }
        if controller.connectedClients > 0 { return "camera.fill" }
        return "dot.radiowaves.left.and.right"
    }

    private var statusColor: Color {
        if !controller.wantsRunning { return .secondary }
        if controller.pausedReason != nil { return .orange }
        if controller.receivedCount > 0 || controller.connectedClients > 0 { return .green }
        return .accentColor
    }

    private var statusTitle: String {
        if !controller.wantsRunning { return "Not receiving" }
        if controller.pausedReason != nil { return "Paused" }
        if controller.receivedCount > 0 {
            return "\(controller.receivedCount) received"
        }
        if controller.connectedClients > 0 { return "Camera connected" }
        return "Waiting for the camera"
    }

    private var statusDetail: String {
        if !controller.wantsRunning {
            return "Tap Start receiving, then send photos from the camera."
        }
        if controller.receivedCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: controller.receivedBytes, countStyle: .file)
            if let name = controller.lastFileName {
                return "Last: \(name). Total \(size). Find them in the Library tab."
            }
            return "Total \(size). Find them in the Library tab."
        }
        if controller.connectedClients > 0 {
            return "Now send photos from the camera (step 4)."
        }
        return "Follow the steps below on the camera."
    }

    // MARK: Step 1 - network

    private var networkSection: some View {
        Section {
            Picker("Camera connects through", selection: $link) {
                ForEach(SonyLink.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            ForEach(Array(networkSteps.enumerated()), id: \.offset) { index, step in
                stepRow(letter: index, text: step)
            }
            if let address = controller.address(for: link) {
                Label("This iPhone's address: \(address)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                Label(missingAddressText, systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            stepHeader(1, "Put the camera and iPhone on one network")
        }
    }

    private var networkSteps: [String] {
        switch link {
        case .hotspot:
            return [
                "iPhone: open Settings > Personal Hotspot and switch on Allow Others to Join. Stay on that screen until the camera has joined - the hotspot is only easy to find while it is open.",
                "If the camera cannot see the hotspot, switch on Maximize Compatibility on the same screen.",
                "Camera: MENU > Network > Wi-Fi > Access Point Set. Choose this iPhone's name and enter the hotspot password shown on the iPhone.",
                "Come back to this app."
            ]
        case .wifi:
            return [
                "iPhone: join your Wi-Fi network in Settings > Wi-Fi.",
                "Camera: MENU > Network > Wi-Fi > Access Point Set. Choose the same network and enter its password.",
                "Guest networks and some public Wi-Fi block devices from talking to each other. If the camera never connects, use Personal Hotspot instead."
            ]
        }
    }

    private var missingAddressText: String {
        switch link {
        case .hotspot:
            return "No hotspot address yet. It appears a few seconds after the camera joins the hotspot. It is usually 172.20.10.1."
        case .wifi:
            return "This iPhone is not on Wi-Fi. Join a network in Settings > Wi-Fi."
        }
    }

    // MARK: Step 2 - camera settings

    private var hostValue: String {
        controller.address(for: link) ?? (link == .hotspot ? "172.20.10.1" : "(join Wi-Fi first)")
    }

    private var cameraSettingsSection: some View {
        Section {
            Text("Camera: MENU > Network > FTP Transfer > FTP Transfer Func. > Server Setting > Server 1. Enter these exactly:")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            valueRow("Destination Settings > Host Name", hostValue)
            valueRow("Destination Settings > Secure Protocol", "Off", copyable: false)
            valueRow("Destination Settings > Port", String(controller.port))
            valueRow("User Info Settings > User", controller.username)
            valueRow("User Info Settings > Password", controller.password)
            valueRow("Passive Mode", "On", copyable: false)
            valueRow("Directory Settings > Specify Directory", "leave empty", copyable: false)
            if let copiedValue {
                Text("Copied \(copiedValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            stepHeader(2, "Tell the camera where to send")
        } footer: {
            Text("You only do this once. The camera remembers Server 1. The password is case-sensitive; tap a value to copy it.")
        }
    }

    // MARK: Step 3 and 4 - switch on and send

    private var sendSection: some View {
        Group {
            Section {
                stepRow(letter: 0, text: "Tap Start receiving at the top of this screen.")
                stepRow(letter: 1, text: "Camera: MENU > Network > FTP Transfer > FTP Transfer Func. > FTP Function > On.")
                stepRow(letter: 2, text: "An FTP icon appears on the camera's screen when it has connected, and \"Camera connected\" appears here.")
            } header: {
                stepHeader(3, "Switch on FTP on the camera")
            }
            Section {
                stepRow(letter: 0, text: "Camera: MENU > Network > FTP Transfer > FTP Transfer Func. > FTP Transfer.")
                stepRow(letter: 1, text: "Target Group: This Date (or This Media for the whole card). Transfer Status: Only Non-transfer.")
                stepRow(letter: 2, text: "Choose OK. The photos arrive here and in the Library tab.")
                stepRow(letter: 3, text: "To send every shot as you take it, use Auto FTP Transfer in the same camera menu instead.")
            } header: {
                stepHeader(4, "Send photos")
            } footer: {
                Text("RAW files from the A7CR are about 60 to 120 MB each and take a while. To send JPEGs only, choose JPEG under the still image transfer setting in the camera's FTP Transfer menu.")
            }
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        Section {
            checkRow("Receiving is switched on", done: controller.isRunning,
                     waiting: "Tap Start receiving.")
            checkRow("The camera reached this iPhone", done: controller.sawConnection,
                     waiting: "Not yet. This is step 1 (network) or the Host Name and Port in step 2.")
            checkRow("The camera logged in", done: controller.sawLogin,
                     waiting: controller.loginRejected
                        ? "The user name or password on the camera is wrong. Re-enter them from step 2."
                        : "Not yet.",
                     failed: controller.loginRejected)
            checkRow("First photo received", done: controller.receivedCount > 0,
                     waiting: "Not yet. Send from the camera (step 4).")
            if controller.sawSecureAttempt && !controller.sawLogin {
                Label("The camera asked for a secure connection. Set Destination Settings > Secure Protocol to Off on the camera.",
                      systemImage: "lock.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("How far it has got")
        } footer: {
            Text("If a setup fails, the first line without a tick is where to look.")
        }
    }

    // MARK: Troubleshooting

    private var troubleshootingSection: some View {
        Section {
            DisclosureGroup("It is not working") {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        controller.runSelfTest()
                    } label: {
                        Label("Check the server on this iPhone", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.isRunning || controller.selfTest == .running)
                    selfTestResult
                    ForEach(Array(SonyFTPView.troubleshooting.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0).font(.subheadline.bold())
                            Text(item.1)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var selfTestResult: some View {
        switch controller.selfTest {
        case .idle:
            if !controller.isRunning {
                Text("Start receiving first, then run the check.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking...").font(.footnote)
            }
        case .passed(let text):
            Label(text + " If the camera still cannot connect, the problem is the network (step 1) or the values typed into the camera (step 2).",
                  systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let troubleshooting: [(String, String)] = [
        ("The camera shows an FTP error",
         "On the camera: MENU > Network > FTP Transfer > FTP Transfer Func. > Display FTP Error Info. The message says whether it could not find the server or could not log in."),
        ("\"The camera reached this iPhone\" never gets a tick",
         "The camera and iPhone are not on the same network, or the Host Name or Port on the camera is wrong. On Personal Hotspot the Host Name is normally 172.20.10.1. Check that the camera's Wi-Fi shows as connected, and that iPhone Settings > Privacy & Security > Local Network has Camera Transfer switched on."),
        ("It reached the iPhone but did not log in",
         "Re-enter User and Password on the camera. The password is lower-case letters and digits. Secure Protocol must be Off."),
        ("It logged in but no photo arrives",
         "Passive Mode must be On. Then send again from FTP Transfer, with Transfer Status set to All if the photos were already marked as transferred."),
        ("It worked before and stopped",
         "The iPhone's address changes when it joins a different network. Compare the address in step 1 with the Host Name on the camera."),
        ("The camera drops off the hotspot",
         "iPhone hotspots switch off when nothing is connected for a while. Open Settings > Personal Hotspot again, then switch the camera's FTP Function off and on.")
    ]

    // MARK: Details

    private var detailsSection: some View {
        Section {
            DisclosureGroup("Details") {
                AutoTransferModePicker(cameraBattery: .notApplicable)
                if mode != .manual {
                    Text("Each JPEG the camera sends is added to Photos (add-only). Only the phone's battery is checked, because the camera's cannot be read over FTP. Added so far: \(controller.photosAdded).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if setupDone {
                    Button("Start the setup checklist again") {
                        controller.resetProgress()
                        setupDone = false
                        showSteps = true
                    }
                }
                ForEach(controller.addresses) { address in
                    LabeledContent(address.friendlyName) {
                        Text(address.address).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
                if controller.log.isEmpty {
                    Text("No activity yet.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(controller.log.prefix(40)) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: entry.isFile ? "checkmark.circle.fill" : "info.circle")
                                .foregroundStyle(entry.isFile ? Color.green : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(entry.text).font(.footnote)
                                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Clear activity") { controller.clearLog() }
                }
                DebugLogView(lines: controller.protocolLog, onClear: { controller.protocolLog = [] })
            }
        } footer: {
            Text("Port, user name and password can be changed in Settings > Advanced.")
        }
    }

    // MARK: Row helpers

    private func stepHeader(_ number: Int, _ title: String) -> some View {
        Text("Step \(number): \(title)")
    }

    private func stepRow(letter index: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "\(index + 1).circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func valueRow(_ label: String, _ value: String, copyable: Bool = true) -> some View {
        Button {
            if copyable {
                UIPasteboard.general.string = value
                copiedValue = value
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func checkRow(_ title: String, done: Bool, waiting: String, failed: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : (failed ? "xmark.circle.fill" : "circle"))
                .foregroundStyle(done ? Color.green : (failed ? Color.red : Color.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if !done {
                    Text(waiting)
                        .font(.caption)
                        .foregroundStyle(failed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
