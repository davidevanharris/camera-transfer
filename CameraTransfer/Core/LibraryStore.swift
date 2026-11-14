import Foundation

/// A file saved in the app's Documents folder.
struct LocalFile: Identifiable, Hashable, Sendable {
    let url: URL
    let camera: CameraModel
    let size: Int64
    let modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var kind: FileKind { FileKind.classify(filename: url.lastPathComponent) }
}

/// Manages `Documents/<Camera Name>/...` and a small JSON index of already-downloaded remote IDs.
/// The index lives in Application Support so it does not clutter the Files app.
final class LibraryStore: @unchecked Sendable {
    static let shared = LibraryStore()

    let documentsURL: URL
    let indexDirectory: URL

    private let lock = NSLock()
    private var indexCache: [CameraModel: Set<String>] = [:]
    private let fileManager = FileManager.default

    init(documentsURL: URL? = nil, indexDirectory: URL? = nil) {
        let fm = FileManager.default
        let documents = documentsURL
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        self.documentsURL = documents
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.indexDirectory = indexDirectory ?? support.appendingPathComponent("DownloadIndex", isDirectory: true)
    }

    // MARK: Folders

    @discardableResult
    func folder(for camera: CameraModel) -> URL {
        let url = documentsURL.appendingPathComponent(camera.folderName, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where a remote file is saved: `Documents/<Camera>/[<storage>/]<camera folder>/<filename>`.
    func destination(for photo: RemotePhoto, camera: CameraModel) -> URL {
        let subfolder = LibraryStore.sanitize((photo.folder as NSString).lastPathComponent, fallback: "Camera")
        let name = LibraryStore.sanitize(photo.filename, fallback: "file")
        var base = folder(for: camera)
        if let storage = photo.storage, !storage.isEmpty {
            base = base.appendingPathComponent(LibraryStore.sanitize(storage, fallback: "storage"), isDirectory: true)
        }
        return base
            .appendingPathComponent(subfolder, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    static func sanitize(_ component: String, fallback: String) -> String {
        var value = (component as NSString).lastPathComponent
        value = value.replacingOccurrences(of: ":", with: "_")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") {
            value.removeFirst()
        }
        if value.isEmpty || value == "/" { return fallback }
        return value
    }

    // MARK: Download index

    private func indexURL(for camera: CameraModel) -> URL {
        indexDirectory.appendingPathComponent("\(camera.rawValue).json")
    }

    func downloadedIDs(for camera: CameraModel) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return loadIndexLocked(camera)
    }

    func markDownloaded(_ id: String, camera: CameraModel) {
        lock.lock()
        defer { lock.unlock() }
        var ids = loadIndexLocked(camera)
        guard !ids.contains(id) else { return }
        ids.insert(id)
        indexCache[camera] = ids
        saveIndexLocked(ids, camera: camera)
    }

    func resetIndex(for camera: CameraModel) {
        lock.lock()
        defer { lock.unlock() }
        indexCache[camera] = []
        try? fileManager.removeItem(at: indexURL(for: camera))
    }

    private func loadIndexLocked(_ camera: CameraModel) -> Set<String> {
        if let cached = indexCache[camera] { return cached }
        var ids: Set<String> = []
        if let data = try? Data(contentsOf: indexURL(for: camera)),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            ids = Set(list)
        }
        indexCache[camera] = ids
        return ids
    }

    private func saveIndexLocked(_ ids: Set<String>, camera: CameraModel) {
        do {
            try fileManager.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ids.sorted())
            try data.write(to: indexURL(for: camera), options: .atomic)
        } catch {
            // The index is a convenience; failing to save it only means files may be offered again.
        }
    }

    // MARK: Auto-transfer baseline
    // Remote IDs that already existed when auto-transfer was armed. Auto-transfer never imports these.

    private func baselineURL(for camera: CameraModel) -> URL {
        indexDirectory.appendingPathComponent("baseline-\(camera.rawValue).json")
    }

    /// nil = no baseline recorded yet since auto-transfer was armed.
    func baselineIDs(for camera: CameraModel) -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: baselineURL(for: camera)),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(list)
    }

    func setBaseline(_ ids: Set<String>, for camera: CameraModel) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(ids.sorted()).write(to: baselineURL(for: camera), options: .atomic)
        } catch {
            // Without a baseline the next poll records one again; nothing old is imported meanwhile.
        }
    }

    func clearBaselines() {
        lock.lock()
        defer { lock.unlock() }
        for camera in CameraModel.allCases {
            try? fileManager.removeItem(at: baselineURL(for: camera))
        }
    }

    // MARK: Local files

    func files(for camera: CameraModel) -> [LocalFile] {
        let root = folder(for: camera)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var result: [LocalFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            if url.pathExtension.lowercased() == "part" { continue }
            result.append(LocalFile(url: url,
                                    camera: camera,
                                    size: Int64(values.fileSize ?? 0),
                                    modified: values.contentModificationDate ?? Date.distantPast))
        }
        return result.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.name > rhs.name
        }
    }

    func delete(_ file: LocalFile) throws {
        // Only ever delete inside Documents.
        let path = file.url.standardizedFileURL.path
        let rootPath = documentsURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return }
        try fileManager.removeItem(at: file.url)
    }

    /// Deletes a single file, but only inside Documents.
    func deleteFile(at url: URL) throws {
        let path = url.standardizedFileURL.path
        let rootPath = documentsURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return }
        try fileManager.removeItem(at: url)
    }

    func totalSize(for camera: CameraModel) -> Int64 {
        files(for: camera).reduce(0) { $0 + $1.size }
    }

    func totalSize() -> Int64 {
        CameraModel.allCases.reduce(0) { $0 + totalSize(for: $1) }
    }
}
