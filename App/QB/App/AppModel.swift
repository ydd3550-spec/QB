import SwiftUI
import QBCore
import WidgetKit

enum AppTab: Hashable {
    case home, discover, library, settings, search
}

/// العنصر اللي نفتح صفحته
struct MediaRef: Hashable, Sendable {
    let id: String
    let kind: MediaKind
    let name: String
    let poster: String?
    let background: String?

    init(id: String, kind: MediaKind, name: String, poster: String? = nil, background: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.poster = poster; self.background = background
    }
    init(_ m: MetaPreview) {
        self.init(id: m.id, kind: m.kind, name: m.name, poster: m.poster, background: m.background)
    }
}

/// حالة التطبيق العامة: التبويب الحالي، المشغّل الحالي، الإضافات، والإعدادات
@Observable
@MainActor
final class AppModel {
    let core: QbCore?
    var tab: AppTab = .home
    var addons: [Manifest] = []
    var ready = false
    var startupError: String?

    /// مسار التنقل لكل تبويب (عشان ضغطة التبويب ترجع للبداية)
    var paths: [AppTab: NavigationPath] = [.home: .init(), .discover: .init(), .library: .init(), .settings: .init(), .search: .init()]
    /// يزيد كل ما انضغط التبويب الحالي وهو بالبداية (يرجّع لأعلى)
    var scrollToTop: [AppTab: Int] = [:]

    let player = PlayerModel()

    // الإعدادات
    var language: AppLanguage = .arabic
    var appearance: String = "system"
    var preferredQuality: Int = 0
    var preferredEngine: String = "auto"
    var subtitleLang: String = "ara"
    var subtitleSize: Double = 1.0
    var autoNext = true
    var skipIntroSeconds = 85

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    init() {
        core = CoreClient.make()
        if let raw = core.flatMap({ try? $0.setting(key: "language") }) ?? nil, let lang = AppLanguage(rawValue: raw) {
            language = lang
        }
        L10n.set(language)
        player.app = self
        loadSettings()
    }

    func start() async {
        guard let core else {
            startupError = L("تعذّر تشغيل النواة")
            return
        }
        _ = await core.seedDefaultAddons()
        await reloadAddons()
        ready = true
        refreshWidget()
    }

    func reloadAddons() async {
        guard let core else { return }
        addons = await core.addons()
    }

    // MARK: - الإعدادات

    private func loadSettings() {
        guard let core else { return }
        func get(_ k: String) -> String? { (try? core.setting(key: k)) ?? nil }
        appearance = get("appearance") ?? "system"
        preferredQuality = Int(get("preferred_quality") ?? "") ?? 0
        preferredEngine = get("preferred_engine") ?? "auto"
        subtitleLang = get("subtitle_lang") ?? (language == .arabic ? "ara" : "eng")
        subtitleSize = Double(get("subtitle_size") ?? "") ?? 1.0
        autoNext = (get("auto_next") ?? "1") == "1"
        skipIntroSeconds = Int(get("skip_intro_seconds") ?? "") ?? 85
    }

    func save(_ key: String, _ value: String) {
        try? core?.setSetting(key: key, value: value)
    }

    func setLanguage(_ lang: AppLanguage) {
        language = lang
        L10n.set(lang)
        save("language", lang.rawValue)
    }

    // MARK: - التبويبات

    /// درس زر التبويب: بصفحة داخلية يرجع للبداية، وبالبداية يطلع لأعلى (ولو فوق ما يسوي شي)
    func select(_ newTab: AppTab) {
        if newTab == tab {
            if let p = paths[newTab], !p.isEmpty {
                paths[newTab] = NavigationPath()
            } else {
                scrollToTop[newTab, default: 0] += 1
            }
        } else {
            tab = newTab
        }
    }

    func binding(for t: AppTab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[t] ?? NavigationPath() }, set: { self.paths[t] = $0 })
    }

    func open(_ ref: MediaRef) {
        paths[tab, default: NavigationPath()].append(ref)
    }

    // MARK: - الروابط

    /// stremio://…/manifest.json يفتح تثبيت الإضافة، وqb://title/<kind>/<id> يفتح العمل (من الويدجت)
    var pendingAddonURL: String?

    func handle(url: URL) {
        if url.scheme == "stremio" {
            pendingAddonURL = url.absoluteString
            tab = .settings
            paths[.settings] = NavigationPath([SettingsRoute.addons])
            return
        }
        if url.scheme == "qb", url.host() == "title" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, let kind = MediaKind(wire: parts[0]) {
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
                tab = .home
                paths[.home] = NavigationPath([MediaRef(id: parts[1], kind: kind, name: name)])
            }
        }
    }

    // MARK: - ويدجت كمّل المشاهدة

    func refreshWidget() {
        guard let core else { return }
        WidgetBridge.write(core.continueWatching())
        WidgetCenter.shared.reloadAllTimelines()
    }
}
