import SwiftUI
import QBCore

/// مكتبتي: المحفوظ مع فلتر النوع، وكمّل المشاهدة، وآخر المشاهدات
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var zoom
    @State private var items: [LibraryItem] = []
    @State private var history: [HistoryEntry] = []
    @State private var filter: Filter = .all
    @State private var sort: Sort = .recent

    enum Filter: Hashable { case all, movies, series }
    enum Sort: Hashable { case recent, name }

    private var shown: [LibraryItem] {
        let f = items.filter {
            switch filter {
            case .all: true
            case .movies: $0.kind == .movie
            case .series: $0.kind == .series
            }
        }
        switch sort {
        case .recent: return f.sorted { $0.addedAt > $1.addedAt }
        case .name: return f.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 106, maximum: 160), spacing: 12, alignment: .top)]

    var body: some View {
        NavigationStack(path: app.binding(for: .library)) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: 0).id("top")
                        if !app.continueWatching.isEmpty {
                            ContinueWatchingShelf(items: app.continueWatching, namespace: zoom)
                        }

                        savedHeader
                        savedGrid
                        historyShelf
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: app.scrollToTop[.library]) { _, _ in
                    withAnimation(Motion.soft) { proxy.scrollTo("top", anchor: .top) }
                }
            }
            .qbScreenBackground()
            .navigationTitle(L("مكتبتي"))
            .mediaDestinations(zoom)
            .task(id: app.libraryVersion) { reload() }
            .refreshable { reload() }
        }
    }

    @ViewBuilder private var savedHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("المحفوظ")).font(Typo.section)
                Spacer()
                Menu {
                    Picker(L("الترتيب"), selection: $sort) {
                        Text(L("الأحدث")).tag(Sort.recent)
                        Text(L("الاسم")).tag(Sort.name)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel(L("الترتيب"))
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Chip(title: L("الكل"), selected: filter == .all) { filter = .all }
                    Chip(title: L("أفلام"), selected: filter == .movies, systemImage: "film") { filter = .movies }
                    Chip(title: L("مسلسلات"), selected: filter == .series, systemImage: "tv") { filter = .series }
                }
            }
            .sensoryFeedback(Haptics.select, trigger: filter)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var savedGrid: some View {
        if shown.isEmpty {
            EmptyStateView(title: items.isEmpty ? L("مكتبتك فاضية") : L("ما فيه شي بهالفلتر"),
                           systemImage: "books.vertical",
                           message: items.isEmpty ? L("اضغط علامة الحفظ في صفحة أي عمل عشان يطلع هنا") : nil)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(shown, id: \.mediaId) { item in
                    let ref = MediaRef(id: item.mediaId, kind: item.kind, name: item.title, poster: item.poster, zoomID: "lib|\(item.mediaId)")
                    NavigationLink(value: ref) {
                        PosterCard(name: item.title, poster: item.poster, width: nil)
                            .matchedTransitionSource(id: ref.zoomID, in: zoom)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            withAnimation(Motion.standard) { _ = app.toggleLibrary(ref) }
                        } label: {
                            Label(L("شل من مكتبتي"), systemImage: "minus.circle")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var historyShelf: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("آخر المشاهدات"), action: {
                    app.tab = .settings
                    app.paths[.settings] = NavigationPath([SettingsRoute.history])
                })
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(uniqueHistory, id: \.mediaId) { h in
                            let ref = MediaRef(id: h.mediaId, kind: h.kind, name: h.title, poster: h.poster, zoomID: "hist|\(h.mediaId)")
                            NavigationLink(value: ref) {
                                PosterCard(name: h.title, poster: h.poster, width: 104)
                                    .matchedTransitionSource(id: ref.zoomID, in: zoom)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// كل عمل مرة وحدة (آخر مرة)
    private var uniqueHistory: [HistoryEntry] {
        var seen = Set<String>()
        return history.filter { seen.insert($0.mediaId).inserted }.prefix(20).map { $0 }
    }

    private func reload() {
        items = (try? app.core?.library()) ?? []
        history = (try? app.core?.history(limit: 60)) ?? []
    }
}
