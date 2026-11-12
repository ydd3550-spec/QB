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

    /// الفيديو عرضي بوضوح (ندوّر له الشاشة أفقي)
    public static func isLandscapeVideo(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width > size.height * 1.15
    }

    /// السحب لتحت يكفي للخروج من المشغّل؟
    public static func swipeDismisses(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation > 140 || predicted > 360
    }
}
