import SwiftUI
import QBCore

/// الرئيسية: بانر بارز، كمّل المشاهدة، ورفوف الكتالوجات من كل الإضافات
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var zoom
    @State private var rows: [CatalogRow] = []
    @State private var loading = true
    @State private var error: String?
    @State private var loadedVersion = -1

    var body: some View {
        NavigationStack(path: app.binding(for: .home)) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        Color.clear.frame(height: 0).id("top")
                        if let hero = heroItem {
                            HeroBanner(item: hero, namespace: zoom, pull: pull)
                                .id(hero.id)
                                .transition(.opacity)
                        } else if loading || !app.ready {
                            HeroPlaceholder()
                                .transition(.opacity)
                        }

                        if !app.continueWatching.isEmpty {
                            ContinueWatchingShelf(items: app.continueWatching, namespace: zoom)
                        }

                        if loading && rows.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in SkeletonShelf() }
                        }

                        ForEach(rows) { row in
                            Shelf(row: row, namespace: zoom)
                        }

                        if let error, rows.isEmpty, !loading {
                            EmptyStateView(title: L("ما قدرنا نحمّل الرفوف"), systemImage: "wifi.exclamationmark", message: error,
                                           actionTitle: L("إعادة المحاولة")) { Task { await load(force: true) } }
                        } else if !loading, rows.isEmpty {
                            EmptyStateView(title: L("ما فيه رفوف بعد"), systemImage: "puzzlepiece.extension",
                                           message: L("ثبّت إضافة فيها كتالوجات من الإعدادات ← الإضافات"))
                        }
                    }
                    .padding(.bottom, 40)
                }
                .ignoresSafeArea(edges: (heroItem == nil && !loading && app.ready) ? [] : .top)
                .trackOverscroll($pull)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top > 420
                } action: { _, past in
                    withAnimation(.smooth(duration: 0.25)) { scrolledPastHero = past }
                }
                .animation(.smooth(duration: 0.45), value: heroItem?.id)
                .scrollIndicators(.hidden)
                .onChange(of: app.scrollToTop[.home]) { _, _ in
                    withAnimation(Motion.soft) { proxy.scrollTo("top", anchor: .top) }
                }
            }
            .qbScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    QBLogo(size: 28)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            // بعد البانر: شريط زجاجي تحت شريط الحالة والشعار عليه، عشان ما يطوف فوق البوسترات
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackgroundVisibility(scrolledPastHero ? .visible : .hidden, for: .navigationBar)
            .mediaDestinations(zoom)
            .task(id: app.addonsVersion) { await load(force: false) }
            .refreshable { await load(force: true) }
        }
    }

    @State private var scrolledPastHero = false

    /// السحب لتحت فوق البانر: الصورة تتمطّط وتعبّي الفراغ
    @State private var pull: CGFloat = 0

    /// آخر بانر محفوظ: يطلع أول ما يفتح التطبيق لين توصل الرفوف
    @State private var cachedHero: MetaPreview? = HeroCache.atLaunch

    /// أول عمل له خلفية عريضة من أول رف (أو المحفوظ لين توصل)
    private var heroItem: MetaPreview? {
        freshHero ?? cachedHero
    }

    private var freshHero: MetaPreview? {
        rows.first?.items.first(where: { $0.background != nil }) ?? rows.first?.items.first
    }

    private func load(force: Bool) async {
        guard let core = app.core else { return }
        if !force, loadedVersion == app.addonsVersion, !rows.isEmpty { return }
        if !app.ready { return }
        loading = true
        error = nil
        do {
            let result = try await core.homeRows()
            let fresh = result.filter { !$0.items.isEmpty }
            // نحفظ البانر وصورته للمرة الجاية (بالخلفية، ما نأخر الرفوف)
            if let first = fresh.first, let hero = first.items.first(where: { $0.background != nil }) ?? first.items.first {
                HeroCache.save(hero)
            }
            withAnimation(Motion.standard) { rows = fresh }
            loadedVersion = app.addonsVersion
        } catch is CancellationError {
            return
        } catch {
            self.error = CoreClient.message(for: error)
        }
        loading = false
    }
}

/// البانر البارز أعلى الرئيسية
struct HeroBanner: View {
    @Environment(AppModel.self) private var app
    let item: MetaPreview
    let namespace: Namespace.ID
    var pull: CGFloat = 0

    var body: some View {
        let ref = MediaRef(item, zoomID: "hero-\(item.id)")
        NavigationLink(value: ref) {
            ZStack(alignment: .bottomLeading) {
                // الصورة لين أعلى الشاشة (ورا شريط الحالة)، ولما تسحب لتحت تطول لفوق من تحت وتعبّي الفراغ
                Color.clear
                    .frame(height: 540)
                    .overlay(alignment: .bottom) {
                        HeroImage(url: item.background ?? item.poster)
                            .frame(height: 540 + pull)
                            .clipped()
                            .overlay(alignment: .top) { Palette.topScrim.frame(height: 140) }
                    }
                    .overlay(alignment: .bottom) { Palette.scrim.frame(height: 300) }

                VStack(alignment: .leading, spacing: 12) {
                    if let logo = item.logo {
                        RemoteImage(url: logo, maxPixel: 700, contentMode: .fit, placeholderSymbol: nil)
                            .frame(maxWidth: 240, maxHeight: 92, alignment: .leading)
                            .environment(\.layoutDirection, .leftToRight)
                    } else {
                        Text(item.name).font(Typo.hero).lineLimit(2).foregroundStyle(.primary)
                    }
                    HStack(spacing: 10) {
                        if let r = item.imdbRating, !r.isEmpty { RatingBadge(rating: r) }
                        if let y = item.releaseInfo, !y.isEmpty { Text(y).font(Typo.caption).foregroundStyle(.secondary) }
                        if let g = item.genres.first { Text(g).font(Typo.caption).foregroundStyle(.secondary) }
                    }
                    if let d = item.description, !d.isEmpty {
                        Text(d).font(Typo.info).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        Label(L("التفاصيل والتشغيل"), systemImage: "play.fill")
                            .font(Typo.headline)
                            .foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 22)
                            .frame(height: 48)
                            .glassEffect(.regular.tint(Palette.accent), in: .capsule)
                        let saved = app.libraryVersion >= 0 && app.isInLibrary(item.id)
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { _ = app.toggleLibrary(MediaRef(item)) }
                        } label: {
                            Image(systemName: saved ? "checkmark" : "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace.downUp))
                                .frame(width: 48, height: 48)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .sensoryFeedback(.selection, trigger: saved)
                        .accessibilityLabel(saved ? L("شل من مكتبتي") : L("أضف لمكتبتي"))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }
            .matchedTransitionSource(id: ref.zoomID, in: namespace)
        }
        .buttonStyle(.plain)
    }
}

/// رف أفقي من كتالوج
struct Shelf: View {
    @Environment(AppModel.self) private var app
    let row: CatalogRow
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: row.title, subtitle: row.addonName, action: {
                app.paths[app.tab, default: NavigationPath()].append(
                    CatalogRoute(addonId: row.addonId, catalogId: row.catalogId, kind: row.kind, title: row.title))
            })
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { item in
                        let ref = MediaRef(item, zoomID: "\(row.id)|\(item.id)")
                        NavigationLink(value: ref) {
                            PosterCard(item)
                                .matchedTransitionSource(id: ref.zoomID, in: namespace)
                        }
                        .buttonStyle(.bouncyCard)
                        .contextMenu { MediaContextMenu(ref: ref) } preview: { MediaPreviewCard(ref: ref) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            // الضغطة المطاطية تكبر البطاقة فوق حجمها شوي: لا تنقص من فوق أو تحت
            .scrollClipDisabled()
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// قائمة الضغط الطويل على البوستر
struct MediaContextMenu: View {
    @Environment(AppModel.self) private var app
    let ref: MediaRef

    var body: some View {
        let saved = app.isInLibrary(ref.id)
        Button {
            app.toggleLibrary(ref)
        } label: {
            Label(saved ? L("شل من مكتبتي") : L("أضف لمكتبتي"), systemImage: saved ? "minus.circle" : "plus.circle")
        }
        if let link = shareURL {
            ShareLink(item: link, subject: Text(ref.name)) {
                Label(L("مشاركة"), systemImage: "square.and.arrow.up")
            }
        }
    }
}

extension MediaContextMenu {
    fileprivate var shareURL: URL? {
        var c = URLComponents()
        c.scheme = "qb"
        c.host = "title"
        c.path = "/\(ref.kind.wire)/\(ref.id)"
        c.queryItems = [URLQueryItem(name: "name", value: ref.name)]
        return c.url
    }
}

/// معاينة الضغط الطويل: البوستر كبير بزوايا ناعمة والاسم تحته (مثل تطبيقات أبل)
struct MediaPreviewCard: View {
    let ref: MediaRef

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay { RemoteImage(url: ref.poster, maxPixel: 600) }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(ref.name)
                .font(Typo.bodyMedium)
                .lineLimit(2)
                .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 260)
        .background(Palette.surface)
    }
}

/// رف كمّل المشاهدة
struct ContinueWatchingShelf: View {
    @Environment(AppModel.self) private var app
    let items: [WatchProgress]
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L("كمّل المشاهدة"))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { p in
                        let ref = MediaRef(id: p.mediaId, kind: p.kind, name: p.title, poster: p.poster, zoomID: "cw|\(p.mediaId)")
                        NavigationLink(value: ref) {
                            ContinueCard(progress: p)
                                .matchedTransitionSource(id: ref.zoomID, in: namespace)
                        }
                        .buttonStyle(.bouncyCard)
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(Motion.standard) { app.removeProgress(p.mediaId) }
                            } label: {
                                Label(L("شل من كمّل المشاهدة"), systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            // الضغطة المطاطية تكبر البطاقة فوق حجمها شوي: لا تنقص من فوق أو تحت
            .scrollClipDisabled()
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct ContinueCard: View {
    let progress: WatchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: 240, height: 136)
                    .overlay { RemoteImage(url: progress.poster, maxPixel: 600) }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .glassEffect(.regular, in: .circle)
                    if let label = episodeLabel {
                        Text(label).font(Typo.badge).foregroundStyle(.white)
                    }
                    Spacer()
                    if let left = TimeFormat.minutesLeft(position: progress.positionS, duration: progress.durationS) {
                        Text(L("باقي %@ د", "\(left)")).font(Typo.badge).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(10)
                .padding(.bottom, 4)
                if let f = progress.fraction {
                    ProgressLine(fraction: f)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            Text(progress.title).font(Typo.caption).lineLimit(1).frame(width: 240, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var episodeLabel: String? {
        guard let ep = progress.episodeId, let (s, e) = WidgetBridge.seasonEpisode(ep) else { return nil }
        return L("م%@ ح%@", "\(s)", "\(e)")
    }
}
