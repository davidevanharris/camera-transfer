import SwiftUI

/// The Apple Watch remote: pick a camera, see its live picture, press the shutter.
/// It talks only to the Camera Transfer app on the paired iPhone, which talks to the camera.
@main
struct CameraTransferWatchApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchCameraList()
            }
            .environmentObject(link)
        }
    }
}
