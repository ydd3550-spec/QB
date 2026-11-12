import SwiftUI
import QBCore

@main
struct QBApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.layoutDirection, model.language.direction)
                .environment(\.locale, model.language.locale)
                .tint(Palette.accent)
                .preferredColorScheme(model.colorScheme)
                .id(model.language) // تغيير اللغة يعيد رسم النصوص كلها
                .task { await model.start() }
                .onOpenURL { model.handle(url: $0) }
        }
    }
}
