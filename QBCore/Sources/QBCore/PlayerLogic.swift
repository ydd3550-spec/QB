// منطق المشغّل اللي ما يحتاج واجهة، هنا عشان نقدر نختبره.
import CoreGraphics

public enum PlayerLogic {
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

    /// الفيديو عرضي بوضوح (ندوّر له الشاشة أفقي)
    public static func isLandscapeVideo(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width > size.height * 1.15
    }

    /// السحب لتحت يكفي للخروج من المشغّل؟
    public static func swipeDismisses(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation > 140 || predicted > 360
    }
}
