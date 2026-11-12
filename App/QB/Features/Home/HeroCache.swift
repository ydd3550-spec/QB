import SwiftUI
import UIKit
import QBCore

/// آخر عمل بالبانر وصورته محفوظين على الجهاز: يطلعون أول ما يفتح التطبيق، قبل ما توصل الرفوف
nonisolated enum HeroCache {
    static let pixel: CGFloat = 1400

    /// يُقرأ من القرص مرة وحدة بس عند فتح التطبيق
    static let atLaunch: MetaPreview? = loadAndWarm()

    private struct Stored: Codable {
        var id, kind, name: String
        var poster, background, logo, description, releaseInfo, imdbRating: String?
        var genres: [String]
        var addon: String
    }

    private static var dir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
    private static var jsonURL: URL? { dir?.appendingPathComponent("qb-hero.json") }
    private static var imageURL: URL? { dir?.appendingPathComponent("qb-hero.jpg") }

    /// يقرأ البانر المحفوظ ويحط صورته بكاش الذاكرة عشان تطلع بدون انتظار
    static func loadAndWarm() -> MetaPreview? {
        guard let jsonURL, let data = try? Data(contentsOf: jsonURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data),
              let kind = MediaKind(wire: s.kind) else { return nil }
        let item = MetaPreview(id: s.id, kind: kind, name: s.name, poster: s.poster, background: s.background, logo: s.logo,
                               description: s.description, releaseInfo: s.releaseInfo, imdbRating: s.imdbRating,
                               genres: s.genres, addon: s.addon)
        if let raw = item.background ?? item.poster, let url = URL(string: raw),
           ImagePipeline.shared.cached(url, maxPixel: pixel) == nil,
           let imageURL, let jpg = try? Data(contentsOf: imageURL), let image = UIImage(data: jpg) {
            ImagePipeline.shared.store(image, for: url, maxPixel: pixel)
        }
        return item
    }

    /// يحفظ البانر الجديد وصورته (بالخلفية) للمرة الجاية
    static func save(_ m: MetaPreview) {
        let s = Stored(id: m.id, kind: m.kind.wire, name: m.name, poster: m.poster, background: m.background, logo: m.logo,
                       description: m.description, releaseInfo: m.releaseInfo, imdbRating: m.imdbRating,
                       genres: m.genres, addon: m.addon)
        let raw = m.background ?? m.poster
        Task.detached(priority: .utility) {
            guard let jsonURL, let imageURL else { return }
            if let raw, let url = URL(string: raw),
               let image = await ImagePipeline.shared.image(for: url, maxPixel: pixel),
               let jpg = image.jpegData(compressionQuality: 0.85) {
                try? jpg.write(to: imageURL, options: .atomic)
            }
            if let data = try? JSONEncoder().encode(s) {
                try? data.write(to: jsonURL, options: .atomic)
            }
        }
    }

    /// نسخة أصغر من نفس الصورة تنزل أسرع (لو الموقع يوفّرها)
    static func previewURL(for raw: String) -> String? {
        if raw.contains("image.tmdb.org/t/p/original/") { return raw.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/") }
        if raw.contains("image.tmdb.org/t/p/w1280/") { return raw.replacingOccurrences(of: "/t/p/w1280/", with: "/t/p/w780/") }
        if raw.contains("/background/medium/") { return raw.replacingOccurrences(of: "/background/medium/", with: "/background/small/") }
        if raw.contains("/background/large/") { return raw.replacingOccurrences(of: "/background/large/", with: "/background/small/") }
        return nil
    }
}

/// صورة البانر: لو محفوظة تطلع على طول، وإلا نسخة صغيرة سريعة أول وبعدين الكاملة بتلاشي ناعم
struct HeroImage: View {
    let url: String?

    @State private var image: UIImage?
    @State private var sharp = false

    var body: some View {
        ZStack {
            // اللمعة تنشال كليًا لما تطلع الصورة (ما تظل شغّالة بالخلفية)
            if image == nil {
                HeroShimmer().transition(.opacity)
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                    .id(sharp)
            }
        }
        .animation(.smooth(duration: 0.45), value: image == nil)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, let full = URL(string: url) else { return }
        if let hit = ImagePipeline.shared.cached(full, maxPixel: HeroCache.pixel) {
            image = hit
            sharp = true
            return
        }
        // الصغيرة والكاملة بنفس الوقت
        async let big = ImagePipeline.shared.image(for: full, maxPixel: HeroCache.pixel)
        if let p = HeroCache.previewURL(for: url), let pu = URL(string: p),
           let small = await ImagePipeline.shared.image(for: pu, maxPixel: 700), image == nil {
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.35)) { image = small }
        }
        if let loaded = await big {
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.45)) {
                image = loaded
                sharp = true
            }
        }
    }
}

/// مكان البانر وقت التحميل: زجاج داكن بلمعة تمشي، بدل مربع رمادي
struct HeroShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Palette.surfaceRaised, Palette.surface, Palette.background],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Palette.accent.opacity(0.10), .clear], center: .topTrailing, startRadius: 10, endRadius: geo.size.width)
                LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.6)
                    .rotationEffect(.degrees(12))
                    .offset(x: phase * geo.size.width * 1.2)
            }
            .clipped()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// بانر التحميل كامل: اللمعة + مكان العنوان والأزرار
struct HeroPlaceholder: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroShimmer()
                .overlay(alignment: .bottom) { Palette.scrim.frame(height: 300) }
            VStack(alignment: .leading, spacing: 12) {
                Capsule().fill(.white.opacity(0.10)).frame(width: 210, height: 30)
                Capsule().fill(.white.opacity(0.07)).frame(width: 140, height: 12)
                Capsule().fill(.white.opacity(0.06)).frame(width: 260, height: 12)
                HStack(spacing: 10) {
                    Capsule().fill(.clear).frame(width: 170, height: 48)
                        .glassEffect(.regular, in: .capsule)
                    Circle().fill(.clear).frame(width: 48, height: 48)
                        .glassEffect(.regular, in: .circle)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
        .frame(height: 540)
        .accessibilityHidden(true)
    }
}
