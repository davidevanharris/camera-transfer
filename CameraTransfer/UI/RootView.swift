import SwiftUI

enum AppTab: Hashable {
    case library
    case cameras
    case settings
}

@MainActor
struct RootView: View {
    @State private var ricohModel = CameraBrowserViewModel(camera: .ricoh)
    @State private var olympusModel = CameraBrowserViewModel(camera: .olympus)
    @State private var ftpController = FTPServerController()
    @State private var libraryModel = LibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AutoTransferSettings.modeKey) private var autoMode: AutoTransferMode = .manual
    @State private var tab: AppTab = .library

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                LibraryView(model: libraryModel,
                            refreshToken: ftpController.lastReceivedAt,
                            onShowCameras: { tab = .cameras })
            }
            .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            .tag(AppTab.library)

            NavigationStack {
                CamerasView(ricohModel: ricohModel, olympusModel: olympusModel, ftpController: ftpController)
            }
            .tabItem { Label("Cameras", systemImage: "camera") }
            .tag(AppTab.cameras)

            NavigationStack {
                SettingsView(ftpController: ftpController)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .library {
                Task { await libraryModel.reload() }
            }
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
