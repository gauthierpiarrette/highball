import AppKit
import Foundation

/// Decoded images survive thumbnail/full-image view changes; URLCache also persists HTTP data.
/// Both caches are bounded so browsing galleries does not retain an entire library in memory.
@MainActor
final class CachedGalleryImageLoader {
    static let shared = CachedGalleryImageLoader()
    private let images = NSCache<NSURL, NSImage>()
    private var pending: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        images.totalCostLimit = 64 * 1024 * 1024
        images.countLimit = 40
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024,
                                          diskPath: "HighballGallery")
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func image(at url: URL) async -> NSImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        if let task = pending[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 15 * 1024 * 1024, let image = NSImage(data: data) else { return nil }
            let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? data.count
            images.setObject(image, forKey: url as NSURL, cost: pixels)
            return image
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil
        return image
    }
}
