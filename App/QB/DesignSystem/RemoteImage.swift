import SwiftUI
import UIKit
import ImageIO

/// تحميل الصور: كاش بالذاكرة + كاش على القرص (URLCache)، وتصغير الصورة قبل عرضها
/// عشان التمرير يكون ناعم وما تاكل الذاكرة.
nonisolated final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        memory.countLimit = 400
        memory.totalCostLimit = 120 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(Int(maxPixel))|\(url.absoluteString)" as NSString
    }

    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        memory.object(forKey: key(url, maxPixel))
    }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            ImagePipeline.downsample(data, maxPixel: maxPixel)
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key(url, maxPixel), cost: cost)
        }
        return image
    }

    /// بيانات خام (للويدجت)
    func data(for url: URL) async -> Data? {
        try? await session.data(from: url).0
    }

    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    func clearMemory() { memory.removeAllObjects() }

    func clearDisk() { session.configuration.urlCache?.removeAllCachedResponses() }

    var diskUsage: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }
}

/// صورة من النت مع ظهور ناعم وهيكل تحميل
struct RemoteImage: View {
    let url: String?
    var maxPixel: CGFloat = 420
    var contentMode: ContentMode = .fill
    var placeholderSymbol: String? = "film"

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                // الشعارات (بدون رمز بديل) خلفيتها شفافة
                (placeholderSymbol == nil ? Color.clear : Palette.surface)
                if failed, let placeholderSymbol {
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, let u = URL(string: url) else {
            image = nil
            failed = true
            return
        }
        if let hit = ImagePipeline.shared.cached(u, maxPixel: maxPixel) {
            image = hit
            return
        }
        image = nil
        failed = false
        let loaded = await ImagePipeline.shared.image(for: u, maxPixel: maxPixel)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            image = loaded
            failed = loaded == nil
        }
    }
}
