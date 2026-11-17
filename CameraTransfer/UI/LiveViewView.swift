import SwiftUI
import UIKit

/// What to do on the camera before live view can start, per camera.
struct RemoteSetupGuide {
    let intro: String
    let steps: [String]
    let caveat: String

    static func guide(for camera: CameraModel) -> RemoteSetupGuide {
        switch camera {
        case .sony:
            return RemoteSetupGuide(
                intro: "The A7CR is controlled through its PC Remote function. Do this once on the camera:",
                steps: [
                    "Put the camera and this iPhone on the same network, exactly as for sending photos (Personal Hotspot or home Wi-Fi). Camera: MENU > Network > Wi-Fi > Access Point Set.",
                    "MENU > Network > Network Option > Access Authen. Settings > Access Authen. > Off. Sony's note: with this off, remote control on that network is not password-protected or encrypted, so use your own hotspot or home Wi-Fi.",
                    "MENU > Network > Cnct./PC Remote > Remote Shoot Setting > Still Img. Save Dest. > Camera Only, so photos are saved to the memory card.",
                    "MENU > Network > Cnct./PC Remote > PC Remote Function > PC Remote > On.",
                    "First time only: in the same PC Remote Function menu choose Pairing and leave that screen showing. Then tap Start Live View here and confirm on the camera when it asks to connect to \"Camera Transfer\".",
                    "Leave the camera in a shooting mode (not playback, not a menu) and close Sony's Creators' App on the phone: the camera accepts one remote at a time."
                ],
                caveat: "Experimental: built from how other Sony Alpha cameras work and not yet confirmed on the A7CR. Sending photos by FTP may not work while PC Remote is On; switch PC Remote Off again if it stops.")
        case .ricoh:
            return RemoteSetupGuide(
                intro: "The GR IV sends its picture over its own Wi-Fi and takes the shutter command over Bluetooth:",
                steps: [
                    "Go back and tap Connect on the Ricoh GR IV screen first. That pairs over Bluetooth and joins the camera's Wi-Fi.",
                    "Leave the camera in shooting mode (not playback).",
                    "Come back here. Live view starts by itself."
                ],
                caveat: "Experimental: a community project reports this working on the GR IV, but it is not yet confirmed with this app.")
        case .olympus:
            return RemoteSetupGuide(
                intro: "The OM-3 sends its picture over its own Wi-Fi:",
                steps: [
                    "On the camera, start the smartphone Wi-Fi connection so it shows its network name and password.",
                    "On this iPhone, join that network in Settings > Wi-Fi.",
                    "Come back here. Live view starts by itself."
                ],
                caveat: "Experimental: based on how older Olympus cameras work and not yet confirmed on the OM-3.")
        }
    }
}

/// Live picture from the camera with a shutter button. Works the same way for all three cameras.
@MainActor
struct LiveViewView: View {
    let camera: CameraModel
    @State private var showLog = false
    @State private var showSetup = false

    private var control: RemoteControl { RemoteControl.shared }

    private var guide: RemoteSetupGuide { RemoteSetupGuide.guide(for: camera) }

    /// The Sony needs camera-side setup, so it does not start until asked the first time.
    private var startsAutomatically: Bool {
        camera != .sony || UserDefaults.standard.bool(forKey: RemoteControl.workedKey(camera))
    }

    private var isShowingThisCamera: Bool { control.camera == camera }

    private var state: RemoteControl.State {
        isShowingThisCamera ? control.state : .idle
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                picture
                    .padding(.horizontal)

                if isShowingThisCamera, let message = control.shotMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                shutterButton

                if !state.isActive {
                    Button {
                        control.start(camera)
                    } label: {
                        Label("Start Live View", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                }

                DisclosureGroup("How to set up the camera", isExpanded: $showSetup) {
                    setupSteps
                }
                .font(.subheadline)
                .padding(.horizontal)

                DisclosureGroup("Troubleshooting log", isExpanded: $showLog) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(logText)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = logText
                        } label: {
                            Label("Copy log", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline)
                .padding(.horizontal)

                Text(guide.caveat + " The iPhone must stay on this screen: live view stops when the app goes to the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("Live View: \(camera.shortName)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            showSetup = !UserDefaults.standard.bool(forKey: RemoteControl.workedKey(camera))
            if startsAutomatically {
                control.start(camera)
            } else if control.camera != camera {
                // Do not show another camera's leftovers.
                control.stop()
            }
        }
        .onDisappear {
            if control.camera == camera {
                control.stop()
            }
        }
        .onChange(of: state) { _, newState in
            if case .failed = newState {
                showSetup = true
            }
        }
    }

    private var logText: String {
        let lines = isShowingThisCamera ? control.log : []
        return lines.isEmpty ? "Empty." : lines.joined(separator: "\n")
    }

    private var picture: some View {
        ZStack {
            Color.black
            if isShowingThisCamera, let image = control.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Live picture from the camera")
    }

    private var shutterButton: some View {
        Button {
            control.shoot()
        } label: {
            ZStack {
                Circle().stroke(Color.primary, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(Color.primary).frame(width: 64, height: 64)
                if isShowingThisCamera, control.isShooting {
                    ProgressView().tint(Color(.systemBackground))
                }
            }
        }
        .disabled(state != .running || control.isShooting)
        .opacity(state == .running ? 1 : 0.35)
        .accessibilityLabel("Take photo")
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(guide.intro)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.footnote.bold())
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                    Text(step)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch state {
        case .idle:
            Text("Live view is off.")
                .foregroundStyle(.white)
        case .starting:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(camera == .sony ? "Connecting. Confirm on the camera if it asks." : "Starting live view...")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding()
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
