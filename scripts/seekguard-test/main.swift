// اختبار SeekGuard: تقديم وبعده أوقات قديمة من المشغّل. يشتغل على Linux أو Mac:
//   swiftc App/QB/Features/Player/SeekGuard.swift scripts/seekguard-test/main.swift -o /tmp/seekguard && /tmp/seekguard
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("PASS  \(what)") } else { failures += 1; print("FAIL  \(what) (line \(line))") }
}

/// يمشّي سلسلة أوقات مبلّغة ويرجع اللي انعرض
func run(_ g: inout SeekGuard, _ reports: [(t: TimeInterval, reported: Double)]) -> [Double] {
    reports.map { g.resolve(reported: $0.reported, now: $0.t) }
}

func neverBack(_ shown: [Double]) -> Bool { zip(shown, shown.dropFirst()).allSatisfy { $1 >= $0 - 0.0001 } }

// 1) VLC: +10 من 100، المشغّل يكمّل يبلّغ 100.2 و100.4 ... لمدة 3 ثواني (إعادة تحويل)، وبعدين 110.1
do {
    var g = SeekGuard()
    g.begin(110, now: 0)
    var reports: [(TimeInterval, Double)] = []
    var t = 0.0
    var old = 100.0
    while t < 3 { t += 0.2; old += 0.2; reports.append((t, old)) }
    reports.append((3.2, 110.1)); reports.append((3.4, 110.3)); reports.append((3.6, 110.5))
    let shown = run(&g, reports.map { (t: $0.0, reported: $0.1) })
    check(shown.prefix(15).allSatisfy { $0 == 110 }, "VLC: old times while seeking show the target, not 100.x")
    check(neverBack(shown), "VLC: the bar never moves back")
    check(!g.isPending && shown.last == 110.5, "VLC: after it arrives the real time takes over")
}

// 2) ضغطات متتالية: +10 ثلاث مرات قبل ما يخلص التقديم = 130 (مو 110 من المكان القديم)
do {
    var g = SeekGuard()
    var current = 100.0
    for i in 0..<3 {
        let next = g.base(current: current) + 10
        g.begin(next, now: Double(i) * 0.3)
        current = g.resolve(reported: 100.0 + Double(i) * 0.3, now: Double(i) * 0.3 + 0.1)
    }
    check(g.target == 130 && current == 130, "Repeated double taps stack on the pending target (130)")
}

// 3) AVPlayer: التأكيد وصل والمشغّل نزل قبل الهدف بنص ثانية وهو واقف
do {
    var g = SeekGuard()
    g.begin(60, now: 0)
    let a = g.resolve(reported: 30, now: 0.1)          // وقت قديم من المراقب
    g.confirm(60, now: 0.5)
    let b = g.resolve(reported: 59.6, now: 0.6)        // نزل على أقرب إطار قبل الهدف
    let c = g.resolve(reported: 59.6, now: 1.5)
    let d = g.resolve(reported: 60.1, now: 1.7)        // بدأ يشتغل
    check(a == 60 && b == 60 && c == 60 && d == 60.1, "AVPlayer: old observer time ignored, no step back after landing slightly early")
    check(!g.isPending, "AVPlayer: guard clears once playback passes the target")
}

// 4) VLC: وقت قديم يوصل متأخر بعد ما حسبناه وصل
do {
    var g = SeekGuard()
    g.begin(200, now: 0)
    let shown = run(&g, [(0.2, 199.4), (0.4, 120.0), (0.6, 199.6), (0.8, 200.2)])
    check(shown == [200, 200, 200, 200.2], "VLC: a late stale update after arrival is ignored")
}

// 5) رجوع لورا (-10): نفس الحماية بالاتجاه الثاني
do {
    var g = SeekGuard()
    g.begin(90, now: 0)
    let shown = run(&g, [(0.2, 100.2), (0.4, 100.4), (0.6, 90.0), (0.8, 90.2)])
    check(shown == [90, 90, 90, 90.2], "Skip back: old later times don't pull the bar forward again")
}

// 6) التقديم ما خلص أبد: بعد المهلة نصدّق المشغّل (ما يعلق الشريط للأبد)
do {
    var g = SeekGuard()
    g.begin(500, now: 0)
    let a = g.resolve(reported: 10, now: 5)
    let b = g.resolve(reported: 10, now: 21)
    check(a == 500 && b == 10 && !g.isPending, "Timeout: after 20 s the player's time is trusted again")
}

// 7) تأكيد لتقديم قديم (انلغى بتقديم أحدث) ما ينحسب
do {
    var g = SeekGuard()
    g.begin(40, now: 0)
    g.begin(50, now: 0.2)
    g.confirm(40, now: 0.3)
    let a = g.resolve(reported: 40.1, now: 0.4)
    check(a == 50, "A completion from an older, replaced seek is ignored")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
