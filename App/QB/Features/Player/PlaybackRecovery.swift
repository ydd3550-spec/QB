import Foundation

// منطق الاستعادة كله بمكان واحد وبدون UIKit، عشان ينختبر على أي جهاز (scripts/recovery-test).
// القاعدة: فيه مصدر واحد لمكان التشغيل (ResumeTracker)، وكل إعادة تحميل أو استعادة أو مصدر ثاني
// أو رجوع للتطبيق تبدأ منه هو، مو من الوقت اللي يقوله مشغّل جديد لسه ما حمّل (اللي يكون صفر).

/// آخر مكان صحيح وصله التشغيل فعلًا. ما يتحرك قدام إلا بتشغيل حقيقي (الوقت يمشي خطوات طبيعية
/// والمشغّل شغّال)، ويتحرك لأي مكان بتقديم أو ترجيع من المستخدم. التعليق والأخطاء والمشغّل الجديد
/// اللي يبلّغ صفر ما يقدرون يرجعونه ورا أبد.
struct ResumeTracker: Equatable {
    /// آخر مكان صحيح (ثواني)
    private(set) var position: Double
    private var lastReported: Double?
    private var userSeekAt: Double = -.infinity
    private var behindSince: Double?
    /// كم مرة رجّعنا المشغّل لمكانه بهالتحميل (عشان ما ندخل بحلقة)
    private(set) var corrections = 0

    /// أكبر خطوة طبيعية بين قراءتين متتاليتين (القراءة كل 0.2 ثانية، حتى سرعة 2x تبقى تحتها بكثير)
    static let maxStep: Double = 4
    /// المشغّل يشتغل ورا آخر مكان صحيح بأكثر من كذا = رجع للبداية لحاله
    static let behindLimit: Double = 8
    /// كم ثانية لازم يبقى ورا قبل ما نرجّعه
    static let behindFor: Double = 1
    static let maxCorrections = 3

    init(position: Double = 0) { self.position = Self.clean(position) }

    private static func clean(_ p: Double) -> Double { p.isFinite ? max(0, p) : 0 }

    /// فيلم أو حلقة جديدة، أو "من البداية" باختيار المستخدم
    mutating func reset(to p: Double) {
        position = Self.clean(p)
        lastReported = nil
        userSeekAt = -.infinity
        behindSince = nil
        corrections = 0
    }

    /// تقديم أو ترجيع من المستخدم: يقدر يروح ورا، حتى للصفر
    mutating func userSeek(to p: Double, now: Double) {
        position = Self.clean(p)
        userSeekAt = now
        lastReported = nil
        behindSince = nil
    }

    /// مشغّل جديد بيبدأ (استعادة، تحديث، رابط جديد، مصدر ثاني، VLC من جديد). مكان الاستكمال هو `position`
    mutating func engineRestarted() {
        lastReported = nil
        behindSince = nil
        corrections = 0
    }

    struct Reading: Equatable {
        /// الوقت اللي ينعرض بالشريط وينحفظ
        var display: Double
        /// المشغّل يشتغل بعيد ورا آخر مكان صحيح: رجّعه لهالمكان
        var correctTo: Double?
    }

    /// قراءة وقت من المشغّل. playing = المشغّل يقول إنه شغّال (مو تحميل ولا واقف ولا خطأ)
    @discardableResult
    mutating func observe(_ t: Double, playing: Bool, now: Double) -> Reading {
        guard t.isFinite, t >= 0 else { return Reading(display: position) }
        let last = lastReported
        lastReported = t
        let stepping = playing && last != nil && t > last! && t - last! <= Self.maxStep
        guard stepping else {
            behindSince = nil
            return Reading(display: position)
        }
        if t >= position - 1.5 {
            // تشغيل حقيقي من حول آخر مكان صحيح (أو قفزة قدام كمّل منها المشغّل)
            if t > position { position = t }
            behindSince = nil
            return Reading(display: position)
        }
        // يشتغل فعلًا بس ورا آخر مكان صحيح
        let recentSeek = now - userSeekAt < 4
        guard !recentSeek, position - t > Self.behindLimit else { return Reading(display: position) }
        if behindSince == nil { behindSince = now }
        guard now - behindSince! >= Self.behindFor, corrections < Self.maxCorrections else {
            return Reading(display: position)
        }
        corrections += 1
        behindSince = nil
        lastReported = nil
        return Reading(display: position, correctTo: position)
    }
}

/// المشغّل قال "خلص": هل خلص الفيلم فعلًا ولا انقطع البث؟
/// VLC مع بث HTTP لما تنقطع الشبكة يوصل لنهاية الملف ويقول "خلص" وهو بالنص، وكان هذا يمسح
/// مكان المشاهدة ويخلّي زر التشغيل يعيد الفيلم من البداية.
enum PlaybackEnd {
    static func isReal(position: Double, duration: Double) -> Bool {
        // مدة ما نعرفها أو مقطع قصير: نصدّق المشغّل
        guard duration.isFinite, duration > 60 else { return true }
        return duration - position <= max(20, duration * 0.02)
    }
}

/// التعليق: ننتظر ونخلّي المؤشر يدور طول ما البيانات توصل، وما نعيد التحميل إلا لما الشبكة تسكت فعلًا
enum StallPolicy {
    /// stalled: كم صار المشغّل واقف وهو المفروض شغّال. quiet: كم صار بدون أي بيانات جديدة (nil = ما نعرف).
    /// justReturned: رجعت للتطبيق قبل شوي (الاتصال غالبًا انقطع بالخلفية)
    static func shouldReload(stalled: Double, quiet: Double?, justReturned: Bool) -> Bool {
        if justReturned { return stalled >= 6 && (quiet ?? stalled) >= 6 }
        guard stalled >= 20 else { return false }
        if let quiet { return quiet >= 20 || stalled >= 120 }
        return stalled >= 30
    }
}

/// الصورة واقفة والوقت يمشي (الترجمة والصوت يكمّلون). frames عدّاد يزيد مع كل إطار ينعرض
struct FrameWatch: Equatable {
    enum Verdict: Equatable {
        case fine
        /// الإطارات وقفت شوي: الترجمة توقف عند وقت آخر إطار
        case lagging
        /// الصورة واقفة والوقت ماشي من فترة: استعادة
        case frozen
    }

    private var lastFrames: Int?
    private(set) var everFrames = false
    /// وقت التشغيل عند آخر إطار جديد
    private(set) var frameTime: Double = 0
    private var stuckSince: Double?
    /// الإطارات متأخرة عن الوقت (الترجمة تمسك عند آخر إطار)
    private(set) var lagging = false

    static let lagAfter: Double = 0.6
    static let frozenAfter: Double = 2.5

    mutating func reset() { self = FrameWatch() }

    mutating func observe(frames: Int, time t: Double, playing: Bool, now: Double) -> Verdict {
        let v = judge(frames: frames, time: t, playing: playing, now: now)
        lastFrames = frames
        lagging = v != .fine
        return v
    }

    private mutating func judge(frames: Int, time t: Double, playing: Bool, now: Double) -> Verdict {
        if let last = lastFrames, frames < last {
            // عدّاد المشغّل رجع لصفر: فتح المصدر من جديد (استعادة، رجوع، VLC من جديد).
            // بدون هذا كنا نحسبها "صورة واقفة" لين يتجاوز العدّاد رقمه القديم.
            frameTime = t
            stuckSince = nil
            return .fine
        }
        if let last = lastFrames, frames > last {
            everFrames = true
            frameTime = t
            stuckSince = nil
            return .fine
        }
        if lastFrames == nil {
            frameTime = t
            return .fine
        }
        // واقف أو يحمّل أو ما فيه فيديو أصلًا: الوقت ما يمشي، فما فيه شي يطلع برا الصورة
        guard playing, everFrames else {
            frameTime = t
            stuckSince = nil
            return .fine
        }
        // ترجيع أو تقديم: الوقت راح ورا أو قفز قدام بعيد
        if t < frameTime - 0.5 || t - frameTime > 30 { frameTime = t; stuckSince = nil; return .fine }
        let ahead = t - frameTime
        guard ahead >= Self.lagAfter else { return .fine }
        if stuckSince == nil { stuckSince = now }
        return ahead >= Self.frozenAfter && now - stuckSince! >= Self.frozenAfter - Self.lagAfter ? .frozen : .lagging
    }
}

/// مقاس الفيديو اللي تعتمد عليه الترجمة والتكبير: مشغّل جديد (استعادة، رجوع، VLC من جديد) يبدأ بمقاس صفر
/// لين يحمّل، وكان هذا ينزّل الترجمة لتحت الشاشة. نفس الفيلم يبقى بآخر مقاس عرفناه
enum StickyVideoSize {
    static func merge(current: (w: Double, h: Double), reported: (w: Double, h: Double)) -> (w: Double, h: Double) {
        reported.w > 1 && reported.h > 1 ? reported : current
    }
}
