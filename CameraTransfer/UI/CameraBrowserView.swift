import SwiftUI

/// One camera's screen (Ricoh GR IV or OM System OM-3): connect, see what is new, import.
struct CameraBrowserView: View {
    @Bindable var model: CameraBrowserViewModel
    @State private var showInstructions = true
    @State private var showDetails = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)]

    private var everConnectedKey: String { "everConnected." + model.camera.rawValue }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Group {
                    statusCard
                    if case .needsManualJoin(let ssid, let passphrase, let reason) = model.connection {
                        ManualJoinCard(ssid: ssid, passphrase: passphrase, reason: reason) {
                            model.connectWithoutBluetooth()
                        }
                    }
                    if !model.isConnected {
                        if model.camera == .ricoh {
                            RicohPairingView(ble: RicohBLE.shared, isExpanded: $showInstructions)
                        } else {
                            ConnectionInstructionsView(camera: model.camera, isExpanded: $showInstructions)
                        }
                    }
                    NavigationLink {
                        LiveViewView(camera: model.camera)
                    } label: {
                        Label("Live view and remote shutter", systemImage: "dot.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    if let message = model.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !model.downloadErrors.isEmpty {
                        errorList
                    }
                }
                .padding(.horizontal)

                if model.isConnected {
                    filterBar
                        .padding(.horizontal)
                    photoGrid
                }

                details
                    .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(model.camera.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.connect()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                        Button {
                            model.selectAllVisible()
                            model.isSelecting = true
                        } label: {
                            Label("Select All Shown", systemImage: "checkmark.circle")
                        }
                        .disabled(model.isDownloading || model.filteredPhotos.isEmpty)
                        Button(role: .destructive) {
                            model.disconnect()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                        .disabled(model.isDownloading)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isDownloading {
                DownloadProgressPanel(model: model)
            } else if model.isSelecting {
                selectionBar
            }
        }
        .onAppear {
            showInstructions = !UserDefaults.standard.bool(forKey: everConnectedKey)
        }
        .onChange(of: model.connection) { _, newValue in
            if case .connected = newValue {
                UserDefaults.standard.set(true, forKey: everConnectedKey)
                withAnimation { showInstructions = false }
            }
        }
    }

    private var debugLines: [String] {
        if model.camera == .ricoh {
            return (model.log + RicohBLE.shared.log).sorted()
        }
        return model.log
    }

    // MARK: Status and the one main button

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title)
                    .foregroundStyle(statusColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let stage = model.stage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(stage).font(.footnote)
                }
            }
            mainButton
            if model.autoTransfer.isRunning {
                Text("Auto-transfer is using the camera. Stop it under Details to import by hand.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var mainButton: some View {
        if model.isConnected {
            let newCount = model.newPhotos.count
            Button {
                model.downloadAllNew()
            } label: {
                Text(newCount == 0 ? "Nothing New to Import" : "Import \(newCount) New")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(newCount == 0 || model.isDownloading || model.autoTransfer.isRunning)
        } else {
            Button {
                model.connect()
            } label: {
                Text(model.connection == .connecting ? "Connecting..." : "Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy)
        }
    }

    private var statusIcon: String {
        switch model.connection {
        case .idle: return "camera"
        case .connecting: return "dot.radiowaves.left.and.right"
        case .connected: return "checkmark.circle.fill"
        case .needsManualJoin: return "wifi.exclamationmark"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.connection {
        case .idle: return .secondary
        case .connecting: return .accentColor
        case .connected: return .green
        case .needsManualJoin: return .orange
        case .failed: return .red
        }
    }

    private var statusTitle: String {
        switch model.connection {
        case .idle: return "Not connected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .needsManualJoin: return "Join the camera's Wi-Fi"
        case .failed: return "Could not connect"
        }
    }

    private var statusDetail: String {
        switch model.connection {
        case .idle:
            return model.camera == .ricoh
                ? "Switch the camera on, then tap Connect."
                : "Join the camera's Wi-Fi in iPhone Settings, then tap Connect."
        case .connecting:
            if model.camera == .ricoh {
                return "Bluetooth: \(RicohBLE.shared.stage.label)"
            }
            return "Looking for the camera..."
        case .connected(let description):
            return "\(description). \(model.photos.count) on the card, \(model.newPhotos.count) not imported yet."
        case .needsManualJoin:
            return "Follow the card below, then continue."
        case .failed(let message):
            return message
        }
    }

    // MARK: Grid

    private var filterBar: some View {
        Picker("Show", selection: $model.filter) {
            ForEach(CameraBrowserViewModel.Filter.allCases) { filter in
                Text(filter == .newOnly ? "New" : filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    private var selectionBar: some View {
        HStack {
            Button("Cancel") {
                model.selection = []
                model.isSelecting = false
            }
            Spacer()
            Button {
                model.downloadSelected()
            } label: {
                Text("Import \(model.selection.count) Selected")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selection.isEmpty || model.autoTransfer.isRunning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var errorList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.downloadErrors.prefix(10).enumerated()), id: \.offset) { _, error in
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if model.downloadErrors.count > 10 {
                Text("... and \(model.downloadErrors.count - 10) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var photoGrid: some View {
        let visible = model.filteredPhotos
        if visible.isEmpty {
            Text(model.photos.isEmpty ? "The memory card is empty." : "Nothing to show for this filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            Text("Tap photos to pick specific ones. A green arrow means already imported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(visible) { photo in
                    RemoteThumbnailCell(photo: photo,
                                        loader: model.thumbnails,
                                        isSelecting: model.isSelecting,
                                        isSelected: model.selection.contains(photo.id),
                                        isDownloaded: model.downloadedIDs.contains(photo.id))
                        .onTapGesture {
                            if !model.isDownloading {
                                if !model.isSelecting { model.isSelecting = true }
                                model.toggleSelection(photo)
                            }
                        }
                }
            }
        }
    }

    // MARK: Details (auto-transfer, fallbacks, log)

    private var details: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                AutoTransferCard(model: model)
                if model.isConnected {
                    if model.camera == .ricoh {
                        RicohPairingView(ble: RicohBLE.shared, isExpanded: $showInstructions)
                    } else {
                        ConnectionInstructionsView(camera: model.camera, isExpanded: $showInstructions)
                    }
                }
                if model.camera == .ricoh && !model.isConnected {
                    Button("Connect without Bluetooth (already on the camera's Wi-Fi)") {
                        model.connectWithoutBluetooth()
                    }
                    .font(.footnote)
                    .disabled(model.isDownloading || model.autoTransfer.isRunning)
                }
                DebugLogView(lines: debugLines, onClear: {
                    model.log = []
                    if model.camera == .ricoh { RicohBLE.shared.clearLog() }
                })
            }
            .padding(.top, 8)
        } label: {
            Label("Details", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct RemoteThumbnailCell: View {
    let photo: RemotePhoto
    let loader: RemoteThumbnailLoader
    let isSelecting: Bool
    let isSelected: Bool
    let isDownloaded: Bool

    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: photo.kind.systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(photo.kind == .other ? (photo.filename as NSString).pathExtension.uppercased() : photo.kind.label)
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                        .shadow(radius: 2)
                        .padding(4)
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.body)
                        .foregroundStyle(.white, .green)
                        .padding(4)
                }
            }
            .overlay {
                if isSelected {
                    Rectangle().stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(photo.filename), \(photo.kind.label)\(isDownloaded ? ", downloaded" : "")")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
            .task(id: photo.id) {
                if image == nil {
                    image = loader.cachedImage(for: photo)
                }
                if image == nil {
                    image = await loader.image(for: photo)
                }
            }
    }
}

struct DownloadProgressPanel: View {
    let model: CameraBrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading \(min(model.completedCount + 1, model.totalCount)) of \(model.totalCount)")
                    .font(.subheadline.bold())
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelDownloads() }
                    .buttonStyle(.bordered)
            }
            ProgressView(value: model.overallProgress)
            if let name = model.currentFileName {
                HStack {
                    Text(name)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(model.currentFileProgress * 100))%")
                        .font(.caption.monospacedDigit())
                }
                ProgressView(value: model.currentFileProgress)
                    .tint(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial)
    }
}
