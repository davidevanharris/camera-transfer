import Foundation
import ImageIO
import AVFoundation
import CoreGraphics

/// Thumbnail creation with ImageIO. ImageIO uses the embedded JPEG previews in DNG / ARW / ORF files.
enum ThumbnailGenerator {

    private static func options(maxPixelSize: Int) -> CFDictionary {
        let dictionary: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return dictionary as CFDictionary
    }

    static func imageThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixelSize: maxPixelSize))
    }

    static func imageThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixelSize: maxPixelSize))
    }

    static func videoThumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        do {
            let (image, _) = try await generator.image(at: .zero)
            return image
        } catch {
            return nil
        }
    }
}
