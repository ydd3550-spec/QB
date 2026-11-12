import AppIntents
import Foundation

/// اختصارات Siri وتطبيق الاختصارات وSpotlight: «كمّل المشاهدة» و«ابحث في QB» و«مكتبتي».
/// كلها تفتح التطبيق وتروح للمكان المطلوب (التطبيق يقرأ الطلب أول ما يصحى).
enum PendingIntent: String {
    case resume, search, library

    private static let key = "qb.pendingIntent"

    func post() {
        store()
        NotificationCenter.default.post(name: .qbPendingIntent, object: nil)
    }

    /// يحفظ الطلب بدون تنبيه (يتنفّذ لما تجهز النواة)
    func store() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }

    static func take() -> PendingIntent? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return PendingIntent(rawValue: raw)
    }
}

extension Notification.Name {
    static let qbPendingIntent = Notification.Name("qb.pendingIntent")
}

nonisolated struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "كمّل المشاهدة"
    static let description = IntentDescription("يفتح آخر شي كنت تشوفه في QB")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.resume.post()
        return .result()
    }
}

nonisolated struct SearchQBIntent: AppIntent {
    static let title: LocalizedStringResource = "ابحث في QB"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.search.post()
        return .result()
    }
}

nonisolated struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "مكتبتي"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.library.post()
        return .result()
    }
}

nonisolated struct QBShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeWatchingIntent(),
                    phrases: ["كمّل المشاهدة في \(.applicationName)", "Resume watching in \(.applicationName)"],
                    shortTitle: "كمّل المشاهدة",
                    systemImageName: "play.circle.fill")
        AppShortcut(intent: SearchQBIntent(),
                    phrases: ["ابحث في \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "ابحث",
                    systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenLibraryIntent(),
                    phrases: ["افتح مكتبتي في \(.applicationName)", "Open my library in \(.applicationName)"],
                    shortTitle: "مكتبتي",
                    systemImageName: "books.vertical.fill")
    }
}
