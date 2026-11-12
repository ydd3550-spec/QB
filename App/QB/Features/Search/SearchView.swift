import SwiftUI
import QBCore

/// البحث: النتائج تطلع من كل الإضافات أول بأول
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var zoom
    @State private var query = ""
    @State private var rows: [CatalogRow] = []
    @State private var searching = false
    @State private var searched = ""
    @State private var error: String?
    @State private var recents: [String] = []

    var body: some View {
        NavigationStack(path: app.binding(for: .search)) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: 0).id("top")
                        content
                    }
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: app.scrollToTop[.search]) { _, _ in
                    withAnimation(Motion.soft) { proxy.scrollTo("top", anchor: .top) }
                }
            }
            .qbScreenBackground()
            .navigationTitle(L("البحث"))
            .searchable(text: $query, prompt: Text(L("أفلام، مسلسلات…")))
            .onSubmit(of: .search) { saveRecent(query) }
            // فتحت نتيجة من هالبحث: نحفظه
            .onChange(of: app.paths[.search]?.count ?? 0) { old, new in
                if new > old, old == 0 { saveRecent(query) }
            }
            .task(id: query) { await search() }
            .onAppear { loadRecents() }
            .mediaDestinations(zoom)
        }
        // تسحب من طرف الشاشة وترجع للصفحة اللي كنت فيها قبل البحث، بنفس مكانك فيها
        .edgeSwipeBack(enabled: (app.paths[.search]?.isEmpty ?? true)) { app.goBackFromSearch() }
    }

    @ViewBuilder
    private var content: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 {
            if recents.isEmpty {
                EmptyStateView(title: L("ابحث في كل إضافاتك"), systemImage: "magnifyingglass", message: L("اكتب اسم فيلم أو مسلسل"))
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("عمليات بحث سابقة")).font(Typo.section)
                        Spacer()
                        Button(L("مسح")) {
                            recents = []
                            app.save("recent_searches", "[]")
                        }
                        .font(Typo.infoMedium)
                    }
                    FlowChips(items: recents) { query = $0 }
                }
                .padding(.horizontal, 20)
            }
        } else {
            if searching && rows.isEmpty {
                ForEach(0..<2, id: \.self) { _ in SkeletonShelf() }
            }
            ForEach(rows) { row in
                Shelf(row: row, namespace: zoom)
            }
            if searching && !rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            if !searching, rows.isEmpty, searched == q {
                if let error {
                    EmptyStateView(title: L("صار خطأ بالبحث"), systemImage: "wifi.exclamationmark", message: error, actionTitle: L("إعادة المحاولة")) {
                        Task { await search(debounce: false) }
                    }
                } else {
                    EmptyStateView(title: L("ما لقينا شي"), systemImage: "magnifyingglass", message: L("جرّب اسم ثاني أو بالإنجليزي"))
                        .padding(.top, 40)
                }
            }
        }
    }

    private func search(debounce: Bool = true) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let core = app.core else {
            rows = []
            searching = false
            searched = ""
            return
        }
        if debounce {
            try? await Task.sleep(for: .milliseconds(380))
            if Task.isCancelled { return }
        }
        searching = true
        error = nil
        rows = []
        let listener = SearchStream()
        let work = Task.detached { () -> Error? in
            defer { listener.finish() }
            do {
                _ = try await core.searchRows(query: q, listener: listener)
                return nil
            } catch {
                return error
            }
        }
        await withTaskCancellationHandler {
            for await row in listener.stream {
                if Task.isCancelled { break }
                guard !row.items.isEmpty else { continue }
                withAnimation(Motion.standard) { rows.append(row) }
            }
        } onCancel: {
            work.cancel()
        }
        if Task.isCancelled { return }
        if let e = await work.value, !(e is CancellationError) { error = CoreClient.message(for: e) }
        searched = q
        searching = false
    }

    private func loadRecents() {
        guard let raw = (try? app.core?.setting(key: "recent_searches")) ?? nil,
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        recents = SearchHistory.cleaned(list)
        if recents != list { persistRecents() }
    }

    private func saveRecent(_ q: String) {
        // ينحفظ بس لما تضغط بحث أو تفتح نتيجة، مو وقت الكتابة
        let next = SearchHistory.adding(q, to: recents)
        guard next != recents else { return }
        recents = next
        persistRecents()
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recents), let s = String(data: data, encoding: .utf8) {
            app.save("recent_searches", s)
        }
    }
}

/// شرائح تلتف لسطر جديد
struct FlowChips: View {
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Chip(title: item, systemImage: "clock.arrow.circlepath") { pick(item) }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
