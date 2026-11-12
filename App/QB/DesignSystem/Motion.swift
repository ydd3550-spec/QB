import SwiftUI

/// الحركة: أربع حركات بس في التطبيق كله
enum Motion {
    /// العادية
    static let standard = Animation.spring(duration: 0.35, bounce: 0.12)
    /// الأزرار والتشغيل/الإيقاف
    static let snappy = Animation.snappy(duration: 0.22)
    /// الشاشات المنبثقة والمشغّل
    static let sheet = Animation.spring(duration: 0.45, bounce: 0.08)
    /// الرجوع لأعلى الصفحة
    static let soft = Animation.smooth(duration: 0.3)
}
