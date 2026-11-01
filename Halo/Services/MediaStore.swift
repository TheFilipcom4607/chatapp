import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Stores attachments and generated media on disk (Application Support/Media).
enum MediaStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for item: MediaItem) -> URL { directory.appendingPathComponent(item.filename) }
    static func url(filename: String) -> URL { directory.appendingPathComponent(filename) }

    static func save(_ data: Data, kind: MediaItem.Kind, mimeType: String, ext: String,
                     originalName: String? = nil, prompt: String? = nil, model: String? = nil) throws -> MediaItem {
        let id = UUID().uuidString
        let filename = "\(id).\(ext)"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        var item = MediaItem(id: id, kind: kind, filename: filename, mimeType: mimeType, originalName: originalName, prompt: prompt, model: model)
        if kind == .image, let img = PlatformImage(data: data) {
            item.width = Double(img.size.width * img.scale)
            item.height = Double(img.size.height * img.scale)
        }
        return item
    }

    static func data(for item: MediaItem) -> Data? { try? Data(contentsOf: url(for: item)) }

    static func image(for item: MediaItem) -> PlatformImage? {
        guard item.kind == .image else { return nil }
        return ImageCache.shared.image(for: url(for: item))
    }

    static func dataURL(for item: MediaItem) -> String? {
        guard let data = data(for: item) else { return nil }
        return "data:\(item.mimeType);base64,\(data.base64EncodedString())"
    }

    static func delete(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: url(for: item))
    }

    static func ext(forMime mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/svg+xml": return "svg"
        case "audio/mpeg": return "mp3"
        case "video/mp4": return "mp4"
        case "application/pdf": return "pdf"
        default: return "bin"
        }
    }
}

/// Small in-memory image cache so chat scrolling stays smooth.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, PlatformImage>()

    func image(for url: URL) -> PlatformImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        guard let data = try? Data(contentsOf: url), let img = PlatformImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

enum ImageDownscaler {
    /// Resizes to fit `maxDimension` and re-encodes as JPEG for upload.
    static func jpegData(from image: PlatformImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        #if canImport(UIKit)
        let size = image.size
        #else
        // AppKit sizes are in points; a Retina screenshot is twice that in pixels.
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        #endif
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        #else
        guard let cg = image.cgImage else { return nil }
        let resized = PlatformImage.render(size: target) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(origin: .zero, size: target))
        }
        #endif
        return resized.jpegData(compressionQuality: quality)
    }
}
