import SwiftUI

struct CameraBrowserView: View {
    @Bindable var model: CameraBrowserViewModel
    @State private var showInstructions = true

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 3)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                AutoTransferCard(model: model)
                if model.camera == .ricoh {
                    RicohPairingView(ble: RicohBLE.shared, isExpanded: $showInstructions)
                } else {
                    ConnectionInstructionsView(camera: model.camera, isExpanded: $showInstructions)
                }
                connectionSection
                if case .needsManualJoin(let ssid, let passphrase, let reason) = model.connection {
                    ManualJoinCard(ssid: ssid, passphrase: passphrase, reason: reason) {
                        model.connectWithoutBluetooth()
                    }
                }
                if model.isConnected {
                    filterChips
                    actionButtons
                    if let message = model.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !model.downloadErrors.isEmpty {
                        errorList
                    }
                    photoGrid
                }
                DebugLogView(lines: debugLines, onClear: {
                    model.log = []
                    if model.camera == .ricoh { RicohBLE.shared.clearLog() }
                })
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle(model.camera.displayName)
        .toolbar {
            if model.isConnected && !model.photos.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isSelecting ? "Done" : "Select") {
                        model.isSelecting.toggle()
                        if !model.isSelecting { model.selection = [] }
                    }
                    .disabled(model.isDownloading)
                }
                if model.isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Select All") { model.selectAllVisible() }
                            .disabled(model.isDownloading)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isDownloading {
                DownloadProgressPanel(model: model)
            }
        }
        .onChange(of: model.connection) { _, newValue in
            if case .connected = newValue {
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

    // MARK: Sections

    @ViewBuilder
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    model.connect()
                } label: {
                    Label(model.isConnected ? "Refresh" : "Connect",
                          systemImage: model.isConnected ? "arrow.clockwise" : "bolt.horizontal.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)

                if model.isConnected {
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.bordered)
                        .disabled(model.isDownloading)
                }
            }

            if model.camera == .ricoh && !model.isConnected {
                Button("Connect without Bluetooth (already on the camera's Wi-Fi)") {
                    model.connectWithoutBluetooth()
                }
                .font(.footnote)
                .disabled(model.isDownloading || model.autoTransfer.isRunning)
            }

            if let stage = model.stage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(stage).font(.footnote)
                }
            }
            if model.camera == .ricoh, case .connecting = model.connection {
                Text("Bluetooth: \(RicohBLE.shared.stage.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.autoTransfer.isRunning {
                Text("Auto-transfer is using the camera. Stop it to browse and download manually.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            switch model.connection {
            case .idle:
                Text("Not connected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .connecting:
                if model.stage == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting to the camera...")
                            .font(.footnote)
                    }
                }
            case .needsManualJoin:
                EmptyView()
            case .connected(let description):
                Label("\(description) - \(model.photos.count) files, \(model.newPhotos.count) new",
                      systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CameraBrowserViewModel.Filter.allCases) { filter in
                    let isOn = model.filter == filter
                    Button {
                        model.filter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(isOn ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button {
                model.downloadSelected()
            } label: {
                Label("Download selected (\(model.selection.count))", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.selection.isEmpty || model.isDownloading || model.autoTransfer.isRunning)

            Button {
                model.downloadAllNew()
            } label: {
                Label("All new (\(model.newPhotos.count))", systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.newPhotos.isEmpty || model.isDownloading || model.autoTransfer.isRunning)
        }
        .font(.subheadline)
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
            Text(model.photos.isEmpty ? "The memory card is empty." : "No files match this filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
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
