import SwiftUI

struct WatchCameraList: View {
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        List {
            Section {
                ForEach(WatchCamera.all) { camera in
                    NavigationLink(value: camera) {
                        Label(camera.name, systemImage: "camera")
                    }
                }
            } footer: {
                Text("Keep Camera Transfer open on the iPhone. The iPhone connects to the camera; this Watch is its remote.")
            }
        }
        .navigationTitle("Cameras")
        .navigationDestination(for: WatchCamera.self) { camera in
            WatchRemoteView(camera: camera)
        }
    }
}

/// Live picture with a shutter button for one camera.
struct WatchRemoteView: View {
    let camera: WatchCamera
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                if let image = link.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    statusText
                        .padding(6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if case .failed = link.state {
                Button("Try Again") {
                    link.start(camera)
                }
            } else {
                Button {
                    link.shoot()
                } label: {
                    if link.isShooting {
                        ProgressView()
                    } else {
                        Label("Shutter", systemImage: "circle.inset.filled")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.state != .running || link.isShooting)
            }
        }
        .navigationTitle(camera.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            link.start(camera)
        }
        .onDisappear {
            link.stop()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if let problem = link.linkProblem {
            Text(problem)
                .font(.footnote)
                .multilineTextAlignment(.center)
        } else {
            switch link.state {
            case .idle:
                Text("Live view is off.")
                    .font(.footnote)
            case .starting:
                VStack(spacing: 4) {
                    ProgressView()
                    Text("Starting on the iPhone...")
                        .font(.footnote)
                }
            case .running:
                ProgressView()
            case .failed(let message):
                ScrollView {
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}
