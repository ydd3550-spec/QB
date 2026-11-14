import XCTest

/// فحص المشغّل على المحاكي: نفتح فيلم، نشغّله، نسحبه لتحت (وبعدين نقفله بـ X)،
/// ونقارن الصفحة اللي تحته قبل وبعد. كل صورة ونص ينحفظ مرفق، والسكربت يطلّعها.
final class QBPlayerDismissUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    @MainActor
    func testDismissLeavesPageIntact() throws {
        let c = Check(test: self)
        c.run()
    }
}

@MainActor
final class Check {
    let test: XCTestCase
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let archiveAddon = "https://stremio-archive.vercel.app/manifest.json"
    let title = "Charlie Chaplin Festival"

    init(test: XCTestCase) { self.test = test }

    func log(_ s: String) { print("CHECK: \(s)") }
    func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        test.add(a)
        log("SHOT \(name)")
    }

    /// شجرة العناصر كاملة كنص، وعدد مرات ظهور العنوان (لو تكرر المحتوى يزيد العدد)
    func tree(_ name: String) {
        let d = app.debugDescription
        let a = XCTAttachment(string: d)
        a.name = name + ".txt"
        a.lifetime = .keepAlways
        test.add(a)
        let lines = d.split(separator: "\n")
        let titleCount = lines.filter { $0.contains(title) }.count
        let sources = lines.filter { $0.contains("Internet Archive") && $0.contains("Button") }.count
        let scrolls = lines.filter { $0.contains("ScrollView") }.count
        let navBars = lines.filter { $0.contains("NavigationBar") }.count
        log("TREE \(name): lines=\(lines.count) title=\(titleCount) sourceButtons=\(sources) scrollViews=\(scrolls) navBars=\(navBars)")
    }

    func first(_ q: XCUIElementQuery, _ format: String, _ args: CVarArg...) -> XCUIElement {
        q.matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    @discardableResult
    func tap(_ e: XCUIElement, _ what: String, timeout: Double = 6) -> Bool {
        if e.waitForExistence(timeout: timeout), e.isHittable { e.tap(); return true }
        if e.exists { e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); return true }
        log("MISSING \(what)")
        return false
    }

    func open(_ s: String) {
        guard let url = URL(string: s) else { return }
        app.open(url)
        let ok = first(springboard.buttons, "label IN %@", ["Open", "فتح"])
        if ok.waitForExistence(timeout: 2) { ok.tap() }
    }

    var screen: XCUICoordinate { springboard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)) }
    func at(_ x: Double, _ y: Double) -> XCUICoordinate { screen.withOffset(CGVector(dx: x, dy: y)) }
    var size: CGSize { springboard.frame.size }

    /// يشغّل أول مصدر 240p (أو أي مصدر) من صفحة الفيلم
    func playSource() -> Bool {
        let row = first(app.buttons, "label CONTAINS %@ AND label CONTAINS %@", "240p", "Internet Archive")
        if row.waitForExistence(timeout: 8) {
            if !row.isHittable { app.swipeUp(velocity: .slow); pause(1) }
            row.tap()
            return true
        }
        let any = first(app.buttons, "label CONTAINS %@", "Internet Archive")
        return tap(any, "any source row")
    }

    /// يوقف الفيديو مؤقت عشان التطبيق يهدأ ونقدر نقرأ العناصر
    func pausePlayback() {
        at(size.width / 2, size.height * 0.36).tap()   // تطلع الأدوات
        pause(0.8)
        at(size.width / 2, size.height / 2).tap()      // زر الإيقاف بالنص
        pause(1.5)
    }

    /// سحب لتحت من أعلى الفيديو، مع صور سريعة بعده عشان نشوف حركة الخروج
    func swipeDownPlayer(_ tag: String) {
        at(size.width / 2, size.height * 0.28).press(forDuration: 0.05, thenDragTo: at(size.width / 2, size.height * 0.86))
        for i in 0..<8 {
            shot("\(tag)_anim_\(i)")
            pause(0.12)
        }
        pause(3)
    }

    func run() {
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        app.launch()
        pause(15)
        log("screen \(size)")

        // الإعدادات ← الإضافات ← تثبيت Internet Archive
        let settings = first(app.buttons, "label == %@", "الإعدادات")
        if settings.waitForExistence(timeout: 6) { settings.tap() } else if app.tabBars.buttons.count > 3 { app.tabBars.buttons.element(boundBy: 3).tap() }
        pause(2)
        let addonsRow = first(app.buttons, "label BEGINSWITH %@", "الإضافات")
        if !tap(addonsRow, "addons row") { tap(app.staticTexts["الإضافات"], "addons text") }
        pause(3)
        let field = app.textFields.firstMatch
        if tap(field, "addon url field") {
            field.typeText(archiveAddon)
            pause(1)
            tap(first(app.buttons, "label == %@", "تثبيت"), "install button")
            pause(10)
        }
        let home = first(app.buttons, "label == %@", "الرئيسية")
        if home.exists { home.tap() }
        pause(2)

        // صفحة الفيلم
        open("qb://title/movie/ia:charlie_chaplin_film_fest?name=Charlie%20Chaplin%20Festival")
        pause(12)
        shot("a0_details_before")
        tree("a0_details_before")

        // 1) تشغيل ثم سحب لتحت
        guard playSource() else { log("NO SOURCE"); return }
        pause(4)
        shot("a1_player_loading")
        pause(16)
        shot("a2_player_playing")
        pausePlayback()
        shot("a3_player_paused")
        swipeDownPlayer("a4_swipe")
        shot("a5_after_swipe")
        tree("a5_after_swipe")
        pause(4)
        shot("a6_after_swipe_settled")
        tree("a6_after_swipe_settled")

        // 2) نفتح المشغّل من المصغّر ونقفله بـ X
        let mini = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY > size.height * 0.75 }.first
        if let mini { mini.tap() } else { log("MISSING mini player"); at(size.width / 2, size.height - 110).tap() }
        pause(3)
        shot("b0_player_expanded")
        if !tap(first(app.buttons, "label == %@", "إغلاق"), "close X", timeout: 4) {
            at(size.width - 40, 75).tap()
        }
        pause(4)
        shot("b1_after_close")
        tree("b1_after_close")

        // 3) مرة ثانية: تشغيل وسحب (نشوف لو التكرار يتراكم)
        if playSource() {
            pause(18)
            pausePlayback()
            swipeDownPlayer("c0_swipe")
            shot("c1_after_second_swipe")
            tree("c1_after_second_swipe")
        }

        // 4) تدوير الجهاز وقت التشغيل
        let mini2 = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY > size.height * 0.75 }.first
        if let mini2 { mini2.tap(); pause(3) }
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(4)
        shot("d0_player_landscape")
        XCUIDevice.shared.orientation = .portrait
        pause(3)
        shot("d1_player_portrait_again")
        app.terminate()
    }
}
