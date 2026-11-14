import Foundation

/// Client for the Ricoh GR HTTP API (/v1). Reported to exist on the GR IV (firmware 1.11):
/// /v1/ping, /v1/props, /v1/photos, /v1/photos/{dir}/{file}[?size=thumb|view]; no auth, plain HTTP.
/// The camera's Wi-Fi must first be started over Bluetooth (see RicohBLE).
final class RicohClient: CameraClient, @unchecked Sendable {
    static let defaultBaseURL = "http://192.168.0.1"

    private let http: CameraHTTP

    init(baseURL: URL) {
        self.http = CameraHTTP(baseURL: baseURL)
    }

    var baseURL: URL { http.baseURL }

    func waitUntilReachable(timeout: TimeInterval) async throws {
        try await http.waitUntilReachable(path: "/v1/ping", timeout: timeout)
    }

    func ping() async throws -> String {
        try await deviceInfo().model
    }

    func deviceInfo() async throws -> CameraDeviceInfo {
        let data = try await http.get(try http.url(path: "/v1/props"))
        return RicohParser.parseDeviceInfo(fromProps: data) ?? CameraDeviceInfo(model: "Ricoh camera")
    }

    /// Lists every equipped storage ("in" internal memory, "sd1" SD card) with `?storageId=`.
    /// Falls back to plain `/v1/photos` when /v1/props has no `storages` array.
    func listPhotos() async throws -> [RemotePhoto] {
        let info = try await deviceInfo()
        if info.storages.isEmpty {
            let data = try await http.get(try http.url(path: "/v1/photos"))
            return try RicohParser.parsePhotoList(data)
        }
        var photos: [RemotePhoto] = []
        for storage in info.storages where storage.equipped {
            try Task.checkCancellation()
            let url = try http.url(path: "/v1/photos", query: [URLQueryItem(name: "storageId", value: storage.name)])
            let data = try await http.get(url)
            photos.append(contentsOf: try RicohParser.parsePhotoList(data, storage: storage.name))
        }
        return photos
    }

    func thumbnailData(for photo: RemotePhoto) async throws -> Data {
        for size in ["thumb", "view"] {
            do {
                let data = try await getWithStorageFallback(photo, extraQuery: [URLQueryItem(name: "size", value: size)])
                if !data.isEmpty { return data }
            } catch {
                if Task.isCancelled { throw error }
                if size == "view" { throw error }
                // Fall through to the larger "view" size.
            }
        }
        throw CameraError.badResponse("no thumbnail")
    }

    func download(_ photo: RemotePhoto, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await http.download(from: try fileURL(photo, includeStorage: true, extraQuery: []),
                                    to: destination, expectedSize: photo.size, progress: progress)
        } catch CameraError.httpStatus(let code, _) where code == 404 && photo.storage != nil {
            // ASSUMPTION: file URLs accept ?storageId=<name>. If the camera rejects it, retry without.
            try await http.download(from: try fileURL(photo, includeStorage: false, extraQuery: []),
                                    to: destination, expectedSize: photo.size, progress: progress)
        }
    }

    /// Ends the camera's Wi-Fi session (best effort; errors ignored).
    func finishSession() async {
        if let url = try? http.url(path: "/v1/device/wlan/finish") {
            _ = try? await http.get(url)
        }
    }

    // MARK: Helpers

    private func getWithStorageFallback(_ photo: RemotePhoto, extraQuery: [URLQueryItem]) async throws -> Data {
        do {
            return try await http.get(try fileURL(photo, includeStorage: true, extraQuery: extraQuery))
        } catch CameraError.httpStatus(let code, _) where code == 404 && photo.storage != nil {
            return try await http.get(try fileURL(photo, includeStorage: false, extraQuery: extraQuery))
        }
    }

    private func fileURL(_ photo: RemotePhoto, includeStorage: Bool, extraQuery: [URLQueryItem]) throws -> URL {
        var query = extraQuery
        if includeStorage, let storage = photo.storage {
            // ASSUMPTION (unconfirmed): the storage is selected with the same query parameter as the listing.
            query.append(URLQueryItem(name: "storageId", value: storage))
        }
        return try http.url(path: "/v1/photos/\(photo.folder)/\(photo.filename)", query: query)
    }
}
