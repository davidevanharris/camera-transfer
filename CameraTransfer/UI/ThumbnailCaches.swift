import SwiftUI
import UIKit

/// Lets a decoded CGImage cross from a background task back to the main actor.
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

/// Loads camera thumbnails with limited concurrency (cameras dislike many parallel requests)
/// and caches them in memory. Most recently requested thumbnails are served first.
@MainActor
final class RemoteThumbnailLoader {
    private let cache = NSCache<NSString, UIImage>()
    private var client: CameraClient?
    private var active = 0
    private let maxConcurrent = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// While paused (for example during downloads) no new thumbnail requests are sent.
    var isPaused = false {
        didSet {
            if !isPaused { pump() }
        }
    }

    init() {
        cache.countLimit = 600
    }

    func reset(client: CameraClient?) {
        self.client = client
        cache.removeAllObjects()
    }

    func cachedImage(for photo: RemotePhoto) -> UIImage? {
        cache.object(forKey: photo.id as NSString)
    }

    func image(for photo: RemotePhoto) async -> UIImage? {
        if let cached = cachedImage(for: photo) { return cached }
        await acquire()
        defer { release() }
        if Task.isCancelled { return nil }
        if let cached = cachedImage(for: photo) { return cached }
        guard let client else { return nil }
        guard let data = try? await client.thumbnailData(for: photo), !data.isEmpty else { return nil }
        let decoded: CGImage? = await Task.detached(priority: .utility) {
            SendableCGImage(ThumbnailGenerator.imageThumbnail(from: data, maxPixelSize: 320))
        }.value.image
        let image: UIImage?
        if let decoded {
            image = UIImage(cgImage: decoded)
        } else {
            image = UIImage(data: data)
        }
        if let image {
            cache.setObject(image, forKey: photo.id as NSString)
        }
        return image
    }

    private func acquire() async {
        if active < maxConcurrent && !isPaused {
            active += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // The slot was handed over by pump(), which already incremented `active`.
    }

    private func release() {
        active -= 1
        pump()
    }

    private func pump() {
        while !isPaused && active < maxConcurrent && !waiters.isEmpty {
            let next = waiters.removeLast()
            active += 1
            next.resume()
        }
    }
}

/// Thumbnails for files already saved on the phone.
final class LocalThumbnailCache: @unchecked Sendable {
    static let shared = LocalThumbnailCache()

    private let cache = NSCache<NSURL, UIImage>()

    init() {
        cache.countLimit = 800
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func thumbnail(for file: LocalFile) async -> UIImage? {
        if let cached = cachedImage(for: file.url) { return cached }
        let url = file.url
        let cgImage: CGImage?
        if file.kind == .video {
            cgImage = await ThumbnailGenerator.videoThumbnail(at: url, maxPixelSize: 320)
        } else {
            cgImage = await Task.detached(priority: .utility) {
                SendableCGImage(ThumbnailGenerator.imageThumbnail(at: url, maxPixelSize: 320))
            }.value.image
        }
        guard let cgImage else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}
