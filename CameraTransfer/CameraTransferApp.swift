import SwiftUI

@main
struct CameraTransferApp: App {
    init() {
        AppDefaults.registerAndPrepare()
        AutoTransferSettings.register()
        _ = PhoneBatteryMonitor.shared
        // Recreate the Bluetooth central at launch only if a Ricoh was paired before, so that
        // CoreBluetooth state restoration works and new users are not asked for Bluetooth up front.
        if RicohBLE.shared.rememberedID != nil {
            RicohBLE.shared.activate()
        }
        // Lets the Apple Watch app (if installed) drive live view and the shutter through this iPhone.
        WatchBridge.shared.activate()
        // Make sure the camera folders exist so they show up in the Files app straight away.
        for camera in CameraModel.allCases {
            LibraryStore.shared.folder(for: camera)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
