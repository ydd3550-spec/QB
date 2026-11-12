import SwiftUI
import UIKit

/// الخط: IBM Plex Sans Arabic (عربي ولاتيني) مع Dynamic Type،
/// كل الأحجام تكبر وتصغر مع إعداد حجم الخط في الجهاز.
enum Typo {
    enum Weight {
        case regular, medium, semibold, bold
        var name: String {
            switch self {
            case .regular: "IBMPlexSansArabic-Regular"
            case .medium: "IBMPlexSansArabic-Medium"
            case .semibold: "IBMPlexSansArabic-SemiBold"
            case .bold: "IBMPlexSansArabic-Bold"
            }
        }
    }

    static func font(_ weight: Weight, _ size: CGFloat, _ style: Font.TextStyle) -> Font {
        .custom(weight.name, size: size, relativeTo: style)
    }

    static let hero = font(.bold, 32, .largeTitle)
    static let title = font(.bold, 23, .title2)
    static let section = font(.bold, 19, .title3)
    static let headline = font(.semibold, 16, .headline)
    static let body = font(.regular, 16, .body)
    static let bodyMedium = font(.medium, 16, .body)
    static let info = font(.regular, 14, .subheadline)
    static let infoMedium = font(.medium, 14, .subheadline)
    static let caption = font(.medium, 12, .caption)
    static let badge = font(.bold, 11, .caption2)
    /// الأرقام المتغيرة (الوقت) بعرض ثابت عشان ما ترجف
    static let time = Font.system(.footnote, design: .rounded).monospacedDigit().weight(.semibold)

    static func uiFont(_ weight: Weight, _ size: CGFloat, _ style: UIFont.TextStyle) -> UIFont {
        let base = UIFont(name: weight.name, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    /// خط أشرطة التنقل (UIKit)
    static func applyToUIKit() {
        let nav = UINavigationBar.appearance()
        nav.largeTitleTextAttributes = [.font: uiFont(.bold, 32, .largeTitle)]
        nav.titleTextAttributes = [.font: uiFont(.semibold, 17, .headline)]
        let item = UIBarButtonItem.appearance()
        item.setTitleTextAttributes([.font: uiFont(.medium, 16, .body)], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: uiFont(.medium, 10, .caption2)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: uiFont(.medium, 13, .subheadline)], for: .normal)
    }
}
