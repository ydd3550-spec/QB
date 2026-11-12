import SwiftUI
import QBCore

/// صفحة العمل: خلفية عريضة، تشغيل، المكتبة، المواسم والحلقات، المصادر مباشرة، المشابه
struct DetailsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    let ref: MediaRef

    @State private var meta: MetaDetail?
    @State private var error: String?
    /// السحب لتحت فوق الخلفية
    @State private var pull: CGFloat = 0
    @State private var loading = true
    @State private var similar: [MetaPreview] = []
    @State private var season: UInt32?
    @State private var inLibrary = false
    @State private var progress: WatchProgress?
    @State private var sources = SourcesLoader()
    @State private var episodeSheet: Video?
    @State private var report: [AddonReport] = []
    @State private var showReport = false
    @State private var expandedOverview = false
    @State private var startingPlay = false
    @Namespace private var localZoom

    private var isSeries: Bool { (meta?.kind ?? ref.kind) == .series || !(meta?.videos.isEmpty ?? true) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if let error, meta == nil {
                    EmptyStateView(title: L("ما قدرنا نفتح التفاصيل"), systemImage: "wifi.exclamationmark", message: error,
                                   actionTitle: L("إعادة المحاولة")) { Task { await load() } }
                }
                if let meta {
                    overview(meta)
                    if isSeries, !meta.videos.isEmpty {
                        episodes(meta)
                    } else {
                        sourcesSection(title: L("المصادر"))
                    }
                    castSection(meta)
                    if !similar.isEmpty {
                        similarShelf
                    }
                    linksSection(meta)
                } else if loading {
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(cornerRadius: 6).frame(height: 16)
                        SkeletonBlock(cornerRadius: 6).frame(height: 16)
                        SkeletonBlock(cornerRadius: 6).frame(width: 200, height: 16)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .trackOverscroll($pull)
        .qbScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    inLibrary = app.toggleLibrary(currentRef)
                } label: {
                    Image(systemName: inLibrary ? "bookmark.fill" : "bookmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(inLibrary ? L("شل من مكتبتي") : L("أضف لمكتبتي"))
                .sensoryFeedback(Haptics.success, trigger: inLibrary)
            }
        }
        .task { await load() }
        .onChange(of: app.libraryVersion) { _, _ in refreshLocalState() }
        .onChange(of: app.continueWatching.count) { _, _ in refreshLocalState() }
        // المشغّل فوق الصفحة مو رجوع منها: نخلّي المصادر مثل ما هي
        .onDisappear { if !app.player.isPresented { sources.cancel() } }
        .sheet(item: $episodeSheet) { video in
            EpisodeSourcesSheet(ref: currentRef, meta: meta, video: video)
                .environment(app)
                .environment(\.layoutDirection, app.language.direction)
                .environment(\.locale, app.language.locale)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $showReport) {
            AddonReportSheet(report: report)
                .environment(\.layoutDirection, app.language.direction)
                .environment(\.locale, app.language.locale)
                .presentationDetents([.medium])
        }
    }

    private var currentRef: MediaRef {
        if let meta { return MediaRef(meta) }
        return ref
    }

    // MARK: - التحميل

    private func load() async {
        guard let core = app.core else { return }
        refreshLocalState()
        // رجعت للصفحة (بعد المشغّل مثلًا): البيانات موجودة، لا نعيد تحميلها ولا نحرّكها من جديد
        if let meta, meta.id == ref.id, !loading {
            if !isSeries { sources.load(core: core, kind: meta.kind, id: meta.id) }
            return
        }
        loading = true
        error = nil
        do {
            let m = try await core.meta(kind: ref.kind, id: ref.id)
            withAnimation(Motion.standard) { meta = m }
            if season == nil { season = initialSeason(m) }
            if !isSeries {
                sources.load(core: core, kind: m.kind, id: m.id)
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = CoreClient.message(for: error)
        }
        loading = false
        async let sim = try? core.similar(kind: ref.kind, id: ref.id)
        async let rep = try? core.addonReport(kind: ref.kind, id: ref.id)
        let (s, r) = await (sim, rep)
        withAnimation(Motion.standard) { similar = s ?? [] }
        report = r ?? []
    }

    private func refreshLocalState() {
        inLibrary = app.isInLibrary(ref.id)
        progress = (try? app.core?.progress(mediaId: ref.id)) ?? nil
    }

    private func initialSeason(_ m: MetaDetail) -> UInt32? {
        if let ep = progress?.episodeId, let v = m.videos.first(where: { $0.id == ep }), let s = v.season { return s }
        let seasons = Self.seasons(m)
        return seasons.first(where: { $0 > 0 }) ?? seasons.first
    }

    static func seasons(_ m: MetaDetail) -> [UInt32] {
        Array(Set(m.videos.compactMap(\.season))).sorted()
    }

    // MARK: - الرأس

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            // الخلفية من حافة لحافة لين فوق شريط الحالة، وتتمطّط لفوق لما تسحب
            Color.clear
                .frame(height: 470)
                .overlay(alignment: .bottom) {
                    RemoteImage(url: meta?.background ?? ref.background ?? meta?.poster ?? ref.poster, maxPixel: 1400)
                        .frame(height: 470 + pull)
                        .clipped()
                        .overlay(alignment: .top) { Palette.topScrim.frame(height: 130) }
                }
                .overlay(alignment: .bottom) { Palette.scrim.frame(height: 280) }

            VStack(alignment: .leading, spacing: 12) {
                if let logo = meta?.logo {
                    RemoteImage(url: logo, maxPixel: 700, contentMode: .fit, placeholderSymbol: nil)
                        .frame(maxWidth: 250, maxHeight: 96, alignment: .leading)
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityLabel(meta?.name ?? ref.name)
                } else {
                    Text(meta?.name ?? ref.name).font(Typo.hero).lineLimit(3)
                }
                metaLine
                actionButtons
            }
            .padding(.horizontal, 20)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 10) {
            if let r = meta?.imdbRating, !r.isEmpty { RatingBadge(rating: r) }
            if let y = meta?.releaseInfo, !y.isEmpty { Text(y) }
            if let rt = meta?.runtime, !rt.isEmpty { Text(rt) }
            if let g = meta.map({ Self.uniqueGenres($0.genres).prefix(2) }), !g.isEmpty { Text(g.map { Genres.display($0, arabic: app.language == .arabic) }.joined(separator: " · ")).lineLimit(1) }
        }
        .font(Typo.caption)
        .foregroundStyle(.secondary)
    }

    private var actionButtons: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                PrimaryButton(title: playTitle, systemImage: startingPlay ? "hourglass" : "play.fill", expand: true) {
                    // ما نعطّل الزر (التعطيل يبهّت النص)، بس ما يسوي شي لين تجهز البيانات
                    guard meta != nil, !startingPlay else { return }
                    Task { await playMain() }
                }
                .sensoryFeedback(Haptics.light, trigger: startingPlay)
                if let trailer = meta?.trailerYtIds.first {
                    GlassCircleButton(systemImage: "film.stack", size: 50, label: L("الإعلان")) {
                        if let url = URL(string: "https://www.youtube.com/watch?v=\(trailer)") { openURL(url) }
                    }
                }
                if !report.isEmpty {
                    GlassCircleButton(systemImage: "chart.bar.xaxis", size: 50, label: L("تقرير الإضافات")) { showReport = true }
                }
            }
        }
        .padding(.top, 4)
    }

    private var playTitle: String {
        if startingPlay { return L("ندوّر أفضل مصدر…") }
        if let p = progress, p.positionS > 15 {
            if let ep = p.episodeId, let (s, e) = WidgetBridge.seasonEpisode(ep) {
                return L("كمّل م%@ ح%@", "\(s)", "\(e)")
            }
            return L("كمّل المشاهدة")
        }
        return L("تشغيل")
    }

    /// زر التشغيل الرئيسي: الفيلم مباشرة، والمسلسل يكمل من آخر حلقة أو أول حلقة
    private func playMain() async {
        guard let meta else { return }
        if isSeries, !meta.videos.isEmpty {
            let target: Video? = {
                if let ep = progress?.episodeId, let v = meta.videos.first(where: { $0.id == ep }) { return v }
                let sorted = meta.videos.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
                return sorted.first(where: { ($0.season ?? 0) > 0 }) ?? sorted.first
            }()
            guard let target else { return }
            startingPlay = true
            let loader = SourcesLoader()
            loader.load(core: app.core, kind: .series, id: target.id)
            let pick = await loader.waitForBest()
            startingPlay = false
            guard let pick else {
                episodeSheet = target
                return
            }
            app.player.play(pick, context: PlayContext(ref: currentRef, meta: meta, video: target, sources: loader.sources))
            return
        }
        startingPlay = true
        let pick = await sources.waitForBest()
        startingPlay = false
        guard let pick else {
            app.showToast(L("ما لقينا مصدر شغّال"))
            return
        }
        app.player.play(pick, context: PlayContext(ref: currentRef, meta: meta, video: nil, sources: sources.sources))
    }

    // MARK: - النبذة

    private func overview(_ m: MetaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = m.description, !d.isEmpty {
                Text(d)
                    .font(Typo.body)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(expandedOverview ? nil : 4)
                    .lineSpacing(3)
                    .onTapGesture { withAnimation(Motion.standard) { expandedOverview.toggle() } }
            }
            if let p = progress, let f = p.fraction, f > 0.01 {
                HStack(spacing: 10) {
                    ProgressLine(fraction: f, height: 4)
                        .environment(\.layoutDirection, .leftToRight)
                    if let left = TimeFormat.minutesLeft(position: p.positionS, duration: p.durationS) {
                        Text(L("باقي %@ د", "\(left)")).font(Typo.caption).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }
            if !m.genres.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Self.uniqueGenres(m.genres), id: \.self) { g in
                            Text(Genres.display(g, arabic: app.language == .arabic)).font(Typo.caption)
                                .padding(.horizontal, 12).frame(height: 30)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - المواسم والحلقات

    private func episodes(_ m: MetaDetail) -> some View {
        let seasons = Self.seasons(m)
        let list = m.videos.filter { $0.season == season || season == nil }
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L("الحلقات"))
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(seasons, id: \.self) { s in
                                Chip(title: s == 0 ? L("إضافات") : L("الموسم %@", "\(s)"), selected: s == season) {
                                    season = s
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .scrollIndicators(.hidden)
                .sensoryFeedback(Haptics.select, trigger: season)
            }
            LazyVStack(spacing: 12) {
                ForEach(list) { v in
                    Button {
                        episodeSheet = v
                    } label: {
                        EpisodeRow(video: v, fallbackImage: m.background ?? m.poster, current: progress?.episodeId == v.id,
                                   fraction: progress?.episodeId == v.id ? progress?.fraction : nil, locale: locale)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - المصادر

    private func sourcesSection(title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: title, subtitle: sourcesSubtitle)
                if sources.loading { ProgressView().padding(.trailing, 20) }
            }
            if sources.sources.isEmpty {
                if sources.loading {
                    VStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in SkeletonBlock().frame(height: 64) }
                    }
                    .padding(.horizontal, 20)
                } else if sources.finished {
                    EmptyStateView(title: L("ما لقينا مصادر"), systemImage: "rectangle.stack.badge.minus",
                                   message: L("ثبّت إضافات مصادر من الإعدادات ← الإضافات"),
                                   actionTitle: L("إعادة المحاولة")) { sources.reload(core: app.core, kind: ref.kind) }
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(sources.sources) { s in
                        Button {
                            guard let meta else { return }
                            app.player.play(s, context: PlayContext(ref: currentRef, meta: meta, video: nil, sources: sources.sources))
                        } label: {
                            SourceRow(source: s)
                                .padding(14)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .opacity(s.isUnreachable ? 0.5 : 1)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var sourcesSubtitle: String? {
        guard !sources.sources.isEmpty else { return nil }
        let alive = sources.sources.filter(\.isAlive).count
        return L("%@ مصدر · %@ شغّال", "\(sources.sources.count)", "\(alive)")
    }

    // MARK: - الطاقم

    @ViewBuilder
    private func castSection(_ m: MetaDetail) -> some View {
        if !m.cast.isEmpty || !m.directors.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("الطاقم"))
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(m.directors, id: \.self) { d in personChip(d, role: L("إخراج")) }
                        ForEach(m.cast.prefix(20), id: \.self) { c in personChip(c, role: nil) }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func personChip(_ name: String, role: String?) -> some View {
        HStack(spacing: 10) {
            Text(initials(name))
                .font(Typo.badge)
                .foregroundStyle(Palette.onAccent)
                .frame(width: 34, height: 34)
                .background(Palette.accent.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(Typo.caption).lineLimit(1)
                if let role { Text(role).font(Typo.badge).foregroundStyle(.secondary) }
            }
        }
        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    // MARK: - مشابه

    private var similarShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L("مشابه"))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(similar) { item in
                        NavigationLink(value: MediaRef(item, zoomID: "sim-\(ref.id)|\(item.id)")) {
                            PosterCard(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - الروابط

    @ViewBuilder
    private func linksSection(_ m: MetaDetail) -> some View {
        let links = m.links.filter { URL(string: $0.url)?.scheme?.hasPrefix("http") == true }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("روابط"))
                FlowLayout(spacing: 8) {
                    ForEach(Array(links.prefix(16).enumerated()), id: \.offset) { _, link in
                        Chip(title: link.name, systemImage: "arrow.up.forward") {
                            if let u = URL(string: link.url) { openURL(u) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                Text(L("المصدر: %@", m.addon)).font(Typo.caption).foregroundStyle(.tertiary).padding(.horizontal, 20)
            }
        }
    }
}

/// صف حلقة
struct EpisodeRow: View {
    let video: Video
    let fallbackImage: String?
    var current = false
    var fraction: Double?
    let locale: Locale

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: 140, height: 80)
                    .overlay { RemoteImage(url: video.thumbnail ?? fallbackImage, maxPixel: 420) }
                    .clipped()
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular, in: .circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let fraction {
                    ProgressLine(fraction: fraction, height: 3).environment(\.layoutDirection, .leftToRight)
                }
            }
            .frame(width: 140, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let e = video.episode {
                        Text(L("الحلقة %@", "\(e)")).font(Typo.badge).foregroundStyle(current ? Palette.accent : .secondary)
                    }
                    if let d = DateText.short(video.released, locale: locale) {
                        Text(d).font(Typo.badge).foregroundStyle(.tertiary)
                    }
                }
                Text(video.title.isEmpty ? L("الحلقة %@", "\(video.episode ?? 0)") : video.title)
                    .font(Typo.infoMedium).lineLimit(2)
                if let o = video.overview, !o.isEmpty {
                    Text(o).font(Typo.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// مصادر حلقة معيّنة
struct EpisodeSourcesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let ref: MediaRef
    let meta: MetaDetail?
    let video: Video
    @State private var loader = SourcesLoader()

    var body: some View {
        NavigationStack {
            List {
                if let best = loader.best, loader.best?.isAlive == true {
                    Section {
                        Button {
                            play(best)
                        } label: {
                            Label(L("شغّل أفضل مصدر"), systemImage: "play.fill").font(Typo.headline).foregroundStyle(Palette.accent)
                        }
                    }
                }
                Section {
                    ForEach(loader.sources) { s in
                        Button { play(s) } label: { SourceRow(source: s) }
                            .buttonStyle(.plain)
                            .opacity(s.isUnreachable ? 0.5 : 1)
                    }
                } header: {
                    HStack {
                        Text(L("المصادر"))
                        if loader.loading { ProgressView().controlSize(.small) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if loader.sources.isEmpty {
                    if loader.finished {
                        EmptyStateView(title: L("ما لقينا مصادر"), systemImage: "rectangle.stack.badge.minus",
                                       actionTitle: L("إعادة المحاولة")) { loader.reload(core: app.core, kind: .series) }
                    } else {
                        ProgressView(L("نجمع المصادر…"))
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { loader.load(core: app.core, kind: .series, id: video.id) }
        .onDisappear { loader.cancel() }
    }

    private var title: String {
        if let s = video.season, let e = video.episode { return L("م%@ ح%@", "\(s)", "\(e)") }
        return video.title
    }

    private func play(_ s: RankedSource) {
        app.player.play(s, context: PlayContext(ref: ref, meta: meta, video: video, sources: loader.sources))
        dismiss()
    }
}

/// كم مصدر جابت كل إضافة وكم منها شغّال
struct AddonReportSheet: View {
    let report: [AddonReport]

    var body: some View {
        NavigationStack {
            List(report, id: \.addon) { r in
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.addon).font(Typo.headline)
                    HStack(spacing: 14) {
                        stat(L("المصادر"), r.total)
                        stat(L("شغّال"), r.alive, color: Palette.live)
                        stat(L("أصلي"), r.native)
                        stat("VLC", r.vlc)
                        if r.other > 0 { stat(L("غيرها"), r.other) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(L("تقرير الإضافات"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func stat(_ label: String, _ n: UInt32, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text("\(n)").font(Typo.headline).foregroundStyle(color).monospacedDigit()
            Text(label).font(Typo.badge).foregroundStyle(.secondary)
        }
    }
}


extension DetailsView {
    /// التصنيفات بدون تكرار (بعض الإضافات ترسل نفس التصنيف مرتين)، بنفس الترتيب
    static func uniqueGenres(_ genres: [String]) -> [String] {
        var seen = Set<String>()
        return genres.compactMap { g in
            let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { return nil }
            return t
        }
    }
}
