import Foundation

/// Broad category of a camera file, decided purely from its file extension.
enum FileKind: String, Codable, Sendable, CaseIterable {
    case jpeg
    case raw
    case video
    case other

    static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    static let rawExtensions: Set<String> = ["dng", "arw", "orf", "ori"]
    static let videoExtensions: Set<String> = ["mov", "mp4"]

    static func classify(filename: String) -> FileKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if jpegExtensions.contains(ext) { return .jpeg }
        if rawExtensions.contains(ext) { return .raw }
        if videoExtensions.contains(ext) { return .video }
        return .other
    }

    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .raw: return "RAW"
        case .video: return "Video"
        case .other: return "File"
        }
    }

    var systemImage: String {
        switch self {
        case .jpeg: return "photo"
        case .raw: return "camera.aperture"
        case .video: return "video"
        case .other: return "doc"
        }
    }
}

/// A file that lives on the camera's memory card.
struct RemotePhoto: Identifiable, Hashable, Codable, Sendable {
    /// Stable identifier: "[<storage>/]<folder>/<filename>".
    let id: String
    /// Folder on the camera, e.g. "100RICOH" (Ricoh) or "/DCIM/100OMSYS" (OM System).
    let folder: String
    let filename: String
    let size: Int64?
    let date: Date?
    let kind: FileKind
    /// Ricoh storage name ("in" = internal memory, "sd1" = SD card); nil when the camera has one storage.
    let storage: String?

    init(folder: String, filename: String, size: Int64? = nil, date: Date? = nil, storage: String? = nil) {
        self.folder = folder
        self.filename = filename
        self.size = size
        self.date = date
        self.storage = storage
        self.kind = FileKind.classify(filename: filename)
        let path: String
        if folder.isEmpty {
            path = filename
        } else if folder.hasSuffix("/") {
            path = folder + filename
        } else {
            path = folder + "/" + filename
        }
        if let storage, !storage.isEmpty {
            self.id = storage + (path.hasPrefix("/") ? "" : "/") + path
        } else {
            self.id = path
        }
    }

    /// Path on the camera without the storage prefix.
    var cameraPath: String {
        if folder.isEmpty { return filename }
        return folder.hasSuffix("/") ? folder + filename : folder + "/" + filename
    }
}

/// The three supported cameras.
enum CameraModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case ricoh
    case sony
    case olympus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ricoh: return "Ricoh GR IV"
        case .sony: return "Sony A7CR"
        case .olympus: return "OM System OM-3"
        }
    }

    var shortName: String {
        switch self {
        case .ricoh: return "GR IV"
        case .sony: return "A7CR"
        case .olympus: return "OM-3"
        }
    }

    /// Folder name inside the app's Documents directory.
    var folderName: String { displayName }
}
