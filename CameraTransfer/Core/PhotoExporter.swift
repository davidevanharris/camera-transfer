import Foundation
import Photos

enum PhotoExportError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Adding to Photos is not allowed. You can enable \"Add Photos Only\" for Camera Transfer in Settings > Privacy & Security > Photos."
        }
    }
}

struct PhotoExportResult: Sendable {
    var added: Int = 0
    var failures: [String] = []
}

/// Adds files to the Photos library using *add-only* access.
/// No API that requires read access to the library is ever called.
enum PhotoExporter {

    struct ExportItem: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case photo, video }
        let primary: URL
        let kind: Kind
        /// A RAW file paired with a JPEG of the same name, added as the alternate resource.
        let alternateRAW: URL?
    }

    static func requestAddOnlyAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        @unknown default:
            return false
        }
    }

    /// Groups JPEG + RAW files with the same base name into one asset.
    static func makeItems(from urls: [URL]) -> [ExportItem] {
        var items: [ExportItem] = []
        var consumed: Set<URL> = []
        let photoLikeOther: Set<String> = ["heic", "heif", "png", "tif", "tiff"]

        func key(_ url: URL) -> String {
            url.deletingPathExtension().path.lowercased()
        }

        let rawByKey: [String: URL] = Dictionary(
            urls.filter { FileKind.classify(filename: $0.lastPathComponent) == .raw }.map { (key($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for url in urls where !consumed.contains(url) {
            let kind = FileKind.classify(filename: url.lastPathComponent)
            switch kind {
            case .jpeg:
                let raw = rawByKey[key(url)]
                if let raw { consumed.insert(raw) }
                consumed.insert(url)
                items.append(ExportItem(primary: url, kind: .photo, alternateRAW: raw))
            case .raw:
                // Added on its own only if no JPEG twin exists in the selection.
                let hasJPEGTwin = urls.contains {
                    FileKind.classify(filename: $0.lastPathComponent) == .jpeg && key($0) == key(url)
                }
                if !hasJPEGTwin {
                    consumed.insert(url)
                    items.append(ExportItem(primary: url, kind: .photo, alternateRAW: nil))
                }
            case .video:
                consumed.insert(url)
                items.append(ExportItem(primary: url, kind: .video, alternateRAW: nil))
            case .other:
                if photoLikeOther.contains(url.pathExtension.lowercased()) {
                    consumed.insert(url)
                    items.append(ExportItem(primary: url, kind: .photo, alternateRAW: nil))
                }
            }
        }
        return items
    }

    static func export(_ urls: [URL]) async throws -> PhotoExportResult {
        guard await requestAddOnlyAccess() else {
            throw PhotoExportError.accessDenied
        }
        var result = PhotoExportResult()
        for item in makeItems(from: urls) {
            do {
                try await add(item)
                result.added += 1
            } catch {
                result.failures.append("\(item.primary.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func add(_ item: ExportItem) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            switch item.kind {
            case .photo:
                request.addResource(with: .photo, fileURL: item.primary, options: options)
                if let raw = item.alternateRAW {
                    let rawOptions = PHAssetResourceCreationOptions()
                    rawOptions.shouldMoveFile = false
                    request.addResource(with: .alternatePhoto, fileURL: raw, options: rawOptions)
                }
            case .video:
                request.addResource(with: .video, fileURL: item.primary, options: options)
            }
        }
    }
}
