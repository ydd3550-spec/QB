import SwiftUI
import QBCore

/// البحث: النتائج تطلع من كل الإضافات أول بأول
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var zoom

    /// كل حالة البحث (الكلمة والنتائج) في نموذج ثابت بالتطبيق: لما تفتح نتيجة وترجع، البحث نفسه بنتايجه
    /// ومكانك فيه، ما ينعاد ولا ينمسح ولا يتحمّل من جديد
    private var model: SearchModel { app.search }

    var body: some View {
        @Bindable var model = app.search
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
            .searchable(text: $model.query, prompt: Text(L("أفلام، مسلسلات…")))
            .onSubmit(of: .search) { model.saveRecent(model.query, app: app) }
            // فتحت نتيجة من هالبحث: نحفظه
            .onChange(of: app.paths[.search]?.count ?? 0) { old, new in
                if new > old, old == 0 { model.saveRecent(model.query, app: app) }
            }
            // البحث يبدأ لما تتغير الكلمة بس، مو كل ما ترجع الصفحة تبان
            .onChange(of: model.query) { _, _ in model.queryChanged(core: app.core) }
            .onAppear { model.loadRecentsOnce(app: app) }
            // من البحث: فتح ورجوع iOS العادي. السحب من اليمين يرجّعك وصفحة البحث بنتايجها ومكانك فيها حيّة تحتها،
            // مع الظل والحركة الخفيفة حق iOS (حركة التكبير كانت تخلّي اللي تحتها أسود في تبويب البحث)
            .mediaDestinations(zoom, zoomTransition: false)
        }
        // تسحب من طرف الشاشة وترجع للصفحة اللي كنت فيها قبل البحث، بنفس مكانك فيها
        .edgeSwipeBack(enabled: (app.paths[.search]?.isEmpty ?? true), backdrop: app.searchBackdrop) { app.goBackFromSearch() }
    }

    @ViewBuilder
    private var content: some View {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 {
            if model.recents.isEmpty {
                EmptyStateView(title: L("ابحث في كل إضافاتك"), systemImage: "magnifyingglass", message: L("اكتب اسم فيلم أو مسلسل"))
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("عمليات بحث سابقة")).font(Typo.section)
                        Spacer()
                        Button(L("مسح")) { model.clearRecents(app: app) }
                        .font(Typo.infoMedium)
                    }
                    FlowChips(items: model.recents) { model.query = $0 }
                }
                .padding(.horizontal, 20)
            }
        } else {
            if model.searching && model.rows.isEmpty {
                ForEach(0..<2, id: \.self) { _ in SkeletonShelf() }
            }
            ForEach(model.rows) { row in
                Shelf(row: row, namespace: zoom)
            }
            if model.searching && !model.rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            if !model.searching, model.rows.isEmpty, model.searched == q {
                if let error = model.error {
                    EmptyStateView(title: L("صار خطأ بالبحث"), systemImage: "wifi.exclamationmark", message: error, actionTitle: L("إعادة المحاولة")) {
                        model.retry(core: app.core)
                    }
                } else {
                    EmptyStateView(title: L("ما لقينا شي"), systemImage: "magnifyingglass", message: L("جرّب اسم ثاني أو بالإنجليزي"))
                        .padding(.top, 40)
                }
            }
        }
    }
}

/// حالة البحث: تعيش طول عمر التطبيق (مو مع ظهور الصفحة)، فالرجوع من صفحة فلم ما يعيد البحث
@Observable
@MainActor
final class SearchModel {
    var query = ""
    private(set) var rows: [CatalogRow] = []
    private(set) var searching = false
    private(set) var searched = ""
    private(set) var error: String?
    private(set) var recents: [String] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    /// الكلمة اللي النتائج الحالية (أو اللي قاعد يجيبها) لها
    @ObservationIgnored private var current = ""
    @ObservationIgnored private var recentsLoaded = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// تغيّرت الكلمة: نبحث بس لو صارت كلمة ثانية فعلًا (مسافة زيادة ما تعيد البحث)
    func queryChanged(core: QbCore?) {
        let q = trimmed
        guard q != current else { return }
        start(q, core: core, debounce: true)
    }

    func retry(core: QbCore?) {
        start(trimmed, core: core, debounce: false)
    }

    private func start(_ q: String, core: QbCore?, debounce: Bool) {
        task?.cancel()
        current = q
        guard q.count >= 2, let core else {
            task = nil
            rows = []
            searching = false
            searched = ""
            error = nil
            return
        }
        task = Task { await run(q, core: core, debounce: debounce) }
    }

    private func run(_ q: String, core: QbCore, debounce: Bool) async {
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
                if UIAccessibility.isReduceMotionEnabled {
                    rows.append(row)
                } else {
                    withAnimation(Motion.standard) { rows.append(row) }
                }
                ImagePipeline.shared.prefetch(row.items.map(\.poster), maxPixel: 360)
            }
        } onCancel: {
            work.cancel()
        }
        if Task.isCancelled || current != q { return }
        if let e = await work.value, !(e is CancellationError) { error = CoreClient.message(for: e) }
        searched = q
        searching = false
    }

    // MARK: - عمليات البحث السابقة

    func loadRecentsOnce(app: AppModel) {
        guard !recentsLoaded else { return }
        guard let raw = (try? app.core?.setting(key: "recent_searches")) ?? nil else {
            // النواة لسا ما جهزت: نحاول المرة الجاية
            if app.core != nil { recentsLoaded = true }
            return
        }
        recentsLoaded = true
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        recents = SearchHistory.cleaned(list)
        if recents != list { persistRecents(app: app) }
    }

    func saveRecent(_ q: String, app: AppModel) {
        // ينحفظ بس لما تضغط بحث أو تفتح نتيجة، مو وقت الكتابة
        let next = SearchHistory.adding(q, to: recents)
        guard next != recents else { return }
        recents = next
        persistRecents(app: app)
    }

    func clearRecents(app: AppModel) {
        recents = []
        app.save("recent_searches", "[]")
    }

    private func persistRecents(app: AppModel) {
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
