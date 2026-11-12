import SwiftUI
import QBCore
import AVFoundation

@main
struct QBApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Typo.applyToUIKit()
        // الصوت يشتغل حتى لو الجوال على الصامت، وهذا شرط لصورة داخل صورة
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.layoutDirection, model.language.direction)
                .environment(\.locale, model.language.locale)
                .font(Typo.body)
                .tint(Palette.accent)
                .preferredColorScheme(model.colorScheme)
                .id(model.language) // تغيير اللغة يعيد رسم النصوص كلها
                .task { await model.start() }
                .onOpenURL { model.handle(url: $0) }
                .onReceive(NotificationCenter.default.publisher(for: .qbPendingIntent)) { _ in model.runPendingIntent() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.runPendingIntent() }
            model.player.scenePhaseChanged(phase)
            if phase == .background { model.refreshWidget() }
        }
    }
}
