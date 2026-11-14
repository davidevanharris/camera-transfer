import SwiftUI
import UIKit

/// Mode picker plus the current policy decision. Shown on every camera tab and in Settings.
struct AutoTransferModePicker: View {
    @AppStorage(AutoTransferSettings.modeKey) private var mode: AutoTransferMode = .manual
    @AppStorage(AutoTransferSettings.allowUnknownCameraBatteryKey) private var allowUnknown = true
    let cameraBattery: CameraBatteryReading
    var showsDecision = true

    private var battery: PhoneBatteryMonitor { PhoneBatteryMonitor.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Auto-transfer", systemImage: mode == .manual ? "bolt.slash" : "bolt.fill")
                    .font(.headline)
                Spacer()
                Picker("Auto-transfer mode", selection: $mode) {
                    ForEach(AutoTransferMode.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
            Text(mode.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsDecision && mode != .manual {
                let decision = TransferPolicy.evaluate(mode: mode,
                                                       phonePercent: battery.percent,
                                                       phoneCharging: battery.isCharging,
                                                       camera: cameraBattery,
                                                       allowWhenCameraBatteryUnknown: allowUnknown)
                Label(decision.reason, systemImage: decision.allowed ? "checkmark.circle" : "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(decision.allowed ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Auto-transfer card for the Ricoh and OM-3 tabs.
struct AutoTransferCard: View {
    let model: CameraBrowserViewModel
    @AppStorage(AutoTransferSettings.modeKey) private var mode: AutoTransferMode = .manual

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AutoTransferModePicker(cameraBattery: model.cameraBatteryReading)
            if mode != .manual {
                Text(model.autoTransfer.statusText)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.autoTransfer.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if model.autoTransfer.isRunning {
                        Button("Stop auto-transfer") { model.autoTransfer.stop() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Start auto-transfer") { model.startAutoTransfer() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isDownloading || model.connection == .connecting)
                    }
                    Spacer()
                    Text("\(model.autoTransfer.transferredCount) sent")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Only full-size JPEGs of shots taken after auto mode was switched on are sent, and they go straight to Photos (add-only). Keep the app open: iOS drops the camera Wi-Fi about a minute after the app leaves the foreground.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shown when the Ricoh's Wi-Fi is up but iOS could not join it automatically.
struct ManualJoinCard: View {
    let ssid: String
    let passphrase: String?
    let reason: String
    let onContinue: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Join the camera's Wi-Fi manually", systemImage: "wifi.exclamationmark")
                .font(.headline)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Network") {
                Text(ssid).font(.body.monospaced()).textSelection(.enabled)
            }
            if let passphrase {
                LabeledContent("Password") {
                    Text(passphrase).font(.body.monospaced()).textSelection(.enabled)
                }
                Button(copied ? "Password copied" : "Copy password") {
                    UIPasteboard.general.string = passphrase
                    copied = true
                }
                .buttonStyle(.bordered)
            }
            Text("1. Open Settings > Wi-Fi and join \"\(ssid)\".\n2. Come back here and tap Continue.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Button("I've joined - Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One-time Bluetooth pairing and camera selection for the Ricoh GR IV.
struct RicohPairingView: View {
    @Bindable var ble: RicohBLE
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("One-time pairing")
                    .font(.subheadline.bold())
                ForEach(Array(RicohPairingView.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.subheadline.monospacedDigit().bold())
                            .frame(width: 22, alignment: .trailing)
                        Text(step)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                if let name = ble.rememberedName {
                    HStack {
                        Label(name, systemImage: "camera")
                        Spacer()
                        if let battery = ble.batteryPercent {
                            Text("\(battery)%").font(.caption.monospacedDigit())
                        }
                        Button("Forget", role: .destructive) { ble.forget() }
                            .font(.caption)
                    }
                } else {
                    Text("No camera selected yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if ble.stage == .scanning {
                        Button("Stop searching") { ble.stopScan() }
                            .buttonStyle(.bordered)
                        ProgressView()
                    } else {
                        Button("Find camera") { ble.startScan() }
                            .buttonStyle(.bordered)
                    }
                }

                ForEach(ble.discovered) { device in
                    Button {
                        ble.choose(device)
                    } label: {
                        HStack {
                            Image(systemName: device.looksLikeCamera ? "camera.fill" : "dot.radiowaves.left.and.right")
                            Text(device.name)
                            Spacer()
                            if device.id == ble.rememberedID {
                                Image(systemName: "checkmark")
                            }
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Bluetooth pairing", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    static let steps: [String] = [
        "On the GR IV: MENU > Wireless Communication > Action Mode > On.",
        "Still in Wireless Communication: Pairing > Execute.",
        "Here: tap Find camera and pick your GR IV from the list (it is remembered).",
        "Tap Connect below. iOS shows a Bluetooth pairing request with a 6-digit code: check that it matches the camera, then accept on both. The first connection can take about 15 seconds.",
        "After pairing, Connect wakes the camera's Wi-Fi over Bluetooth, joins it (iOS asks you to confirm) and lists your photos."
    ]
}

/// Collapsible debug log.
struct DebugLogView: View {
    let lines: [String]
    var onClear: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                if lines.isEmpty {
                    Text("Empty.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(lines.suffix(200).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onClear, !lines.isEmpty {
                    Button("Clear log", action: onClear)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Label("Debug log (\(lines.count))", systemImage: "ladybug")
                .font(.subheadline)
        }
    }
}
