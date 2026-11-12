import SwiftUI
import QBCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        TabView(selection: Binding(get: { model.tab }, set: { model.select($0) })) {
            Tab(L("الرئيسية"), systemImage: "house.fill", value: AppTab.home) {
                HomeView().miniPlayerInset(model.player.showsMini)
            }
            Tab(L("اكتشف"), systemImage: "square.grid.2x2.fill", value: AppTab.discover) {
                DiscoverView().miniPlayerInset(model.player.showsMini)
            }
            Tab(L("مكتبتي"), systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView().miniPlayerInset(model.player.showsMini)
            }
            Tab(L("الإعدادات"), systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView().miniPlayerInset(model.player.showsMini)
            }
            Tab(L("البحث"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView().miniPlayerInset(model.player.showsMini)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(MiniPlayerAccessory(visible: model.player.showsMini))
        .modifier(BehindPlayerEffect(player: model.player))
        .fullScreenCover(isPresented: $player.isPresented, onDismiss: { model.player.didDismiss() }) {
            PlayerHost()
                .environment(model)
                .environment(\.layoutDirection, model.language.direction)
                .environment(\.locale, model.language.locale)
                .font(Typo.body)
                .tint(Palette.accent)
        }
        .overlay(alignment: .top) {
            ToastHost(toast: model.toast)
        }
        .overlay {
            if let err = model.startupError {
                StartupErrorView(message: err, detail: model.startupDetail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.background.ignoresSafeArea())
            }
        }
        .alert(L("الحفظ متوقف مؤقتًا"), isPresented: Binding(get: { model.storageWarning != nil }, set: { if !$0 { model.storageWarning = nil } })) {
            Button(L("نسخ الخطأ")) { UIPasteboard.general.string = model.storageWarning }
            Button(L("تمام"), role: .cancel) {}
        } message: {
            Text(L("التطبيق شغّال، بس ما قدر يحفظ على الجهاز، فاللي تسويه ما بينحفظ بعد ما تقفله. هذا نص الخطأ:") + "\n\n" + (model.storageWarning ?? ""))
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

/// شاشة فشل التشغيل: الرسالة، ونص الخطأ الحقيقي من النواة (ينقدر يتحدد وينسخ)، وزر إعادة المحاولة
private struct StartupErrorView: View {
    @Environment(AppModel.self) private var model
    let message: String
    let detail: String?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                EmptyStateView(title: L("ما اشتغل التطبيق"), systemImage: "exclamationmark.triangle", message: message)
                if let detail {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("نص الخطأ")).font(Typo.info).foregroundStyle(.secondary)
                        Text(verbatim: detail)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
                }
                // زرّين بنفس المقاس والستايل، جنب بعض
                HStack(spacing: 12) {
                    if let detail {
                        GlassButton(title: copied ? L("انتسخ") : L("نسخ الخطأ"),
                                    systemImage: copied ? "checkmark" : "doc.on.doc",
                                    width: ButtonMetrics.pairWidth) {
                            UIPasteboard.general.string = detail
                            copied = true
                        }
                    }
                    GlassButton(title: L("إعادة المحاولة"), systemImage: "arrow.clockwise", width: ButtonMetrics.pairWidth) {
                        copied = false
                        Task { await model.retryStartup() }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 30)
            }
            .padding(.top, 40)
        }
    }
}

/// المشغّل المصغّر فوق التبويبات. iOS 26.1 يقدر يخفيه كامل لما ما فيه شي شغّال؛
/// على 26.0 يبقى ظاهر (تغيير الشكل يعيد بناء التبويبات ويضيّع مكانك).
private struct MiniPlayerAccessory: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: visible) { MiniPlayerView() }
        } else {
            content.tabViewBottomAccessory { MiniPlayerView() }
        }
    }
}


extension View {
    /// مسافة تحت آخر المحتوى بقد المشغّل الصغير، عشان آخر سطر ينسحب فوقه وما يتغطّى
    func miniPlayerInset(_ visible: Bool) -> some View {
        safeAreaPadding(.bottom, visible ? 64 : 0)
    }
}

/// الصفحة اللي ورا المشغّل: معتّمة وهو فوقها، وتنوّر مع ما تسحبه لتحت.
/// طبقة فوقها بس، فالصفحة ما ينعاد ترتيبها ولا تنبني من جديد
private struct BehindPlayerEffect: ViewModifier {
    let player: PlayerModel

    func body(content: Content) -> some View {
        let p = player.isPresented ? player.dismissProgress : 1
        // الصفحة اللي ورا تبان كاملة ومعتّمة حول البطاقة (مثل سحب صفحة التفاصيل)
        content
            .overlay {
                GeometryReader { g in
                    // بالعرض الصفحة اللي ورا مرتّبة للطول أصلًا، فنغطيها بزجاج مموّه بدل ما تبان أزرارها مقصوصة تحت البطاقة
                    let landscape = g.size.width > g.size.height
                    ZStack {
                        if landscape, p < 1 {
                            Rectangle().fill(.regularMaterial).opacity(1 - p)
                        }
                        Color.black.opacity((landscape ? 0.45 : 0.3) * (1 - p))
                    }
                    .ignoresSafeArea()
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .animation(Motion.soft, value: player.isPresented)
    }
}
