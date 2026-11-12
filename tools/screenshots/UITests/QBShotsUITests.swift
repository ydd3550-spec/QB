import XCTest

/// جولة صور حقيقية على المحاكي. ما تغيّر شي في التطبيق: تضغط وتصوّر بس.
/// كل صورة تنحفظ مرفق في نتيجة الاختبار باسمها، والسكربت يطلّعها PNG.
final class QBShotsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testTour() throws {
        let t = Tour(test: self)
        t.run()
    }
}

@MainActor
final class Tour {
    let test: XCTestCase
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let archiveAddon = "https://stremio-archive.vercel.app/manifest.json"

    init(test: XCTestCase) { self.test = test }

    // MARK: - أدوات

    func log(_ s: String) { print("TOUR: \(s)") }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        test.add(a)
        log("SHOT \(name)")
    }

    func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    func first(_ q: XCUIElementQuery, _ format: String, _ args: CVarArg...) -> XCUIElement {
        q.matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    @discardableResult
    func tap(_ e: XCUIElement, _ what: String, timeout: Double = 6) -> Bool {
        if e.waitForExistence(timeout: timeout), e.isHittable {
            e.tap()
            return true
        }
        if e.exists {
            e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
        log("MISSING \(what)")
        return false
    }

    /// أعرض زر بهالاسم (زر التشغيل الكبير، مو زر المشغّل المصغّر)
    func tapBiggest(_ label: String) -> Bool {
        _ = first(app.buttons, "label == %@", label).waitForExistence(timeout: 6)
        let all = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        guard let best = all.filter({ $0.exists }).max(by: { $0.frame.width < $1.frame.width }) else {
            log("MISSING big button \(label)")
            return false
        }
        if best.isHittable { best.tap() } else { best.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        return true
    }

    func tab(_ label: String, index: Int) {
        let byLabel = first(app.buttons, "label == %@", label)
        if byLabel.waitForExistence(timeout: 5) {
            byLabel.tap()
            return
        }
        let bars = app.tabBars.buttons
        if bars.count > index {
            bars.element(boundBy: index).tap()
        } else {
            log("MISSING tab \(label)")
        }
    }

    func open(_ s: String) {
        guard let url = URL(string: s) else { return }
        app.open(url)
        let ok = first(springboard.buttons, "label IN %@", ["Open", "فتح"])
        if ok.waitForExistence(timeout: 2) { ok.tap() }
    }

    func dismissAlerts() {
        for l in ["Allow", "OK", "Allow While Using App", "السماح", "حسنًا", "تمام"] {
            let b = springboard.alerts.buttons[l]
            if b.exists { b.tap() }
        }
    }

    func swipeUp(_ times: Int = 1) {
        for _ in 0..<times {
            app.swipeUp(velocity: .slow)
            pause(1)
        }
    }

    // MARK: - الجولة

    func run() {
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        app.launch()
        pause(18)
        dismissAlerts()
        shot("01_home")
        swipeUp(2)
        pause(3)
        shot("02_home_shelves")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)

        // الإعدادات والإضافات
        tab("الإعدادات", index: 3)
        pause(2)
        shot("03_settings")
        swipeUp(1)
        shot("04_settings_more")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        let addonsRow = first(app.buttons, "label BEGINSWITH %@", "الإضافات")
        if !tap(addonsRow, "addons row") {
            tap(app.staticTexts["الإضافات"], "addons text")
        }
        pause(3)
        shot("05_addons")
        // نثبّت إضافة Internet Archive (أفلام ملكية عامة بروابط MP4) عشان نوصل للمشغّل
        let field = app.textFields.firstMatch
        if tap(field, "addon url field") {
            field.typeText(archiveAddon)
            pause(1)
            tap(first(app.buttons, "label == %@", "تثبيت"), "install button")
            pause(10)
            shot("06_addons_installed")
        }

        // اكتشف
        tab("اكتشف", index: 1)
        pause(10)
        shot("07_discover")

        // البحث
        tab("البحث", index: 4)
        pause(2)
        shot("08_search_empty")
        let search = app.searchFields.firstMatch
        if tap(search, "search field") {
            search.typeText("Batman\n")
            pause(12)
            shot("09_search_results")
        }

        // صفحة فيلم (Cinemeta)
        open("qb://title/movie/tt1877830?name=The%20Batman")
        pause(10)
        shot("10_details_movie")
        tap(first(app.buttons, "label == %@", "أضف لمكتبتي"), "add to library", timeout: 3)
        pause(1.5)
        shot("11_details_added")
        swipeUp(2)
        pause(3)
        shot("12_details_more")

        // صفحة مسلسل مع المواسم
        open("qb://title/series/tt0903747?name=Breaking%20Bad")
        pause(10)
        tap(first(app.buttons, "label == %@", "أضف لمكتبتي"), "add series to library", timeout: 3)
        pause(1.5)
        shot("13_details_series")
        swipeUp(2)
        pause(3)
        shot("14_series_episodes")

        // المشغّل: فيلم ملكية عامة من Internet Archive
        open("qb://title/movie/ia:charlie_chaplin_film_fest?name=Charlie%20Chaplin%20Festival")
        pause(10)
        shot("15_details_archive")
        if tapBiggest("تشغيل") {
            pause(16)
            shot("16_player")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            pause(1.2)
            shot("17_player_controls")
            let sources = first(app.buttons, "label CONTAINS %@", "المصادر")
            if sources.waitForExistence(timeout: 2) {
                sources.tap()
                pause(3)
                shot("18_player_sources")
                app.swipeDown(velocity: .fast)
                pause(1.5)
            }
            pause(8)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            pause(1)
            if !tap(first(app.buttons, "label == %@", "تصغير"), "minimize", timeout: 3) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
                pause(1)
                tap(first(app.buttons, "label == %@", "تصغير"), "minimize retry", timeout: 3)
            }
            pause(3)
            shot("19_mini_player")
        }

        // الرئيسية بعد المشاهدة (كمّل المشاهدة)
        tab("الرئيسية", index: 0)
        pause(1)
        tab("الرئيسية", index: 0)
        pause(1)
        tab("الرئيسية", index: 0)
        pause(5)
        shot("20_home_after_watch")
        swipeUp(1)
        pause(2)
        shot("21_home_continue")

        // مكتبتي
        tab("مكتبتي", index: 2)
        pause(4)
        shot("22_library")

        // سجل المشاهدة
        tab("الإعدادات", index: 3)
        pause(1)
        tab("الإعدادات", index: 3)
        pause(1)
        if tap(first(app.buttons, "label BEGINSWITH %@", "سجل المشاهدة"), "history row") {
            pause(3)
            shot("23_history")
        }

        widget()
    }

    // MARK: - الويدجت (محاولة على الشاشة الرئيسية للمحاكي)

    func widget() {
        XCUIDevice.shared.press(.home)
        pause(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 1.6)
        pause(1.5)
        let editHome = first(springboard.buttons, "label IN %@", ["Edit Home Screen", "تعديل الشاشة الرئيسية"])
        if editHome.exists { editHome.tap(); pause(1.5) }
        shot("zz_widget_step1")
        let edit = first(springboard.buttons, "label IN %@", ["Edit", "تعديل"])
        if edit.waitForExistence(timeout: 3) { edit.tap(); pause(1.2) }
        let addWidget = first(springboard.buttons, "label IN %@", ["Add Widget", "إضافة أداة", "Add"])
        if !tap(addWidget, "springboard add widget", timeout: 4) {
            log(springboard.debugDescription)
            shot("zz_widget_fail_menu")
            XCUIDevice.shared.press(.home)
            return
        }
        pause(2.5)
        shot("zz_widget_gallery")
        let search = springboard.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("QB")
            pause(3)
        }
        shot("zz_widget_search")
        let entry = first(springboard.cells, "label CONTAINS[c] %@", "QB")
        var opened = tap(entry, "QB in gallery", timeout: 4)
        if !opened {
            let any = first(springboard.descendants(matching: .any), "label CONTAINS[c] %@ AND elementType != %d", "QB", XCUIElement.ElementType.searchField.rawValue)
            opened = tap(any, "QB element in gallery", timeout: 3)
        }
        if !opened {
            log(springboard.debugDescription)
            XCUIDevice.shared.press(.home)
            return
        }
        pause(3)
        shot("zz_widget_preview")
        let add = first(springboard.buttons, "label IN %@", ["Add Widget", "إضافة أداة"])
        if !tap(add, "add widget button", timeout: 4) {
            log(springboard.debugDescription)
            XCUIDevice.shared.press(.home)
            return
        }
        pause(2)
        let done = first(springboard.buttons, "label IN %@", ["Done", "تم"])
        if done.waitForExistence(timeout: 3) { done.tap() } else { XCUIDevice.shared.press(.home) }
        pause(4)
        shot("24_widget")
    }
}
