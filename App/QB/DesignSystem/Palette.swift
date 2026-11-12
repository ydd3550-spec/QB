import SwiftUI

/// الألوان: خلفية شبه سوداء دافية، لون مميّز واحد هادي، والباقي ألوان النظام (فاتح وداكن).
enum Palette {
    /// اللون المميّز الوحيد: ذهبي هادي
    static let accent = Color(light: .init(red: 0.62, green: 0.46, blue: 0.20), dark: .init(red: 0.85, green: 0.73, blue: 0.48))

    /// الخلفية: شبه سوداء دافية بالداكن، كريمي دافي بالفاتح
    static let background = Color(light: .init(red: 0.98, green: 0.97, blue: 0.95), dark: .init(red: 0.075, green: 0.063, blue: 0.055))
    static let surface = Color(light: .init(red: 0.94, green: 0.92, blue: 0.89), dark: .init(red: 0.13, green: 0.115, blue: 0.10))
    static let surfaceRaised = Color(light: .white, dark: .init(red: 0.17, green: 0.15, blue: 0.13))

    static let live = Color.green
    static let checking = Color.orange
    static let dead = Color.red

    /// تدرّج يغطي أسفل الصور عشان النص ينقرا
    static let scrim = LinearGradient(
        colors: [.clear, background.opacity(0.55), background],
        startPoint: .top, endPoint: .bottom
    )
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
