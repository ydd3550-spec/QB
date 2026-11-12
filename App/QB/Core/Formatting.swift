import Foundation
import QBCore

typealias WatchProgress = QBCore.Progress

/// تنسيقات بسيطة ما تعتمد على الواجهة (عليها اختبارات)
nonisolated enum TimeFormat {
    /// 75 -> "1:15"، 3725 -> "1:02:05"
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// الدقايق المتبقية (تقريب لأعلى)
    static func minutesLeft(position: Double, duration: Double?) -> Int? {
        guard let duration, duration > 0, position < duration else { return nil }
        return max(1, Int(((duration - position) / 60).rounded(.up)))
    }
}

/// اسم الجودة من الرقم
nonisolated enum QualityLabel {
    static func text(_ q: UInt16) -> String? {
        switch q {
        case 0: nil
        case 2000...: "4K"
        case 1400..<2000: "1440p"
        case 1000..<1400: "1080p"
        case 700..<1000: "720p"
        default: "\(q)p"
        }
    }
}

/// أسماء اللغات للترجمات والصوت (الإضافات تستخدم رموز ثلاثية مثل ara)
nonisolated enum LanguageNames {
    private static let threeToTwo: [String: String] = [
        "ara": "ar", "eng": "en", "fre": "fr", "fra": "fr", "spa": "es", "ger": "de", "deu": "de",
        "tur": "tr", "per": "fa", "fas": "fa", "urd": "ur", "hin": "hi", "ita": "it", "por": "pt",
        "pob": "pt", "rus": "ru", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh", "ind": "id",
        "may": "ms", "msa": "ms", "dut": "nl", "nld": "nl", "pol": "pl", "swe": "sv", "heb": "he",
        "gre": "el", "ell": "el", "rum": "ro", "ron": "ro", "hun": "hu", "cze": "cs", "ces": "cs",
        "tha": "th", "vie": "vi", "ukr": "uk", "ben": "bn", "dan": "da", "fin": "fi", "nor": "no",
    ]

    /// يوحّد الرمز: "ara" و"ar" و"Arabic" كلها -> "ar"
    static func normalize(_ code: String) -> String {
        let c = code.trimmingCharacters(in: .whitespaces).lowercased()
        if let two = threeToTwo[c] { return two }
        if c.hasPrefix("arab") { return "ar" }
        if c.hasPrefix("engl") { return "en" }
        if c.count >= 2, let dash = c.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(c[..<dash])
        }
        return c
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    static func displayName(_ code: String, locale: Locale) -> String {
        let n = normalize(code)
        if let name = locale.localizedString(forLanguageCode: n), !name.isEmpty { return name }
        return code.uppercased()
    }
}

/// البحث عن سطر الترجمة الحالي (بحث ثنائي)
nonisolated enum CueIndex {
    /// cues مرتّبة بالبداية. offset بالثواني: موجب يأخّر الترجمة
    static func text(in cues: [Cue], at seconds: Double, offset: Double = 0) -> String? {
        guard !cues.isEmpty else { return nil }
        let t = (seconds - offset) * 1000
        guard t >= 0 else { return nil }
        let ms = UInt64(t)
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].startMs <= ms {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard found >= 0 else { return nil }
        // أكثر من سطر ممكن يتداخلون: نجمع اللي شغالين الحين
        var lines: [String] = []
        var i = found
        while i >= 0, found - i < 4 {
            let c = cues[i]
            if c.startMs <= ms, ms < c.endMs { lines.insert(clean(c.text), at: 0) }
            i -= 1
        }
        let joined = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// يشيل وسوم HTML وASS اللي تبقى
    static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// حساب التقديم بالسحب الأفقي
nonisolated enum SeekMath {
    /// كم ثانية يساوي السحب من طرف الشاشة للطرف الثاني
    static func secondsPerWidth(duration: Double?) -> Double {
        guard let duration, duration > 0 else { return 120 }
        return min(max(duration * 0.5, 60), 600)
    }

    static func target(start: Double, dx: CGFloat, width: CGFloat, duration: Double?) -> Double {
        guard width > 0 else { return start }
        let delta = Double(dx / width) * secondsPerWidth(duration: duration)
        var t = start + delta
        if let duration, duration > 0 { t = min(t, duration - 1) }
        return max(0, t)
    }
}

/// تاريخ العرض من نص ISO
nonisolated enum DateText {
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: String(s.prefix(10)))
    }

    static func short(_ s: String?, locale: Locale) -> String? {
        guard let d = parse(s) else { return nil }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }
}

nonisolated enum ByteText {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
