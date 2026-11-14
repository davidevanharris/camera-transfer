import SwiftUI

@MainActor
struct RootView: View {
    @State private var ricohModel = CameraBrowserViewModel(camera: .ricoh)
    @State private var olympusModel = CameraBrowserViewModel(camera: .olympus)
    @State private var ftpController = FTPServerController()
    @State private var libraryModel = LibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AutoTransferSettings.modeKey) private var autoMode: AutoTransferMode = .manual

    var body: some View {
        TabView {
            NavigationStack {
                CameraBrowserView(model: ricohModel)
            }
            .tabItem { Label("GR IV", systemImage: "camera") }

            NavigationStack {
                SonyFTPView(controller: ftpController)
            }
            .tabItem { Label("A7CR", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack {
                CameraBrowserView(model: olympusModel)
            }
            .tabItem { Label("OM-3", systemImage: "camera.aperture") }

            NavigationStack {
                LibraryView(model: libraryModel, refreshToken: ftpController.lastReceivedAt)
            }
            .tabItem { Label("Library", systemImage: "photo.stack") }

            NavigationStack {
                SettingsView(ftpController: ftpController)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                PhoneBatteryMonitor.shared.refresh()
                ricohModel.appBecameActive()
                olympusModel.appBecameActive()
                ftpController.evaluatePolicy()
            case .background:
                ricohModel.autoTransfer.stopAfterCurrentFile()
                olympusModel.autoTransfer.stopAfterCurrentFile()
            default:
                break
            }
        }
        .onChange(of: autoMode) { oldMode, newMode in
            autoModeChanged(from: oldMode, to: newMode)
        }
    }

    private func autoModeChanged(from oldMode: AutoTransferMode, to newMode: AutoTransferMode) {
        if newMode == .manual {
            // Disarm: forget the baselines and stop polling.
            LibraryStore.shared.clearBaselines()
            ricohModel.autoTransfer.stop("Auto-transfer turned off.")
            olympusModel.autoTransfer.stop("Auto-transfer turned off.")
        } else if oldMode == .manual {
            // Arm: the next camera listing records which photos already exist.
            LibraryStore.shared.clearBaselines()
            Task {
                _ = await PhotoExporter.requestAddOnlyAccess()
                ricohModel.appBecameActive()
                olympusModel.appBecameActive()
            }
        }
        ftpController.evaluatePolicy()
    }
}
