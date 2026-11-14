import Foundation

/// Client for the OI.Share-style HTTP API of Olympus / OM System cameras
/// (documented for E-M / OM-1 bodies; assumed for the OM-3).
final class OlympusClient: CameraClient, @unchecked Sendable {
    static let defaultBaseURL = "http://192.168.0.10"
    /// The cameras reject requests that do not carry the OI.Share user agent.
    static let userAgent = "OI.Share v2"
    private static let maxDepth = 4

    private let http: CameraHTTP

    init(baseURL: URL) {
        self.http = CameraHTTP(baseURL: baseURL, headers: ["User-Agent": OlympusClient.userAgent])
    }

    var baseURL: URL { http.baseURL }

    func waitUntilReachable(timeout: TimeInterval) async throws {
        try await http.waitUntilReachable(path: "/get_caminfo.cgi", timeout: timeout)
    }

    /// The OI.Share API exposes no battery level that we know of, so the battery stays unknown.
    func ping() async throws -> String {
        let data = try await http.get(try http.url(path: "/get_caminfo.cgi"))
        return OlympusParser.parseModel(fromCamInfo: data) ?? "OM System camera"
    }

    func listPhotos() async throws -> [RemotePhoto] {
        do {
            _ = try await http.get(try http.url(path: "/switch_cammode.cgi",
                                                 query: [URLQueryItem(name: "mode", value: "play")]))
        } catch CameraError.httpStatus(_, _) {
            // Some bodies answer with an error if they are already in play mode; carry on.
        }
        return try await listDirectory("/DCIM", depth: 0)
    }

    private func listDirectory(_ directory: String, depth: Int) async throws -> [RemotePhoto] {
        let data: Data
        do {
            data = try await http.get(try http.url(path: "/get_imglist.cgi",
                                                    query: [URLQueryItem(name: "DIR", value: directory)]))
        } catch CameraError.httpStatus(let code, _) where code == 404 {
            // Empty directories answer 404.
            return []
        }
        let entries = OlympusParser.parseImageList(String(decoding: data, as: UTF8.self))
        var photos: [RemotePhoto] = []
        for entry in entries {
            try Task.checkCancellation()
            if entry.isDirectory {
                if depth < OlympusClient.maxDepth {
                    photos.append(contentsOf: try await listDirectory(entry.path, depth: depth + 1))
                }
            } else {
                photos.append(OlympusParser.photo(from: entry))
            }
        }
        return photos
    }

    func thumbnailData(for photo: RemotePhoto) async throws -> Data {
        let url = try http.url(path: "/get_thumbnail.cgi", query: [URLQueryItem(name: "DIR", value: photo.id)])
        return try await http.get(url)
    }

    func download(_ photo: RemotePhoto, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = try http.url(path: photo.id)
        try await http.download(from: url, to: destination, expectedSize: photo.size, progress: progress)
    }
}
