import SwiftUI
import QBCore

/// شبكة بوسترات مع تحميل صفحات لما توصل لآخرها (مشتركة بين "الكل" واكتشف)
@Observable
@MainActor
final class CatalogPager {
    var items: [MetaPreview] = []
    var loading = false
    var error: String?
    var exhausted = false
    private var seen = Set<String>()
    private var key = ""
    private var task: Task<Void, Never>?

    func reset(key: String) {
        guard key != self.key else { return }
        task?.cancel()
        self.key = key
        items = []
        seen = []
        exhausted = false
        error = nil
        loading = false
    }

    func loadMore(core: QbCore?, addonUrl: String?, kind: String, catalogId: String, genre: String?, pageSize: Bool = true) {
        guard let core, let addonUrl, !loading, !exhausted else {
            if addonUrl == nil { exhausted = true }
            return
        }
        loading = true
        error = nil
        let skip = UInt32(items.count)
        let key = self.key
        task = Task {
            do {
                let page = try await core.catalogPage(addonUrl: addonUrl, kind: kind, catalogId: catalogId, genre: genre, skip: skip)
                guard key == self.key, !Task.isCancelled else { return }
                let fresh = page.filter { seen.insert($0.id).inserted }
                withAnimation(Motion.standard) { items.append(contentsOf: fresh) }
                // prefetch: حمّل بوسترات الصفحة مسبقًا
                ImagePipeline.shared.prefetch(fresh.map(\.poster), maxPixel: 360)
                if fresh.isEmpty { exhausted = true }
            } catch is CancellationError {
            } catch {
                guard key == self.key else { return }
                self.error = CoreClient.message(for: error)
            }
            if key == self.key { loading = false }
        }
    }
}

struct PosterGrid: View {
    let items: [MetaPreview]
    let namespace: Namespace.ID
    let prefix: String
    var onReachEnd: () -> Void = {}

    private let columns = [GridItem(.adaptive(minimum: 106, maximum: 160), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                let ref = MediaRef(item, zoomID: "\(prefix)|\(item.id)")
                NavigationLink(value: ref) {
                    PosterCard(item, width: nil)
                        .matchedTransitionSource(id: ref.zoomID, in: namespace)
                }
                .buttonStyle(.bouncyCard)
                .contextMenu { MediaContextMenu(ref: ref) } preview: { MediaPreviewCard(ref: ref) }
                .onAppear {
                    if item.id == items.last?.id { onReachEnd() }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// "الكل" من رف بالرئيسية
struct CatalogGridView: View {
    @Environment(AppModel.self) private var app
    let route: CatalogRoute
    let namespace: Namespace.ID
    @State private var pager = CatalogPager()

    private var addonUrl: String? {
        app.addons.first(where: { $0.id == route.addonId })?.transportUrl
    }

    var body: some View {
        ScrollView {
            PosterGrid(items: pager.items, namespace: namespace, prefix: "grid-\(route.catalogId)") { more() }
                .padding(.top, 8)
            footer
        }
        .qbScreenBackground()
        .navigationTitle(route.title)
            .qbNavBar()
        .navigationBarTitleDisplayMode(.large)
        .task {
            pager.reset(key: "\(route.addonId)/\(route.catalogId)/\(route.kind.wire)")
            if pager.items.isEmpty { more() }
        }
    }

    private func more() {
        pager.loadMore(core: app.core, addonUrl: addonUrl, kind: route.kind.wire, catalogId: route.catalogId, genre: nil)
    }

    @ViewBuilder
    private var footer: some View {
        if pager.loading {
            ProgressView().padding(30)
        } else if let error = pager.error {
            EmptyStateView(title: L("ما قدرنا نحمّل المزيد"), systemImage: "wifi.exclamationmark", message: error, actionTitle: L("إعادة المحاولة")) { more() }
        } else if pager.items.isEmpty, pager.exhausted {
            EmptyStateView(title: L("ما فيه شي هنا"), systemImage: "square.grid.2x2")
        }
    }
}
