// منطق المشغّل اللي ما يحتاج واجهة، هنا عشان نقدر نختبره.
import CoreGraphics

public enum PlayerLogic {
    /// مقاسات أزرار الوسط: صغيرة، ونسبة الرجوع/التقديم للتشغيل ثابتة عشان تبان موزونة
    public enum Transport {
        public static let play: CGFloat = 52

    }

    /// وش ينكتب يمين شريط التقدّم
    public enum TrailingTime: Equatable {
        /// الباقي بالثواني
        case remaining(Double)
        /// بث مباشر فعلًا
        case live
        /// المدة ما وصلت للحين (التحميل): --:--
        case unknown
    }

    public static func trailingTime(elapsed: Double, duration: Double?, live: Bool) -> TrailingTime {
        if let total = duration, total > 0, total.isFinite { return .remaining(max(0, total - elapsed)) }
        return live ? .live : .unknown
    }

    /// القوس على الطرف ياخذ هالنسبة من عرض الشاشة (بعيد عن زر التشغيل اللي بالنص)
    public static let rippleWidthFraction: CGFloat = 0.28

    /// ضغطتين على نفس الطرف ورا بعض: 10، 20، 30… وطرف جديد يبدأ من 10
    public static func nextSeekBurst(previous: Int?, step: Int = 10) -> Int {
        guard let previous, previous > 0 else { return step }
        return previous + step
    }

    /// الصوت/الإضاءة بالسحب: نص ارتفاع الشاشة يغطي المدى كله (سريع)، لفوق يرفع. ما نقص هنا عشان نعرف المطّ
    public static func sideLevel(start: Double, dy: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return start }
        return start - Double(dy / (height * 0.5))
    }

    /// وين بدأ السحب العمودي: الثلث اليسار صوت، اليمين إضاءة، والنص (أو من فوق) خروج من المشغّل
    public enum VerticalDrag: Equatable { case volume, brightness, dismiss }

    public static func verticalDrag(startX: CGFloat, startY: CGFloat, size: CGSize) -> VerticalDrag {
        guard size.width > 0, size.height > 0 else { return .dismiss }
        if startY < size.height * 0.15 { return .dismiss }
        if startX < size.width / 3 { return .volume }
        if startX > size.width * 2 / 3 { return .brightness }
        return .dismiss
    }

    /// الفيديو عرضي بوضوح (ندوّر له الشاشة أفقي)
    public static func isLandscapeVideo(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width > size.height * 1.15
    }

    /// السحب لتحت يكفي للخروج من المشغّل؟
    public static func swipeDismisses(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation > 140 || predicted > 360
    }
}
