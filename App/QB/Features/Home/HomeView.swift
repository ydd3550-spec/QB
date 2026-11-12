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
                            HeroBanner(item: hero, namespace: zoom)
                        } else if loading {
                            SkeletonBlock(cornerRadius: 0).frame(height: 520)
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
                .ignoresSafeArea(edges: heroItem == nil ? [] : .top)
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
            .mediaDestinations(zoom)
            .task(id: app.addonsVersion) { await load(force: false) }
            .refreshable { await load(force: true) }
        }
    }

    /// أول عمل له خلفية عريضة من أول رف
    private var heroItem: MetaPreview? {
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
            withAnimation(Motion.standard) { rows = result.filter { !$0.items.isEmpty } }
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

    var body: some View {
        let ref = MediaRef(item, zoomID: "hero-\(item.id)")
        NavigationLink(value: ref) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .frame(height: 540)
                    .overlay { RemoteImage(url: item.background ?? item.poster, maxPixel: 1400) }
                    .clipped()
                    .overlay(alignment: .top) { Palette.topScrim.frame(height: 140) }
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
                        Button {
                            app.toggleLibrary(MediaRef(item))
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel(L("أضف لمكتبتي"))
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
                        .buttonStyle(.plain)
                        .contextMenu { MediaContextMenu(ref: ref) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
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
                        .buttonStyle(.plain)
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
