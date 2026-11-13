import SwiftUI
import UIKit
import QBCore

/// بانر الرئيسية: العمل المعروض وصورته محفوظين على الجهاز، والعمل اللي بيطلع بالفتحة الجاية (مختار مسبقًا
/// وصورته جاهزة على القرص)، فكل فتحة للتطبيق تطلع بعمل جديد من أول إطار بدون تبديل قدامك
nonisolated enum HeroCache {
    static let pixel: CGFloat = 1400

    /// يُقرأ من القرص مرة وحدة بس عند فتح التطبيق
    private static let launch: (item: MetaPreview?, lastID: String?, fresh: Bool) = loadAndWarm()

    /// اللي ينعرض أول ما يفتح التطبيق: المختار للفتحة هذي لو موجود، وإلا آخر واحد انعرض
    static var atLaunch: MetaPreview? { launch.item }
    /// آخر عمل انعرض بالجلسة اللي قبل (عشان ما يتكرر)
    static var lastShownID: String? { launch.lastID }
    /// اللي انعرض أول الفتحة جديد (مختار مسبقًا ومو نفس آخر واحد)
    static var launchIsFresh: Bool { launch.fresh }

    /// رفوف الرئيسية بهالجلسة: لو انبنت الرئيسية من جديد ترجع بنفس الرفوف فورًا بدون تحميل ولا ظهور من جديد
    @MainActor static var sessionRows: [CatalogRow] = []
    @MainActor static var sessionVersion = -1

    /// البانر المعروض بهالجلسة (بالذاكرة): لو انبنت الرئيسية من جديد (رجوع من البحث وغيره) ترجع بنفسه
    /// ونفس الصورة من أول إطار. ما يتغير إلا مع فتحة جديدة أو السحب للتحديث أو رجوع للتطبيق بعد فترة
    @MainActor static var current: MetaPreview?
    /// متى راح التطبيق للخلفية
    @MainActor static var backgroundedAt: Date?
    /// كم لازم يقعد بالخلفية عشان يتغير البانر لما ترجع
    static let rotateAfter: TimeInterval = 10 * 60

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
    private static var nextJSONURL: URL? { dir?.appendingPathComponent("qb-hero-next.json") }
    private static var nextImageURL: URL? { dir?.appendingPathComponent("qb-hero-next.jpg") }

    private static func read(_ json: URL?) -> MetaPreview? {
        guard let json, let data = try? Data(contentsOf: json),
              let s = try? JSONDecoder().decode(Stored.self, from: data),
              let kind = MediaKind(wire: s.kind) else { return nil }
        return MetaPreview(id: s.id, kind: kind, name: s.name, poster: s.poster, background: s.background, logo: s.logo,
                           description: s.description, releaseInfo: s.releaseInfo, imdbRating: s.imdbRating,
                           genres: s.genres, addon: s.addon)
    }

    /// يحط صورة القرص بكاش الذاكرة (ويثبّتها) عشان تطلع بدون انتظار
    private static func warm(_ item: MetaPreview, from file: URL?) -> Bool {
        guard let raw = item.background ?? item.poster, let url = URL(string: raw) else { return false }
        if ImagePipeline.shared.cached(url, maxPixel: pixel) == nil {
            guard let file, let jpg = try? Data(contentsOf: file), let image = UIImage(data: jpg) else { return false }
            ImagePipeline.shared.store(image, for: url, maxPixel: pixel)
        }
        ImagePipeline.shared.pin(pinEntries(item))
        return true
    }

    /// يقرأ البانر ويحط صورته بالذاكرة. المختار للفتحة هذي يتقدّم لو صورته جاهزة ومو نفس آخر واحد انعرض
    private static func loadAndWarm() -> (item: MetaPreview?, lastID: String?, fresh: Bool) {
        let last = read(jsonURL)
        if let next = read(nextJSONURL), next.id != last?.id, warm(next, from: nextImageURL) {
            return (next, last?.id, true)
        }
        if let last { _ = warm(last, from: imageURL) }
        return (last, last?.id, false)
    }

    private static func stored(_ m: MetaPreview) -> Stored {
        Stored(id: m.id, kind: m.kind.wire, name: m.name, poster: m.poster, background: m.background, logo: m.logo,
               description: m.description, releaseInfo: m.releaseInfo, imdbRating: m.imdbRating,
               genres: m.genres, addon: m.addon)
    }

    /// الصور اللي تنثبّت للعمل: الخلفية الكاملة والصغيرة والشعار
    static func pinEntries(_ m: MetaPreview) -> [(URL, CGFloat)] {
        var out: [(URL, CGFloat)] = []
        if let raw = m.background ?? m.poster, let u = URL(string: raw) {
            out.append((u, pixel))
            if let p = previewURL(for: raw), let pu = URL(string: p) { out.append((pu, 700)) }
        }
        if let logo = m.logo, let u = URL(string: logo) { out.append((u, 700)) }
        return out
    }

    /// يحمّل صورة العمل (والشعار) بالذاكرة قبل ما ينعرض. يرجع true لو الخلفية جاهزة
    static func preload(_ m: MetaPreview) async -> Bool {
        guard let raw = m.background ?? m.poster, let url = URL(string: raw) else { return false }
        async let logo = loadLogo(m.logo)
        let big = await ImagePipeline.shared.image(for: url, maxPixel: pixel)
        _ = await logo
        return big != nil
    }

    private static func loadLogo(_ raw: String?) async -> UIImage? {
        guard let raw, let u = URL(string: raw) else { return nil }
        return await ImagePipeline.shared.image(for: u, maxPixel: 700)
    }

    /// يثبّت صور البانر المعروض بالذاكرة (ما تنمسح لين يتغير البانر)
    static func pin(_ m: MetaPreview) {
        ImagePipeline.shared.pin(pinEntries(m))
    }

    /// يحفظ البانر المعروض وصورته (بالخلفية): يصير "آخر واحد انعرض" وصورته للمرة الجاية
    static func save(_ m: MetaPreview) {
        write(m, json: jsonURL, image: imageURL)
    }

    /// يحفظ اللي بيطلع بالفتحة الجاية وصورته على القرص، عشان يطلع من أول إطار
    static func saveNext(_ m: MetaPreview) {
        write(m, json: nextJSONURL, image: nextImageURL)
    }

    private static func write(_ m: MetaPreview, json: URL?, image file: URL?) {
        let s = stored(m)
        let raw = m.background ?? m.poster
        let logoRaw = m.logo
        Task.detached(priority: .utility) {
            guard let json, let file else { return }
            if let raw, let url = URL(string: raw),
               let image = await ImagePipeline.shared.image(for: url, maxPixel: pixel),
               let jpg = image.jpegData(compressionQuality: 0.85) {
                try? jpg.write(to: file, options: .atomic)
            } else {
                // بدون صورة ما نحفظه (عشان ما يطلع البانر فاضي أول الفتحة)
                return
            }
            if let data = try? JSONEncoder().encode(s) {
                try? data.write(to: json, options: .atomic)
            }
            // الشعار بكاش القرص بعد
            _ = await loadLogo(logoRaw)
        }
    }

    /// الأعمال اللي ينختار منها البانر: الرائج (أول رف) اللي له خلفية عريضة، ولو قليلة نزيد من الرفوف اللي بعده
    static func pool(_ rows: [CatalogRow]) -> [MetaPreview] {
        var out: [MetaPreview] = []
        var seen = Set<String>()
        for (i, row) in rows.prefix(3).enumerated() {
            if i > 0, out.count >= 6 { break }
            for item in row.items.prefix(i == 0 ? 20 : 10) where item.background != nil && !seen.contains(item.id) {
                seen.insert(item.id)
                out.append(item)
            }
        }
        if out.isEmpty, let first = rows.first?.items.first { out = [first] }
        return out
    }

    /// اختيار عشوائي ما يكرر اللي انعرض
    static func pick(from pool: [MetaPreview], avoiding ids: Set<String>) -> MetaPreview? {
        let candidates = pool.filter { !ids.contains($0.id) }
        return candidates.randomElement() ?? pool.randomElement()
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
    /// رابط الصورة الكاملة المعروضة الحين
    @State private var shownURL: String?

    /// الصورة من الذاكرة من أول إطار: لو ننتظر .task (يشتغل بعد أول رسم) يطلع إطار وحده فيه اللمعة الفاتحة،
    /// وهذي هي الومضة البيضا لما ترجع للرئيسية من البحث
    init(url: String?) {
        self.url = url
        if let url, let full = URL(string: url),
           let hit = ImagePipeline.shared.cached(full, maxPixel: HeroCache.pixel) {
            _image = State(initialValue: hit)
            _sharp = State(initialValue: true)
            _shownURL = State(initialValue: url)
        } else if let url, let p = HeroCache.previewURL(for: url), let pu = URL(string: p),
                  let small = ImagePipeline.shared.cached(pu, maxPixel: 700) {
            _image = State(initialValue: small)
        }
    }

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
        // رجعت الرئيسية تبان والصورة الكاملة نفسها معروضة: ما نلمسها أبد (حتى لو انمسحت من الكاش)
        if image != nil, sharp, shownURL == url { return }
        if let hit = ImagePipeline.shared.cached(full, maxPixel: HeroCache.pixel) {
            // نفس الصورة معروضة: ما نلمسها (لا تلاشي ولا إعادة رسم)
            if image !== hit {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    image = hit
                    sharp = true
                }
            }
            shownURL = url
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
            shownURL = url
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
            Color.clear
                .frame(height: 540)
                .overlay {
                    // اللمعة تطول لفوق وتعبّي المسافة مثل الصورة
                    HeroShimmer()
                        .clipped()
                        .stretchesUp(height: 540)
                }
                .clipShape(SideClip())
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
