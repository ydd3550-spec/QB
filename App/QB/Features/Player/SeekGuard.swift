import Foundation

/// يمسك مكان التقديم وهو ماشي، عشان الشريط ورأس التشغيل والوقت ما يرجعون للمكان القديم.
///
/// المشكلة: بعد ما نطلب التقديم، المشغّل (AVPlayer وVLC) يكمّل يبلّغ الوقت القديم لين يخلص التقديم فعلًا.
/// مع البث من النت وملفات MKV اللي تتحوّل، التقديم ياخذ ثواني (يعيد التحويل من المكان الجديد)،
/// فكان الوقت القديم يكتب فوق المكان الجديد: الشريط ينط لورا وبعدين يرجع قدام، والضغطة الثانية
/// تنحسب من المكان القديم.
///
/// الحل: من لحظة التقديم نعرض الهدف بس، ونتجاهل أي وقت يجي من المشغّل لين:
/// - المشغّل يأكد إنه خلص (AVPlayer: completion بـ finished = true)، أو
/// - الوقت المبلّغ يوصل قريب من الهدف (VLC ما عنده تأكيد).
/// بعد الوصول نبقى على الهدف لين الوقت المبلّغ يوصله أو يتعداه (لو نزل قبله بشوي)، فما فيه ولا خطوة لورا.
/// والضغطات المتتالية تنحسب من الهدف المعلّق، مو من الوقت القديم.
/// منطق صافي بدون أي مشغّل، فينختبر لحاله (scripts/seekguard-test).
struct SeekGuard {
    /// الهدف المعلّق (nil = ما فيه تقديم ماشي)
    private(set) var target: Double?
    private var issuedAt: TimeInterval = 0
    private var arrivedAt: TimeInterval?
    private var confirmed = false

    /// كم قريب من الهدف يعتبر وصل (VLC يبلّغ الوقت بخطوات وينزل على أقرب إطار)
    var arriveWithin: Double = 1.5
    /// أقصى وقت ننتظر فيه التقديم (إعادة التحويل ممكن تطوّل)، بعده نصدّق المشغّل
    var timeout: TimeInterval = 20
    /// بعد الوصول: أقصى وقت نبقى فيه على الهدف لو المشغّل نزل قبله بشوي
    var settle: TimeInterval = 1.5

    var isPending: Bool { target != nil }

    /// تقديم جديد (يلغي أي تقديم معلّق قبله)
    mutating func begin(_ seconds: Double, now: TimeInterval) {
        target = max(0, seconds)
        issuedAt = now
        arrivedAt = nil
        confirmed = false
    }

    /// المشغّل أكّد إن التقديم خلص (AVPlayer completion finished = true)
    mutating func confirm(_ seconds: Double, now: TimeInterval) {
        guard let target, abs(target - seconds) < 0.001 else { return }
        confirmed = true
        if arrivedAt == nil { arrivedAt = now }
    }

    mutating func cancel() {
        target = nil
        arrivedAt = nil
        confirmed = false
    }

    /// الهدف المعلّق لو فيه، وإلا الوقت الحالي (للضغطات المتتالية: +10 فوق +10)
    func base(current: Double) -> Double { target ?? current }

    /// الوقت اللي ينعرض بدل الوقت المبلّغ من المشغّل
    mutating func resolve(reported: Double, now: TimeInterval) -> Double {
        guard let target else { return reported }
        guard reported.isFinite else { return target }
        if now - issuedAt > timeout {
            cancel()
            return reported
        }
        if arrivedAt == nil {
            if abs(reported - target) <= arriveWithin {
                arrivedAt = now
            } else {
                // لسا يبلّغ المكان القديم
                return target
            }
        } else if !confirmed, abs(reported - target) > arriveWithin {
            // VLC: وقت قديم وصل متأخر بعد ما حسبناه وصل: نبقى على الهدف وننتظر من جديد
            arrivedAt = nil
            return target
        }
        // وصل: لو الوقت المبلّغ وصل الهدف أو تعداه خلاص نصدّقه
        if reported >= target - 0.05 {
            cancel()
            return reported
        }
        // نزل قبل الهدف بشوي (أقرب إطار): نبقى على الهدف شوي عشان ما يرجع الشريط لورا
        if let arrivedAt, now - arrivedAt > settle {
            cancel()
            return reported
        }
        return target
    }
}
