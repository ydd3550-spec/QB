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

    /// سحب الرجوع من الطرف: ثلث الشاشة أو رمية سريعة لنصها
    public static func edgeSwipeCompletes(progress: CGFloat, predicted: CGFloat, width: CGFloat) -> Bool {
        progress > width * 0.33 || predicted > width * 0.5
    }

    /// الفيديو عرضي بوضوح (ندوّر له الشاشة أفقي)
    public static func isLandscapeVideo(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width > size.height * 1.15
    }

    /// السحب لتحت يكفي للخروج من المشغّل؟
    public static func swipeDismisses(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation > 140 || predicted > 360
    }

    /// مستطيل الفيديو المعروض داخل الشاشة: الحجم الأصلي مثل AVMakeRect، وملء الشاشة يغطيها (ويطلع براها).
    /// nil لو مقاس الفيديو ما انعرف للحين
    public static func videoRect(video: CGSize, in screen: CGSize, fill: Bool) -> CGRect? {
        guard video.width > 0, video.height > 0, screen.width > 0, screen.height > 0 else { return nil }
        let sx = screen.width / video.width, sy = screen.height / video.height
        let s = fill ? max(sx, sy) : min(sx, sy)
        let w = video.width * s, h = video.height * s
        return CGRect(x: (screen.width - w) / 2, y: (screen.height - h) / 2, width: w, height: h)
    }

    /// مكان الترجمة: المسافة من أسفل الشاشة (مع الحافة الآمنة) وتصغير الخط للفيديو الصغير
    public struct SubtitlePlacement: Equatable, Sendable {
        public let bottom: CGFloat
        public let scale: CGFloat
    }

    /// الترجمة داخل أسفل الصورة نفسها (مو أسفل الشاشة): بالطول تطلع تحت الفيديو اللي بالنص،
    /// وبالعرض أو بعد التكبير تظل فوق حافة الشاشة وفوق الأدوات لو ظاهرة.
    public static func subtitlePlacement(screen: CGSize, video: CGSize, fill: Bool, safeBottom: CGFloat, controlsVisible: Bool) -> SubtitlePlacement {
        let floor = safeBottom + (controlsVisible ? 128 : 34)
        guard let rect = videoRect(video: video, in: screen, fill: fill) else {
            return SubtitlePlacement(bottom: floor, scale: 1)
        }
        let visibleBottom = min(rect.maxY, screen.height)
        let visibleHeight = visibleBottom - max(rect.minY, 0)
        let gap = max(0, screen.height - visibleBottom)
        let inner = max(10, visibleHeight * 0.06)
        let scale = min(1, max(0.8, visibleHeight / 360))
        return SubtitlePlacement(bottom: max(gap + inner, floor), scale: scale)
    }

    /// القرص بالإصبعين خلص: true ملء الشاشة، false الحجم الأصلي، nil ما يتغيّر شي
    /// (حركة صغيرة، أو نفس الوضع الحالي)
    public static func pinchZoomDecision(magnification: CGFloat, filled: Bool) -> Bool? {
        guard magnification.isFinite, magnification > 0 else { return nil }
        if magnification >= 1.08, !filled { return true }
        if magnification <= 0.93, filled { return false }
        return nil
    }

    /// معاينة خفيفة للفيديو وقت القرص: تتبع أصابعك شوي ومحدودة عشان ما تتمطّط الصورة
    public static func pinchPreviewScale(_ magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite, magnification > 0 else { return 1 }
        return 1 + min(max((magnification - 1) * 0.3, -0.06), 0.08)
    }
}
