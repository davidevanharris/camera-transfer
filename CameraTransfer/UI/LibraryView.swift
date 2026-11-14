import SwiftUI
import QuickLook
import Observation

struct LibrarySnapshot: Sendable {
    var files: [CameraModel: [LocalFile]] = [:]
    var totalBytes: Int64 = 0
}

@MainActor
@Observable
final class LibraryViewModel {
    var camera: CameraModel = .ricoh
    var snapshot = LibrarySnapshot()
    var isLoading = false
    var isSelecting = false
    var selection: Set<String> = []
    var message: String?
    var isExporting = false

    private let store: LibraryStore

    init(store: LibraryStore = .shared) {
        self.store = store
    }

    var files: [LocalFile] { snapshot.files[camera] ?? [] }

    var cameraBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    var selectedFiles: [LocalFile] { files.filter { selection.contains($0.id) } }

    func reload() async {
        isLoading = true
        let store = self.store
        let result = await Task.detached(priority: .userInitiated) { () -> LibrarySnapshot in
            var snapshot = LibrarySnapshot()
            for camera in CameraModel.allCases {
                let files = store.files(for: camera)
                snapshot.files[camera] = files
                snapshot.totalBytes += files.reduce(0) { $0 + $1.size }
            }
            return snapshot
        }.value
        snapshot = result
        let valid = Set(files.map(\.id))
        selection = selection.intersection(valid)
        isLoading = false
    }

    func delete(_ toDelete: [LocalFile]) async {
        var failures = 0
        for file in toDelete {
            do {
                try store.delete(file)
                LocalThumbnailCache.shared.remove(file.url)
            } catch {
                failures += 1
            }
        }
        message = failures == 0 ? "Deleted \(toDelete.count) file(s)." : "Could not delete \(failures) file(s)."
        selection = []
        isSelecting = false
        await reload()
    }

    func exportToPhotos(_ toExport: [LocalFile]) async {
        guard !toExport.isEmpty else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let result = try await PhotoExporter.export(toExport.map(\.url))
            if result.failures.isEmpty {
                message = "Added \(result.added) item(s) to Photos."
            } else {
                message = "Added \(result.added) item(s) to Photos. Failed: " + result.failures.joined(separator: "; ")
            }
        } catch {
            message = CameraError.userMessage(for: error, baseURL: nil)
        }
    }
}

struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    /// Changes whenever the FTP server receives a file, so the list refreshes.
    var refreshToken: Date?

    @State private var previewURL: URL?
    @State private var pendingDelete: [LocalFile] = []
    @State private var showDeleteConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 3)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Camera", selection: $model.camera) {
                    ForEach(CameraModel.allCases) { camera in
                        Text(camera.shortName).tag(camera)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.camera) { _, _ in
                    model.selection = []
                }

                HStack {
                    Text("\(model.files.count) files, \(ByteCountFormatter.string(fromByteCount: model.cameraBytes, countStyle: .file))")
                    Spacer()
                    Text("Total \(ByteCountFormatter.string(fromByteCount: model.snapshot.totalBytes, countStyle: .file))")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if model.isSelecting {
                    selectionBar
                }

                if model.files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(model.isLoading ? "Loading..." : "No files from the \(model.camera.displayName) yet.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(model.files) { file in
                            LocalThumbnailCell(file: file,
                                               isSelecting: model.isSelecting,
                                               isSelected: model.selection.contains(file.id))
                                .onTapGesture {
                                    if model.isSelecting {
                                        if model.selection.contains(file.id) {
                                            model.selection.remove(file.id)
                                        } else {
                                            model.selection.insert(file.id)
                                        }
                                    } else {
                                        previewURL = file.url
                                    }
                                }
                                .contextMenu {
                                    ShareLink(item: file.url) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        Task { await model.exportToPhotos([file]) }
                                    } label: {
                                        Label("Save to Photos (add-only)", systemImage: "photo.badge.plus")
                                    }
                                    Button(role: .destructive) {
                                        pendingDelete = [file]
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.isSelecting ? "Done" : "Select") {
                    model.isSelecting.toggle()
                    if !model.isSelecting { model.selection = [] }
                }
                .disabled(model.files.isEmpty)
            }
        }
        .refreshable { await model.reload() }
        .task { await model.reload() }
        .onChange(of: refreshToken) { _, _ in
            Task { await model.reload() }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let files = pendingDelete
                pendingDelete = []
                Task { await model.delete(files) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = []
            }
        } message: {
            Text("The files are removed from this iPhone. Copies on the camera and in Photos are not affected.")
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) files?"
    }

    private var selectionBar: some View {
        let selected = model.selectedFiles
        return HStack {
            Button("All") {
                model.selection = Set(model.files.map(\.id))
            }
            Spacer()
            ShareLink(items: selected.map(\.url)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(selected.isEmpty)
            Spacer()
            Button {
                Task { await model.exportToPhotos(selected) }
            } label: {
                Label("Photos", systemImage: "photo.badge.plus")
            }
            .disabled(selected.isEmpty || model.isExporting)
            Spacer()
            Button(role: .destructive) {
                pendingDelete = selected
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selected.isEmpty)
        }
        .font(.subheadline)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LocalThumbnailCell: View {
    let file: LocalFile
    let isSelecting: Bool
    let isSelected: Bool

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
                    Image(systemName: file.kind.systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(file.kind == .other ? file.url.pathExtension.uppercased() : file.kind.label)
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
                }
            }
            .overlay {
                if isSelected {
                    Rectangle().stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(file.name), \(file.kind.label)")
            .task(id: file.id) {
                if image == nil {
                    image = LocalThumbnailCache.shared.cachedImage(for: file.url)
                }
                if image == nil {
                    image = await LocalThumbnailCache.shared.thumbnail(for: file)
                }
            }
    }
}
