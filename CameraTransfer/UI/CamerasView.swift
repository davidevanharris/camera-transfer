import SwiftUI

/// The three cameras, each with a plain-language status. Tap one to connect or set it up.
struct CamerasView: View {
    let ricohModel: CameraBrowserViewModel
    let olympusModel: CameraBrowserViewModel
    let ftpController: FTPServerController

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CameraBrowserView(model: ricohModel)
                } label: {
                    CameraRow(name: CameraModel.ricoh.displayName,
                              icon: "camera",
                              status: status(for: ricohModel),
                              how: "Connects by Bluetooth, then the camera's own Wi-Fi")
                }
                NavigationLink {
                    SonyFTPView(controller: ftpController)
                } label: {
                    CameraRow(name: CameraModel.sony.displayName,
                              icon: "camera.fill",
                              status: sonyStatus,
                              how: "The camera sends photos to this iPhone over Wi-Fi or hotspot")
                }
                NavigationLink {
                    CameraBrowserView(model: olympusModel)
                } label: {
                    CameraRow(name: CameraModel.olympus.displayName,
                              icon: "camera.aperture",
                              status: status(for: olympusModel),
                              how: "Join the camera's own Wi-Fi, then connect")
                }
            } header: {
                Text("Import photos")
            } footer: {
                Text("Imported photos appear in the Library tab and in the Files app under Camera Transfer.")
            }

            Section {
                ForEach(CameraModel.allCases) { camera in
                    NavigationLink {
                        LiveViewView(camera: camera)
                    } label: {
                        Label(camera.displayName, systemImage: "dot.viewfinder")
                    }
                }
            } header: {
                Text("Live view and remote shutter")
            } footer: {
                Text("See what the camera sees and take a photo from this iPhone or from the Camera Transfer app on your Apple Watch. Experimental until tested on each camera.")
            }
        }
        .navigationTitle("Cameras")
    }

    private func status(for model: CameraBrowserViewModel) -> CameraRow.Status {
        if model.isDownloading {
            return .init(text: "Importing \(min(model.completedCount + 1, model.totalCount)) of \(model.totalCount)", tone: .active)
        }
        if model.autoTransfer.isRunning {
            return .init(text: "Auto-transfer running", tone: .active)
        }
        switch model.connection {
        case .idle:
            return .init(text: "Not connected", tone: .neutral)
        case .connecting:
            return .init(text: "Connecting...", tone: .active)
        case .connected:
            let newCount = model.newPhotos.count
            return .init(text: newCount == 0 ? "Connected, nothing new" : "Connected, \(newCount) new", tone: .good)
        case .needsManualJoin:
            return .init(text: "Join the camera's Wi-Fi", tone: .warning)
        case .failed:
            return .init(text: "Could not connect", tone: .warning)
        }
    }

    private var sonyStatus: CameraRow.Status {
        if !ftpController.wantsRunning {
            return .init(text: "Not receiving", tone: .neutral)
        }
        if ftpController.pausedReason != nil {
            return .init(text: "Paused", tone: .warning)
        }
        if ftpController.errorMessage != nil {
            return .init(text: "Could not start", tone: .warning)
        }
        if ftpController.receivedCount > 0 {
            return .init(text: "\(ftpController.receivedCount) received", tone: .good)
        }
        if ftpController.connectedClients > 0 {
            return .init(text: "Camera connected", tone: .good)
        }
        return .init(text: "Waiting for the camera", tone: .active)
    }
}

struct CameraRow: View {
    enum Tone {
        case neutral
        case active
        case good
        case warning
    }

    struct Status {
        let text: String
        let tone: Tone
    }

    let name: String
    let icon: String
    let status: Status
    let how: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(toneColor)
                        .frame(width: 8, height: 8)
                    Text(status.text)
                        .font(.subheadline)
                        .foregroundStyle(status.tone == .neutral ? Color.secondary : toneColor)
                }
                Text(how)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var toneColor: Color {
        switch status.tone {
        case .neutral: return Color(.systemGray3)
        case .active: return .accentColor
        case .good: return .green
        case .warning: return .orange
        }
    }
}
