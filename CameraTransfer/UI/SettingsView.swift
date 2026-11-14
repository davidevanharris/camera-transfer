import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.ricohBaseURL) private var ricohBaseURL = AppDefaults.ricohBaseURL
    @AppStorage(SettingsKey.olympusBaseURL) private var olympusBaseURL = AppDefaults.olympusBaseURL
    @AppStorage(SettingsKey.ftpPort) private var ftpPort = AppDefaults.ftpPort
    @AppStorage(SettingsKey.ftpUsername) private var ftpUsername = AppDefaults.ftpUsername
    @AppStorage(SettingsKey.ftpPassword) private var ftpPassword = ""
    @AppStorage(SettingsKey.exportAfterDownload) private var exportAfterDownload = false
    @AppStorage(AutoTransferSettings.allowUnknownCameraBatteryKey) private var allowUnknownCameraBattery = true
    @AppStorage(AutoTransferSettings.keepCopyKey) private var keepCopy = false

    let ftpController: FTPServerController

    @State private var historyMessage: String?

    private var portText: Binding<String> {
        Binding(
            get: { String(ftpPort) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if let value = Int(digits), value <= 65535 {
                    ftpPort = value
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                AutoTransferModePicker(cameraBattery: .unknown, showsDecision: false)
                Toggle("Allow when camera battery is unknown", isOn: $allowUnknownCameraBattery)
                Toggle("Keep a copy in the app folder", isOn: $keepCopy)
            } header: {
                Text("Auto-transfer")
            } footer: {
                Text("Default: both phone and camera above 75%. Battery saver: above 90%. Gonna charge soon: above 25%. A charging phone always passes the phone check. Auto-transfer sends only the full-size JPEG of each new shot (no RAW, no video) and adds it to Photos with add-only access; shots already on the card when you switch auto mode on are never imported. \"Allow when camera battery is unknown\" matters for the OM-3 (and for a Ricoh whose battery cannot be read). With \"Keep a copy\" off, the app's own copy is deleted after it is safely in Photos; if adding to Photos fails, the file is kept. Auto-transfer runs only while the app is open: iOS drops the camera Wi-Fi about a minute after the app leaves the foreground.")
            }

            Section {
                urlField("Base URL", text: $ricohBaseURL)
                if ricohBaseURL != AppDefaults.ricohBaseURL {
                    Button("Reset to \(AppDefaults.ricohBaseURL)") { ricohBaseURL = AppDefaults.ricohBaseURL }
                }
                validity(for: ricohBaseURL)
            } header: {
                Text("Ricoh GR IV")
            }

            Section {
                urlField("Base URL", text: $olympusBaseURL)
                if olympusBaseURL != AppDefaults.olympusBaseURL {
                    Button("Reset to \(AppDefaults.olympusBaseURL)") { olympusBaseURL = AppDefaults.olympusBaseURL }
                }
                validity(for: olympusBaseURL)
            } header: {
                Text("OM System OM-3")
            } footer: {
                Text("For testing in the Simulator with tools/mock_cameras.py use http://localhost:8001 (Ricoh) and http://localhost:8002 (OM System).")
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("2121", text: portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                HStack {
                    Text("User name")
                    Spacer()
                    TextField("camera", text: $ftpUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                HStack {
                    Text("Password")
                    Spacer()
                    TextField("password", text: $ftpPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                Button("Generate new password") {
                    ftpPassword = AppDefaults.randomPassword()
                    ftpController.refreshInfo()
                }
            } header: {
                Text("Sony A7CR FTP server")
            } footer: {
                Text(ftpController.isRunning
                     ? "The server is running. Changes apply after you stop and start it again."
                     : "Use a port between 1024 and 65535. The password protects the server from other devices on the same network.")
            }

            Section {
                Toggle("After download, also add to Photos (add-only)", isOn: $exportAfterDownload)
            } header: {
                Text("Photos")
            } footer: {
                Text("Uses \"Add Photos Only\" permission. The app can never see your existing photos.")
            }

            Section {
                ForEach([CameraModel.ricoh, CameraModel.olympus]) { camera in
                    Button("Forget download history for \(camera.displayName)") {
                        LibraryStore.shared.resetIndex(for: camera)
                        historyMessage = "All files on the \(camera.displayName) will show as new on the next Connect."
                    }
                }
                if let historyMessage {
                    Text(historyMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Download history")
            }

            Section {
                privacyRow("photo.on.rectangle", "Your photo library",
                           "Never read. The app does not ask for Photos read access. Saving to Photos (optional, and used by auto-transfer) uses add-only access, so the app can add new items but cannot see, list or change anything already there.")
                privacyRow("folder", "Files",
                           "Transferred files are stored only in this app's own folder (Files > On My iPhone > Camera Transfer). Deleting the app deletes them.")
                privacyRow("wifi", "Network",
                           "The app only talks to your camera on the local network (plain HTTP to the camera, or the camera connecting to this phone's FTP server). No internet requests, no analytics, no accounts, no tracking.")
                privacyRow("dot.radiowaves.left.and.right", "Bluetooth",
                           "Used only to wake the Ricoh GR IV's Wi-Fi and to notice when it is switched on. Nothing else is scanned for or stored, apart from the identifier of the camera you pick.")
                privacyRow("wifi.router", "Joining camera Wi-Fi",
                           "The app can ask iOS to join the Ricoh's Wi-Fi for you (you confirm each time); the network is forgotten when the app leaves the foreground.")
                privacyRow("location.slash", "Location",
                           "Not used.")
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Version", value: appVersion)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func urlField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())
    }

    @ViewBuilder
    private func validity(for value: String) -> some View {
        if CameraHTTP.parseBaseURL(value) == nil {
            Text("Not a valid address.")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func privacyRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
