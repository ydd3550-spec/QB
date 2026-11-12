import SwiftUI
import QBCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        TabView(selection: Binding(get: { model.tab }, set: { model.select($0) })) {
            Tab(L("الرئيسية"), systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab(L("اكتشف"), systemImage: "square.grid.2x2.fill", value: AppTab.discover) {
                DiscoverView()
            }
            Tab(L("مكتبتي"), systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab(L("الإعدادات"), systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
            Tab(L("البحث"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(MiniPlayerAccessory(visible: model.player.showsMini))
        .fullScreenCover(isPresented: $player.isPresented, onDismiss: { model.player.didDismiss() }) {
            PlayerHost()
                .environment(model)
                .environment(\.layoutDirection, model.language.direction)
                .environment(\.locale, model.language.locale)
                .font(Typo.body)
                .tint(Palette.accent)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let err = model.startupError {
                EmptyStateView(title: L("ما اشتغل التطبيق"), systemImage: "exclamationmark.triangle", message: err)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.background.ignoresSafeArea())
            }
        }
        .background(Palette.background.ignoresSafeArea())
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
