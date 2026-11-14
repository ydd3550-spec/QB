// اختبار الاستعادة: تعليق، انقطاع شبكة، خطأ ورابط جديد، إعادة تشغيل خادم التحويل، VLC من جديد،
// والصورة الواقفة مع وقت ماشي. كل حالة لازم تكمّل من نفس المكان ومو من الصفر. يشتغل على Linux أو Mac:
//   swiftc App/QB/Features/Player/PlaybackRecovery.swift scripts/recovery-test/main.swift -o /tmp/recovery && /tmp/recovery
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("PASS  \(what)") } else { failures += 1; print("FAIL  \(what) (line \(line))") }
}

/// مشغّل وهمي مربوط بنفس المنطق اللي يستخدمه PlayerModel: كل 0.2 ثانية يبلّغ وقت وحالة،
/// وكل إعادة تحميل تاخذ مكان الاستكمال من tracker.position (مثل resumePoint بالموديل)
struct Sim {
    var tracker = ResumeTracker()
    var now = 0.0
    var engineTime = 0.0
    var shown: [Double] = []
    var loads: [Double] = []
    var corrections: [Double] = []

    mutating func tick(playing: Bool, advance: Bool) {
        now += 0.2
        if advance { engineTime += 0.2 }
        let r = tracker.observe(engineTime, playing: playing, now: now)
        shown.append(r.display)
        if let c = r.correctTo { corrections.append(c); engineTime = c }   // الموديل يسوي engine.seek(to: c)
    }
    mutating func play(_ seconds: Double) { for _ in 0..<Int(seconds * 5) { tick(playing: true, advance: true) } }
    /// مشغّل جديد: يبدأ يبلّغ صفر وهو يحمّل، وبعدين ينزل على مكان الاستكمال
    mutating func reload(loadingTicks: Int = 10) {
        tracker.engineRestarted()
        let at = tracker.position
        loads.append(at)
        engineTime = 0
        for _ in 0..<loadingTicks { tick(playing: false, advance: false) }
        engineTime = at
    }
}

func near(_ a: Double, _ b: Double, _ tol: Double = 2) -> Bool { abs(a - b) <= tol }

// 1) تعليق وبعدين استعادة: 10 دقايق تشغيل، يعلّق 25 ثانية والشبكة ساكتة، ينعاد التحميل
do {
    var s = Sim()
    s.play(600)
    var stalled = 0.0
    while !StallPolicy.shouldReload(stalled: stalled, quiet: stalled, justReturned: false) {
        s.tick(playing: false, advance: false); stalled += 0.2
    }
    check(near(stalled, 20, 0.3), "stall: reload only after 20s with no data (was \(stalled))")
    s.reload()
    s.play(5)
    check(near(s.loads.last!, 600), "stall: reload starts at the saved position \(s.loads.last!), not 0")
    check(s.shown.dropFirst(10).allSatisfy { $0 > 1 }, "stall: the shown time never drops to 0")
    check(near(s.tracker.position, 605), "stall: playback carries on from there (\(s.tracker.position))")
}

// 2) شبكة ضعيفة: واقف بس البيانات توصل = ننتظر وما نعيد التحميل
do {
    var reloadAt: Double?
    for i in 0..<500 {
        let stalled = Double(i) * 0.2
        if StallPolicy.shouldReload(stalled: stalled, quiet: 1.0, justReturned: false) { reloadAt = stalled; break }
    }
    check(reloadAt.map { $0 >= 119.8 } ?? true, "weak network: waits while data still arrives (no reload before 2 min)")
    check(!StallPolicy.shouldReload(stalled: 5, quiet: 5, justReturned: true), "back from background: not before 6s")
    check(StallPolicy.shouldReload(stalled: 6.2, quiet: 6.2, justReturned: true), "back from background: dead connection reloads after 6s")
    check(!StallPolicy.shouldReload(stalled: 10, quiet: 0.5, justReturned: true), "back from background: data arriving = wait")
}

// 3) انقطاع الشبكة مع VLC: يقول "خلص" وهو بالنص -> مو نهاية، نعيد التحميل من نفس المكان
do {
    var s = Sim()
    s.play(1234)
    check(!PlaybackEnd.isReal(position: s.tracker.position, duration: 5400), "network drop: VLC 'ended' at 20:34 of 90:00 is not a real end")
    s.reload()
    s.play(3)
    check(near(s.loads.last!, 1234), "network drop: reload resumes at \(s.loads.last!), not 0")
    check(PlaybackEnd.isReal(position: 5390, duration: 5400), "real end: 10s before the end counts as the end")
    check(PlaybackEnd.isReal(position: 5300, duration: 5400), "real end: inside the credits (2%) counts as the end")
    check(!PlaybackEnd.isReal(position: 0, duration: 5400), "network drop at the start is not a real end")
}

// 4) خطأ وبعدين محاولة برابط جديد: قبل الخطأ المشغّل بلّغ صفر (انهار)، والرابط الجديد ياخذ المكان الصحيح
do {
    var s = Sim()
    s.play(2000)
    s.engineTime = 0
    s.tick(playing: false, advance: false)
    s.tick(playing: true, advance: false)
    check(near(s.tracker.position, 2000), "error: a 0 reported while failing is ignored (\(s.tracker.position))")
    s.reload(loadingTicks: 25)   // يدوّر رابط جديد 5 ثواني
    s.play(2)
    check(near(s.loads.last!, 2000), "error + new URL: retry resumes at \(s.loads.last!), not 0")
    check(s.shown.dropFirst(10).allSatisfy { $0 > 1 }, "error + new URL: the bar never shows 0")
}

// 5) خادم التحويل رجع يشتغل والمشغّل بدأ من الصفر لحاله (يشتغل فعلًا من 0): ينمسك ويرجع لمكانه
do {
    var s = Sim()
    s.play(900)
    s.engineTime = 0
    s.play(3)
    check(s.corrections.count == 1 && near(s.corrections[0], 900), "remux restart: playing from 0 by itself is caught and sent back to \(s.corrections.first ?? -1)")
    check(near(s.tracker.position, 902, 2.5), "remux restart: carries on from the saved position (\(s.tracker.position))")
    check(s.shown.dropFirst(5 * 900).allSatisfy { $0 >= 899 }, "remux restart: the bar never shows the restart from 0")
    check(s.shown.suffix(20).allSatisfy { $0 >= 899 }, "remux restart: the bar never jumps back to 0")
}

// 6) VLC ينبني من جديد لما ترجع للتطبيق: وهو بالخلفية يبلّغ 0 ومو شغّال
do {
    var s = Sim()
    s.play(3000)
    s.engineTime = 0
    for _ in 0..<50 { s.tick(playing: false, advance: false) }   // 10 ثواني بالخلفية
    s.reload()
    s.play(2)
    check(near(s.loads.last!, 3000), "VLC rebuild: new VLC media starts at \(s.loads.last!), not 0")
    check(s.corrections.isEmpty, "VLC rebuild: lands in place, nothing to correct")
}

// 7) المستخدم نفسه رجع للبداية: هذا ينحترم وما ينرجّع
do {
    var s = Sim()
    s.play(700)
    s.tracker.userSeek(to: 0, now: s.now)
    s.engineTime = 0
    s.play(10)
    check(s.corrections.isEmpty && near(s.tracker.position, 10), "start over by the user: honoured (\(s.tracker.position))")
    s.tracker.userSeek(to: 300, now: s.now)
    s.engineTime = 300
    s.play(1)
    check(near(s.tracker.position, 301), "user seek forward: honoured")
}

// 8) الصورة واقفة والوقت ماشي: نكتشفها، الترجمة توقف عند آخر إطار، والاستعادة من آخر إطار
do {
    var w = FrameWatch()
    var frames = 0
    var t = 400.0
    var now = 0.0
    var verdicts: [FrameWatch.Verdict] = []
    for _ in 0..<50 { now += 0.2; t += 0.2; frames += 5; verdicts.append(w.observe(frames: frames, time: t, playing: true, now: now)) }
    check(verdicts.allSatisfy { $0 == .fine }, "frozen video: normal playback is fine")
    let frozeAt = t
    var firstLag: Double?
    var firstFrozen: Double?
    for _ in 0..<25 {
        now += 0.2; t += 0.2
        let v = w.observe(frames: frames, time: t, playing: true, now: now)
        if v == .lagging, firstLag == nil { firstLag = t - frozeAt }
        if v == .frozen, firstFrozen == nil { firstFrozen = t - frozeAt }
    }
    check((firstLag ?? 99) <= 0.8, "frozen video: subtitles hold within 0.8s (\(firstLag ?? -1))")
    check((firstFrozen ?? 99) <= 3.1, "frozen video: detected within ~3s (\(firstFrozen ?? -1))")
    check(near(w.frameTime, frozeAt, 0.01), "frozen video: subtitles stay at the last shown frame \(w.frameTime)")
    // الاستعادة تكمّل من آخر إطار انعرض (الموديل يسوي userSeek له)
    var s = Sim()
    s.play(t)
    s.tracker.userSeek(to: w.frameTime, now: s.now)
    s.reload()
    check(near(s.loads.last!, frozeAt) && s.loads.last! > 1, "frozen video: recovery resumes at the last frame \(s.loads.last!), never 0")
    // موقّف أو يحمّل: مو تجمّد
    var p = FrameWatch()
    _ = p.observe(frames: 1, time: 10, playing: true, now: 0)
    _ = p.observe(frames: 2, time: 10.2, playing: true, now: 0.2)
    var any = false
    for i in 0..<30 { if p.observe(frames: 2, time: 10.2, playing: false, now: 0.4 + Double(i) * 0.2) != .fine { any = true } }
    check(!any, "paused or buffering is not a frozen picture")
    var audio = FrameWatch()
    var anyAudio = false
    for i in 0..<30 { if audio.observe(frames: 0, time: Double(i) * 0.2, playing: true, now: Double(i) * 0.2) != .fine { anyAudio = true } }
    check(!anyAudio, "audio-only (no frames ever) is not a frozen picture")
}

// 9) الترجمة ما تنزل: المشغّل الجديد يبلّغ مقاس صفر وهو يحمّل، نبقى بآخر مقاس
do {
    var size = (w: 1920.0, h: 1080.0)
    for reported in [(w: 0.0, h: 0.0), (w: 0.0, h: 0.0), (w: 1.0, h: 0.0)] { size = StickyVideoSize.merge(current: size, reported: reported) }
    check(size == (w: 1920, h: 1080), "subtitles: a reload's zero video size keeps the last size (subtitle position unchanged)")
    size = StickyVideoSize.merge(current: size, reported: (w: 1280, h: 536))
    check(size == (w: 1280, h: 536), "subtitles: a real new size is taken")
}

// 10) عدّاد الإطارات يرجع لصفر بعد ما ينفتح المصدر من جديد: ما نحسبها صورة واقفة
do {
    var w = FrameWatch()
    var frozen = false
    for i in 0..<25 { if w.observe(frames: 50 + i * 2, time: Double(i) * 0.2, playing: true, now: Double(i) * 0.2) == .frozen { frozen = true } }
    for i in 0..<25 { if w.observe(frames: i, time: 5 + Double(i) * 0.2, playing: true, now: 5 + Double(i) * 0.2) == .frozen { frozen = true } }
    check(!frozen, "reopen: the frame counter going back to 0 is not a frozen picture")

    var z = FrameWatch()
    _ = z.observe(frames: 40, time: 0, playing: true, now: 0)
    _ = z.observe(frames: 42, time: 0.2, playing: true, now: 0.2)
    var caught = false
    for i in 0..<40 { if z.observe(frames: 0, time: 1 + Double(i) * 0.2, playing: true, now: 1 + Double(i) * 0.2) == .frozen { caught = true } }
    check(caught, "reopen: a picture that never comes back after the reopen is caught (not blind)")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
