import SwiftUI

/// لغة التطبيق. العربية أول، والإنجليزية اختيار من الإعدادات.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case arabic = "ar"
    case english = "en"

    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .arabic: "العربية"
        case .english: "English"
        }
    }
    var direction: LayoutDirection { self == .arabic ? .rightToLeft : .leftToRight }
    var locale: Locale { Locale(identifier: self == .arabic ? "ar" : "en") }
}

/// المفتاح هو النص العربي نفسه (العربية لغة المصدر في Localizable.xcstrings)،
/// فلو ضاعت الترجمة يطلع عربي صحيح مو مفتاح غريب.
enum L10n {
    nonisolated(unsafe) private static var bundle: Bundle = .main
    nonisolated(unsafe) private(set) static var language: AppLanguage = .arabic

    static func set(_ lang: AppLanguage) {
        language = lang
        if let path = Bundle.main.path(forResource: lang.rawValue, ofType: "lproj"), let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }

    static func string(_ key: String) -> String {
        let s = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return s.isEmpty ? key : s
    }
}

/// النص المترجم. الوسيط الأول نص عربي ثابت (عشان سكربت الترجمات يلقاه).
func L(_ key: String) -> String {
    L10n.string(key)
}

/// نص مترجم فيه متغيرات (%@ أو %d)
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key), locale: L10n.language.locale, arguments: args)
}
