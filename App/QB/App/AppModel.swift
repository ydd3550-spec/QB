import SwiftUI
import QBCore
import WidgetKit

/// حالة التطبيق العامة: التبويب الحالي، المشغّل الحالي، الإضافات، والإعدادات
@Observable
@MainActor
final class AppModel {
    private(set) var core: QbCore?
    var tab: AppTab = .home
    var addons: [Manifest] = []
    var ready = false
    var startupError: String?
    /// نص الخطأ الحقيقي من النواة (يطلع تحت رسالة الخطأ وينقدر ينسخ)
    var startupDetail: String?
    /// النواة اشتغلت بالذاكرة بس: هذا سبب فشل التخزين
    var storageWarning: String?

    /// مسار التنقل لكل تبويب (عشان ضغطة التبويب ترجع للبداية)
    var paths: [AppTab: NavigationPath] = [.home: .init(), .discover: .init(), .library: .init(), .settings: .init(), .search: .init()]
    /// يزيد كل ما انضغط التبويب الحالي وهو بالبداية (يرجّع لأعلى)
    var scrollToTop: [AppTab: Int] = [:]

    let player = PlayerModel()
    /// البحث: كلمته ونتايجه تبقى لين تغيّرها (الرجوع من صفحة فلم ما يعيد البحث)
    let search = SearchModel()

    /// قائمة كمّل المشاهدة (تتحدّث بعد كل حفظ تقدّم)
    var continueWatching: [WatchProgress] = []
    /// يزيد كل ما تغيّرت المكتبة أو السجل عشان الشاشات تعيد القراءة
    var libraryVersion = 0
    /// يزيد كل ما تغيّرت الإضافات عشان الرئيسية تعيد التحميل
    var addonsVersion = 0

    /// رسالة عابرة
    var toast: String?
    private var toastTask: Task<Void, Never>?

    // الإعدادات
    var language: AppLanguage = .arabic
    var appearance: String = "system"
    var preferredQuality: Int = 0
    var preferredEngine: String = "auto"
    var subtitleLang: String = "ara"
    var subtitleSize: Double = 1.0
    var subtitleBackground = true
    /// شكل الترجمة: 0 ظل، 1 صندوق، 2 بدون خلفية
    var subtitleStyle: Int = 0
    /// وزن خط الترجمة: 0 عادي، 1 سميك، 2 عريض
    var subtitleWeight: Int = 1
    /// مكان الترجمة: 0.8 منخفض، 1 وسط، 1.4 مرتفع
    var subtitlePosition: Double = 1.0
    var autoNext = true
    var skipIntroSeconds = 85
    var autoPiP = true

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    init() {
        let startup = CoreClient.make()
        core = startup.core
        startupDetail = startup.error
        storageWarning = startup.warning
        if let raw = core.flatMap({ try? $0.setting(key: "language") }) ?? nil, let lang = AppLanguage(rawValue: raw) {
            language = lang
        }
        L10n.set(language)
        player.app = self
        loadSettings()
        continueWatching = core?.continueWatching() ?? []
    }

    func start() async {
        guard let core else {
            startupError = L("تعذّر تشغيل النواة")
            return
        }
        guard !ready else { return }
        startupError = nil
        let seeded = await core.seedDefaultAddons()
        await reloadAddons()
        if seeded > 0 { addonsVersion += 1 }
        ready = true
        runPendingIntent()
        refreshContinueWatching()
    }

    /// يعيد محاولة تشغيل النواة من شاشة الخطأ
    func retryStartup() async {
        guard core == nil else { return }
        let startup = CoreClient.make()
        startupDetail = startup.error
        storageWarning = startup.warning
        guard let c = startup.core else { return }
        core = c
        startupError = nil
        loadSettings()
        continueWatching = c.continueWatching()
        await start()
    }

    func reloadAddons() async {
        guard let core else { return }
        addons = await core.addons()
    }

    /// بعد تثبيت/حذف/ترتيب الإضافات
    func addonsChanged() async {
        await reloadAddons()
        addonsVersion += 1
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
        subtitleBackground = (get("subtitle_background") ?? "1") == "1"
        subtitleStyle = Int(get("subtitle_style") ?? "") ?? (subtitleBackground ? 1 : 0)
        subtitleWeight = Int(get("subtitle_weight") ?? "") ?? 1
        subtitlePosition = Double(get("subtitle_position") ?? "") ?? 1.0
        autoNext = (get("auto_next") ?? "1") == "1"
        skipIntroSeconds = Int(get("skip_intro_seconds") ?? "") ?? 85
        autoPiP = (get("auto_pip") ?? "1") == "1"
    }

    func save(_ key: String, _ value: String) {
        try? core?.setSetting(key: key, value: value)
    }

    func setLanguage(_ lang: AppLanguage) {
        guard lang != language else { return }
        L10n.set(lang)
        language = lang
        save("language", lang.rawValue)
        refreshWidget()
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
            if newTab == .search {
                tabBeforeSearch = tab
                // صورة للصفحة اللي كنت فيها قبل ما نفتح البحث: تبان تحت البحث وانت تسحب للرجوع
                searchBackdrop = WindowSnapshot.capture()
            } else if tab == .search {
                searchBackdrop = nil
            }
            tab = newTab
        }
    }

    /// شكل الصفحة اللي كنت فيها لحظة فتحت البحث (تنمسح أول ما تطلع من البحث)
    private(set) var searchBackdrop: UIImage?

    /// التبويب اللي كنت فيه قبل البحث (السحب من الطرف يرجّعك له بنفس حالته)
    private(set) var tabBeforeSearch: AppTab = .home

    func goBackFromSearch() {
        guard tab == .search else { return }
        // التبديل لحظي وبدون أي تلاشي من النظام: الصفحة اللي سحبتها وصلت مكانها، فما لازم يتحرك شي ثاني.
        // قبل كان التبويب يتلاشى ربع ثانية، فتطلع نسخة شفافة من الصفحة وتختفي
        UIView.setAnimationsEnabled(false)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { tab = tabBeforeSearch }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            UIView.setAnimationsEnabled(true)
            // صورة الصفحة اللي تحت البحث تنشال بعد ما يخلص التبديل (مو بنفس اللحظة)
            try? await Task.sleep(for: .milliseconds(600))
            if self.tab != .search { self.searchBackdrop = nil }
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
                let id = parts[1...].joined(separator: "/")
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
                tab = .home
                paths[.home] = NavigationPath([MediaRef(id: id, kind: kind, name: name)])
            }
        }
    }

    /// اختصار من Siri أو تطبيق الاختصارات
    func runPendingIntent() {
        guard let intent = PendingIntent.take() else { return }
        switch intent {
        case .search:
            select(.search)
        case .library:
            select(.library)
        case .resume:
            // النواة لسا ما اشتغلت: نرجّع الطلب ويتنفّذ أول ما تجهز
            guard core != nil, ready else { PendingIntent.resume.store(); return }
            if continueWatching.isEmpty { refreshContinueWatching() }
            guard let p = continueWatching.first else { select(.library); return }
            tab = .home
            paths[.home] = NavigationPath([MediaRef(id: p.mediaId, kind: p.kind, name: p.title, poster: p.poster)])
        }
    }

    // MARK: - المكتبة والتقدّم

    func refreshContinueWatching() {
        continueWatching = core?.continueWatching() ?? []
        refreshWidget()
    }

    func removeProgress(_ mediaId: String) {
        try? core?.removeProgress(mediaId: mediaId)
        refreshContinueWatching()
    }

    func isInLibrary(_ id: String) -> Bool {
        (try? core?.inLibrary(mediaId: id)) ?? false
    }

    /// يضيف أو يشيل من المكتبة، ويرجّع الحالة الجديدة
    @discardableResult
    func toggleLibrary(_ ref: MediaRef) -> Bool {
        guard let core else { return false }
        do {
            if isInLibrary(ref.id) {
                try core.removeFromLibrary(mediaId: ref.id)
                libraryVersion += 1
                showToast(L("انشال من مكتبتي"))
                return false
            }
            try core.addToLibrary(item: LibraryItem(mediaId: ref.id, kind: ref.kind, title: ref.name, poster: ref.poster, addedAt: CoreClient.now))
            libraryVersion += 1
            showToast(L("انضاف لمكتبتي"))
            return true
        } catch {
            showToast(CoreClient.message(for: error))
            return isInLibrary(ref.id)
        }
    }

    // MARK: - الرسائل

    func showToast(_ text: String) {
        toastTask?.cancel()
        // الحركة كلها في ToastHost، هنا بس نغيّر القيمة
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - ويدجت كمّل المشاهدة

    func refreshWidget() {
        WidgetBridge.write(continueWatching, language: language)
    }
}
