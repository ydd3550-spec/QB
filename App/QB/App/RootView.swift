import SwiftUI
import QBCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if model.player.hasMedia && !model.player.isPresented && !model.player.miniHidden {
                MiniPlayerView()
            }
        }
        .fullScreenCover(isPresented: $model.player.isPresented) {
            PlayerHost()
                .environment(model)
                .environment(\.layoutDirection, model.language.direction)
                .environment(\.locale, model.language.locale)
        }
        .overlay {
            if let err = model.startupError {
                ContentUnavailableView(L("ما اشتغل التطبيق"), systemImage: "exclamationmark.triangle", description: Text(err))
                    .background(Palette.background)
            }
        }
        .background(Palette.background.ignoresSafeArea())
    }
}
