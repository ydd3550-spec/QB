import SwiftUI

/// الحركة: أربع حركات بس في التطبيق كله
enum Motion {
    /// العادية
    static let standard = Animation.spring(duration: 0.35, bounce: 0.06)
    /// الأزرار والتشغيل/الإيقاف
    static let snappy = Animation.snappy(duration: 0.22)
    /// الشاشات المنبثقة والمشغّل
    static let sheet = Animation.spring(duration: 0.45, bounce: 0.08)
    /// الرجوع لأعلى الصفحة
    static let soft = Animation.smooth(duration: 0.3)
}


// MARK: - الضغطة المطاطية (من الأنميشن اللي يحبها هوى)
//
// القياس من التسجيل (60 إطار بالثانية): العنصر ينضغط بسرعة لقرابة 86٪ من حجمه في حوالي 80 جزء من
// الثانية بدون ارتداد، ولما ينشال الإصبع يقفز فوق حجمه الأصلي بشوي (قرابة 104٪) ويرجع يستقر بنعومة
// خلال ربع ثانية تقريبًا. النزول حاد، والطلوع مطاطي.
extension Motion {
    /// النزول مع الإصبع: سريع وبدون ارتداد
    static let pressDown = Animation.spring(response: 0.14, dampingFraction: 0.9)
    /// الطلوع بعد الإفلات: يتعدّى حجمه شوي ويرجع
    static let pressRelease = Animation.spring(response: 0.34, dampingFraction: 0.42)
    /// ظهور وانتقال العناصر الصغيرة (رسائل المشغّل، الشارات) بنفس الروح
    static let pop = Animation.spring(response: 0.38, dampingFraction: 0.62)
}

/// زر ينضغط وينطّ مثل الأنميشن المرجعية. `depth` حجم العنصر وهو مضغوط: الأزرار الصغيرة تنضغط أكثر
/// (0.86) والبطاقات الكبيرة أقل (0.94) عشان ما تبان قفزة كبيرة.
struct BouncyPressStyle: ButtonStyle {
    var depth: CGFloat = 0.86
    var dims = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? depth : 1)
            .brightness(dims && configuration.isPressed ? -0.06 : 0)
            .animation(configuration.isPressed ? Motion.pressDown : Motion.pressRelease, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BouncyPressStyle {
    /// أزرار صغيرة وشارات
    static var bouncy: BouncyPressStyle { BouncyPressStyle() }
    /// بطاقات وبوسترات
    static var bouncyCard: BouncyPressStyle { BouncyPressStyle(depth: 0.94) }
}
