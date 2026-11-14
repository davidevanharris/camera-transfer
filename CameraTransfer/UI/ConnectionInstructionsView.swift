import SwiftUI

struct ConnectionInstructionsView: View {
    let camera: CameraModel
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.subheadline.monospacedDigit().bold())
                            .frame(width: 22, alignment: .trailing)
                        Text(step)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("How to connect", systemImage: "wifi")
                .font(.headline)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    static func steps(for camera: CameraModel) -> [String] {
        switch camera {
        case .ricoh:
            // The Ricoh tab uses RicohPairingView instead; kept for completeness.
            return RicohPairingView.steps
        case .olympus:
            return [
                "On the OM-3, open MENU > Setup (wrench) > Wi-Fi/Bluetooth settings and start the connection to a smartphone, so the camera shows its network name (SSID) and password (choose the private / Wi-Fi option if asked).",
                "On this iPhone, open Settings > Wi-Fi and join the camera's network. iOS may say \"No Internet Connection\" - that is expected, stay connected.",
                "Come back to this app and tap Connect. If iOS asks to find devices on your local network, tap Allow.",
                "Pick photos and tap Download. Files are saved in Files > On My iPhone > Camera Transfer > OM System OM-3.",
                "For auto-transfer, pick a mode above while connected to the camera's Wi-Fi. The OM-3's battery level cannot be read, so the \"Allow when camera battery is unknown\" setting decides."
            ]
        case .sony:
            return []
        }
    }

    private var steps: [String] { ConnectionInstructionsView.steps(for: camera) }

    private var note: String? {
        switch camera {
        case .ricoh:
            return "The GR IV's Wi-Fi is started over Bluetooth by this app; see the README."
        case .olympus:
            return "The camera address defaults to http://192.168.0.10 and can be changed in Settings."
        case .sony:
            return nil
        }
    }
}
