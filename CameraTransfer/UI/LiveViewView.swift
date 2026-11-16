import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class LiveViewModel {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    var state: State = .idle
    var image: UIImage?
    var frameCount = 0
    var isShooting = false
    var shotMessage: String?
    var log: [String] = []

    @ObservationIgnored private var remote: OlympusRemote?
    @ObservationIgnored private var receiver: LiveViewReceiver?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    private func note(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("\(formatter.string(from: Date())) \(text)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func start() {
        guard state != .starting, state != .running else { return }
        guard let baseURL = AppDefaults.baseURL(for: .olympus) else {
            state = .failed("The camera address in Settings is not valid.")
            return
        }
        state = .starting
        frameCount = 0
        shotMessage = nil
        let newRemote = OlympusRemote(baseURL: baseURL)
        remote = newRemote
        let newReceiver = LiveViewReceiver { [weak self] jpeg in
            guard let picture = UIImage(data: jpeg) else { return }
            Task { @MainActor in
                self?.show(picture)
            }
        }
        do {
            try newReceiver.start(port: OlympusRemote.liveViewPort)
        } catch {
            state = .failed("Could not listen for the camera's video: \(error.localizedDescription)")
            return
        }
        receiver = newReceiver
        UIApplication.shared.isIdleTimerDisabled = true
        note("Asking the camera at \(baseURL.host ?? "?") to start live view...")
        Task {
            do {
                try await newRemote.startLiveView()
                self.note("The camera accepted the live-view request. Waiting for the picture...")
                self.startWatchdog()
            } catch {
                let message = CameraError.userMessage(for: error, baseURL: baseURL)
                self.note("Start failed: \(message)")
                if let commands = await newRemote.commandList() {
                    self.note("Commands this camera supports: \(commands.prefix(1500))")
                }
                self.teardown()
                self.state = .failed(message)
            }
        }
    }

    private func show(_ picture: UIImage) {
        guard state == .starting || state == .running else { return }
        image = picture
        frameCount += 1
        if state != .running {
            state = .running
            note("First frame received.")
        }
    }

    /// If the camera accepts the request but no picture arrives, say so instead of waiting forever.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.state == .starting {
                self.note("No picture after 8 seconds.")
                self.teardown()
                self.state = .failed("The camera accepted the request but sent no picture. This camera may use a different live-view method, or iOS blocked the video: check Settings > Privacy & Security > Local Network.")
            }
        }
    }

    func shoot() {
        guard let remote, !isShooting else { return }
        isShooting = true
        shotMessage = nil
        Task {
            do {
                let command = try await remote.takePhoto()
                self.note("Shutter command accepted (\(command)).")
                self.shotMessage = "Shutter command sent. Check the camera took the photo."
            } catch {
                let message = CameraError.userMessage(for: error, baseURL: nil)
                self.note("Shutter failed: \(message)")
                self.shotMessage = "The camera refused the shutter command: \(message)"
            }
            self.isShooting = false
        }
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        receiver?.stop()
        receiver = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func stop() {
        let finishing = remote
        remote = nil
        teardown()
        image = nil
        if state == .starting || state == .running {
            state = .idle
        }
        Task {
            await finishing?.stopLiveView()
            await finishing?.returnToPlayback()
        }
    }
}

/// Live picture from the camera with a shutter button. OM System OM-3 only, and experimental.
struct LiveViewView: View {
    let camera: CameraModel
    @State private var model = LiveViewModel()
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Color.black
                if let image = model.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    placeholder
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            if let message = model.shotMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                model.shoot()
            } label: {
                ZStack {
                    Circle().stroke(Color.primary, lineWidth: 4).frame(width: 78, height: 78)
                    Circle().fill(Color.primary).frame(width: 64, height: 64)
                }
            }
            .disabled(model.state != .running || model.isShooting)
            .opacity(model.state == .running ? 1 : 0.35)
            .accessibilityLabel("Take photo")

            if model.state == .idle || isFailed {
                Button("Start Live View") { model.start() }
                    .buttonStyle(.borderedProminent)
            }

            Spacer(minLength: 0)

            DisclosureGroup("Troubleshooting log", isExpanded: $showLog) {
                ScrollView {
                    Text(model.log.isEmpty ? "Empty." : model.log.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
            .font(.footnote)
            .padding(.horizontal)

            Text("Experimental: based on how older Olympus cameras work and not yet confirmed on the OM-3. The iPhone must be joined to the camera's Wi-Fi.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical)
        .navigationTitle("Live View")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.state {
        case .idle:
            Text("Live view is off.")
                .foregroundStyle(.white)
        case .starting:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Starting live view...")
                    .foregroundStyle(.white)
            }
        case .running:
            ProgressView().tint(.white)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
