import SwiftUI
import QuickLook
import Observation

struct LibrarySnapshot: Sendable {
    var files: [CameraModel: [LocalFile]] = [:]
    var totalBytes: Int64 = 0
}

/// One day's worth of transferred files, newest day first.
struct LibraryDay: Identifiable, Sendable {
    let day: Date
    let files: [LocalFile]

    var id: Date { day }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

enum LibraryGrouping {
    /// Filters, sorts newest first and groups by calendar day. Pure, so it can be unit-tested.
    static func days(from snapshot: LibrarySnapshot,
                     camera: CameraModel?,
                     kind: FileKind?,
                     calendar: Calendar = .current) -> [LibraryDay] {
        var all: [LocalFile] = []
        for (model, files) in snapshot.files where camera == nil || camera == model {
            all.append(contentsOf: files)
        }
        if let kind {
            all = all.filter { $0.kind == kind }
        }
        all.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.id < rhs.id
        }
        var result: [LibraryDay] = []
        var currentDay: Date?
        var bucket: [LocalFile] = []
        for file in all {
            let day = calendar.startOfDay(for: file.modified)
            if day != currentDay {
                if let currentDay, !bucket.isEmpty {
                    result.append(LibraryDay(day: currentDay, files: bucket))
                }
                currentDay = day
                bucket = []
            }
            bucket.append(file)
        }
        if let currentDay, !bucket.isEmpty {
            result.append(LibraryDay(day: currentDay, files: bucket))
        }
        return result
    }
}

@MainActor
@Observable
final class LibraryViewModel {
    /// nil shows every camera together.
    var cameraFilter: CameraModel?
    /// nil shows every kind of file.
    var kindFilter: FileKind?
    var snapshot = LibrarySnapshot()
    var isLoading = false
    var isSelecting = false
    var selection: Set<String> = []
    var message: String?
    var isExporting = false
    private(set) var days: [LibraryDay] = []
    private let store: LibraryStore

    init(store: LibraryStore = .shared) {
        self.store = store
    }

    var files: [LocalFile] { days.flatMap(\.files) }
    var totalCount: Int { snapshot.files.values.reduce(0) { $0 + $1.count } }
    var selectedFiles: [LocalFile] { files.filter { selection.contains($0.id) } }
    var hasFilter: Bool { cameraFilter != nil || kindFilter != nil }

    func count(for camera: CameraModel) -> Int {
        snapshot.files[camera]?.count ?? 0
    }

    func regroup() {
        days = LibraryGrouping.days(from: snapshot, camera: cameraFilter, kind: kindFilter)
        let valid = Set(files.map(\.id))
        selection = selection.intersection(valid)
    }

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
        regroup()
        isLoading = false
    }

    func toggle(_ file: LocalFile) {
        if selection.contains(file.id) {
            selection.remove(file.id)
        } else {
            selection.insert(file.id)
        }
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
        message = failures == 0 ? "Deleted \(toDelete.count) item(s)." : "Could not delete \(failures) item(s)."
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

/// Everything that has been transferred, from all cameras, in one grid laid out like the Photos app.
struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    /// Changes whenever the FTP server receives a file, so the grid refreshes.
    var refreshToken: Date?
    /// Called by the empty state's button to jump to the Cameras tab.
    var onShowCameras: (() -> Void)?

    @State private var previewURL: URL?
    @State private var pendingDelete: [LocalFile] = []
    @State private var showDeleteConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)]

    var body: some View {
        ScrollView {
            if model.days.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 2, pinnedViews: []) {
                    ForEach(model.days) { day in
                        Section {
                            ForEach(day.files) { file in
                                cell(for: file)
                            }
                        } header: {
                            HStack {
                                Text(day.title).font(.headline)
                                Spacer()
                                Text("\(day.files.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        }
                    }
                }
                summary
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                filterMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.isSelecting ? "Cancel" : "Select") {
                    model.isSelecting.toggle()
                    if !model.isSelecting { model.selection = [] }
                }
                .disabled(model.days.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting {
                selectionBar
            } else if let message = model.message {
                Text(message)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .onTapGesture { model.message = nil }
            }
        }
        .refreshable { await model.reload() }
        .task { await model.reload() }
        .onChange(of: refreshToken) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: model.cameraFilter) { _, _ in model.regroup() }
        .onChange(of: model.kindFilter) { _, _ in model.regroup() }
        .quickLookPreview($previewURL, in: model.files.map(\.url))
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
            Text("This removes the copies stored in this app. Copies on the camera and in Photos are not affected.")
        }
    }

    // MARK: Pieces

    private func cell(for file: LocalFile) -> some View {
        LocalThumbnailCell(file: file,
                           isSelecting: model.isSelecting,
                           isSelected: model.selection.contains(file.id))
            .onTapGesture {
                if model.isSelecting {
                    model.toggle(file)
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
                    Label("Add to Photos", systemImage: "photo.badge.plus")
                }
                Button(role: .destructive) {
                    pendingDelete = [file]
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            ProgressView()
                .padding(.top, 120)
        } else if model.hasFilter && model.totalCount > 0 {
            ContentUnavailableView {
                Label("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No transferred items match this filter.")
            } actions: {
                Button("Show Everything") {
                    model.cameraFilter = nil
                    model.kindFilter = nil
                }
            }
            .padding(.top, 60)
        } else {
            ContentUnavailableView {
                Label("No Photos Yet", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Photos you import from your cameras appear here.")
            } actions: {
                if let onShowCameras {
                    Button("Import from a Camera", action: onShowCameras)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 60)
        }
    }

    private var summary: some View {
        let count = model.files.count
        let bytes = model.files.reduce(Int64(0)) { $0 + $1.size }
        return Text("\(count) item\(count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Camera", selection: $model.cameraFilter) {
                Text("All Cameras").tag(CameraModel?.none)
                ForEach(CameraModel.allCases) { camera in
                    Text("\(camera.displayName) (\(model.count(for: camera)))").tag(CameraModel?.some(camera))
                }
            }
            Picker("Kind", selection: $model.kindFilter) {
                Text("All Kinds").tag(FileKind?.none)
                Text("JPEG").tag(FileKind?.some(.jpeg))
                Text("RAW").tag(FileKind?.some(.raw))
                Text("Video").tag(FileKind?.some(.video))
            }
        } label: {
            Image(systemName: model.hasFilter
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) items?"
    }

    private var selectionBar: some View {
        let selected = model.selectedFiles
        return VStack(spacing: 8) {
            HStack {
                Text(selected.isEmpty ? "Select Items" : "\(selected.count) Selected")
                    .font(.subheadline.bold())
                Spacer()
                Button(selected.count == model.files.count ? "Deselect All" : "Select All") {
                    if selected.count == model.files.count {
                        model.selection = []
                    } else {
                        model.selection = Set(model.files.map(\.id))
                    }
                }
                .font(.subheadline)
            }
            HStack {
                ShareLink(items: selected.map(\.url)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(selected.isEmpty)
                .accessibilityLabel("Share")
                Spacer()
                Button {
                    Task { await model.exportToPhotos(selected) }
                } label: {
                    Label("Add to Photos", systemImage: "photo.badge.plus")
                }
                .disabled(selected.isEmpty || model.isExporting)
                Spacer()
                Button(role: .destructive) {
                    pendingDelete = selected
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selected.isEmpty)
                .accessibilityLabel("Delete")
            }
            .font(.title3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
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
                if file.kind != .jpeg {
                    Text(file.kind == .other ? file.url.pathExtension.uppercased() : file.kind.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay {
                if isSelected {
                    Color.white.opacity(0.3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.clear)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(file.name), \(file.kind.label)")
            .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
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
