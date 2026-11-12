import SwiftUI

/// الألوان: خلفية شبه سوداء دافية، لون مميّز واحد ذهبي هادي، والباقي ألوان النظام (فاتح وداكن).
enum Palette {
    /// اللون المميّز الوحيد: ذهبي شمباني
    static let accent = Color(light: UIColor(red: 0.62, green: 0.46, blue: 0.20, alpha: 1), dark: UIColor(red: 0.87, green: 0.75, blue: 0.50, alpha: 1))
    /// نص فوق اللون المميّز
    static let onAccent = Color(red: 0.10, green: 0.08, blue: 0.05)

    /// الخلفية: شبه سوداء دافية بالداكن، كريمي دافي بالفاتح
    static let background = Color(light: UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1), dark: UIColor(red: 0.067, green: 0.057, blue: 0.050, alpha: 1))
    static let surface = Color(light: UIColor(red: 0.93, green: 0.91, blue: 0.88, alpha: 1), dark: UIColor(red: 0.125, green: 0.11, blue: 0.098, alpha: 1))
    static let surfaceRaised = Color(light: .white, dark: UIColor(red: 0.17, green: 0.15, blue: 0.13, alpha: 1))
    static let hairline = Color(light: UIColor(white: 0, alpha: 0.08), dark: UIColor(white: 1, alpha: 0.08))

    static let live = Color(red: 0.30, green: 0.82, blue: 0.46)
    static let checking = Color(red: 0.98, green: 0.70, blue: 0.25)
    static let dead = Color(red: 0.95, green: 0.33, blue: 0.30)

    /// تدرّج يغطي أسفل الصور عشان النص ينقرا
    static let scrim = LinearGradient(
        colors: [.clear, background.opacity(0.6), background],
        startPoint: .top, endPoint: .bottom
    )
    /// تدرّج خفيف أعلى الصورة عشان شريط الحالة يبان
    static let topScrim = LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
}

extension Color {
    nonisolated init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { @Sendable trait in trait.userInterfaceStyle == .dark ? dark : light })
    }
}
