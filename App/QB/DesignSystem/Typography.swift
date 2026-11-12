import SwiftUI

/// الخط: SF Arabic من النظام مع Dynamic Type.
/// العناوين .largeTitle والمعلومات .subheadline، وكلها تكبر وتصغر مع إعداد حجم الخط.
enum Typo {
    static let hero = Font.largeTitle.weight(.bold)
    static let title = Font.title2.weight(.bold)
    static let section = Font.title3.weight(.semibold)
    static let body = Font.body
    static let info = Font.subheadline
    static let caption = Font.caption.weight(.medium)
    static let badge = Font.caption2.weight(.bold)
    /// الأرقام المتغيرة (الوقت) بعرض ثابت عشان ما ترجف
    static let time = Font.subheadline.monospacedDigit().weight(.semibold)
}
