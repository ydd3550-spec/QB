import SwiftUI
import QBCore

/// اكتشف: اختيار النوع والكتالوج والتصنيف بشرائح زجاجية، وشبكة بوسترات
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var zoom
    @State private var kind: MediaKind = .movie
    @State private var catalogKey: String?
    @State private var genre: String?
    @State private var catalogs: [DiscoverCatalog] = []
    @State private var pager = CatalogPager()

    private var forKind: [DiscoverCatalog] {
        catalogs.filter { MediaKind(wire: $0.catalog.kind) == kind }
    }

    private var selected: DiscoverCatalog? {
        forKind.first(where: { key($0) == catalogKey }) ?? forKind.first
    }

    private func key(_ c: DiscoverCatalog) -> String { "\(c.addonUrl)|\(c.catalog.id)|\(c.catalog.kind)" }

    var body: some View {
        NavigationStack(path: app.binding(for: .discover)) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear.frame(height: 0).id("top")
                        filters
                        PosterGrid(items: pager.items, namespace: zoom, prefix: "discover") { more() }
                        footer
                    }
                    .padding(.bottom, 30)
                }
                .onChange(of: app.scrollToTop[.discover]) { _, _ in
                    withAnimation(Motion.soft) { proxy.scrollTo("top", anchor: .top) }
                }
            }
            .qbScreenBackground()
            .navigationTitle(L("اكتشف"))
            .mediaDestinations(zoom)
            .task(id: app.addonsVersion) {
                catalogs = app.core?.discoverCatalogs() ?? []
                reload()
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Chip(title: L("أفلام"), selected: kind == .movie, systemImage: "film") { setKind(.movie) }
                    Chip(title: L("مسلسلات"), selected: kind == .series, systemImage: "tv") { setKind(.series) }
                }
                .padding(.horizontal, 16)
            }

            if forKind.count > 1 {
                chipRow(forKind.map { (key($0), $0.catalog.name.isEmpty ? $0.addonName : "\($0.catalog.name) · \($0.addonName)") }, selected: selected.map(key)) { k in
                    catalogKey = k
                    genre = nil
                    reload()
                }
            }

            if let c = selected, c.catalog.supportsGenre, !c.catalog.genres.isEmpty {
                chipRow([("", L("الكل"))] + c.catalog.genres.map { ($0, $0) }, selected: genre ?? "") { g in
                    genre = g.isEmpty ? nil : g
                    reload()
                }
            }
        }
        .padding(.top, 4)
    }

    private func chipRow(_ options: [(String, String)], selected: String?, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                LazyHStack(spacing: 8) {
                    ForEach(options, id: \.0) { option in
                        Chip(title: option.1, selected: option.0 == selected) { pick(option.0) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(Haptics.select, trigger: selected)
    }

    private func setKind(_ k: MediaKind) {
        guard k != kind else { return }
        kind = k
        catalogKey = nil
        genre = nil
        reload()
    }

    private func reload() {
        guard let c = selected else {
            pager.reset(key: "none-\(kind.wire)")
            return
        }
        pager.reset(key: "\(key(c))|\(genre ?? "")")
        more()
    }

    private func more() {
        guard let c = selected else { return }
        pager.loadMore(core: app.core, addonUrl: c.addonUrl, kind: c.catalog.kind, catalogId: c.catalog.id, genre: genre)
    }

    @ViewBuilder
    private var footer: some View {
        if pager.loading {
            if pager.items.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 106, maximum: 160), spacing: 12)], spacing: 18) {
                    ForEach(0..<9, id: \.self) { _ in SkeletonBlock().aspectRatio(2 / 3, contentMode: .fit) }
                }
                .padding(.horizontal, 16)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            }
        } else if let error = pager.error {
            EmptyStateView(title: L("ما قدرنا نحمّل المزيد"), systemImage: "wifi.exclamationmark", message: error, actionTitle: L("إعادة المحاولة")) { more() }
        } else if selected == nil {
            EmptyStateView(title: L("ما فيه كتالوجات"), systemImage: "square.grid.2x2", message: L("ثبّت إضافة فيها كتالوجات من الإعدادات ← الإضافات"))
        } else if pager.items.isEmpty, pager.exhausted {
            EmptyStateView(title: L("ما فيه شي هنا"), systemImage: "square.grid.2x2")
        }
    }
}
