import Foundation

/// أسماء التصنيفات بالعربي (القيمة الأصلية تنرسل للإضافة زي ما هي، هذا للعرض بس)
enum Genres {
    static let hiddenCatalogIds: Set<String> = ["calendar-videos", "last-videos"]

    private static let arabic: [String: String] = [
        "action": "أكشن", "adventure": "مغامرة", "animation": "أنمي ورسوم", "anime": "أنمي", "biography": "سيرة ذاتية",
        "comedy": "كوميدي", "crime": "جريمة", "documentary": "وثائقي", "drama": "دراما", "family": "عائلي",
        "fantasy": "فانتازيا", "film-noir": "نوار", "film noir": "نوار", "game-show": "برامج مسابقات", "history": "تاريخي",
        "horror": "رعب", "music": "موسيقى", "musical": "موسيقي", "mystery": "غموض", "news": "أخبار",
        "reality-tv": "تلفزيون الواقع", "reality": "تلفزيون الواقع", "romance": "رومانسي", "sci-fi": "خيال علمي",
        "science fiction": "خيال علمي", "short": "قصير", "sport": "رياضة", "sports": "رياضة", "talk-show": "حواري",
        "thriller": "إثارة", "war": "حرب", "western": "غربي", "kids": "أطفال", "soap": "مسلسلات طويلة",
        "talk": "حواري", "war & politics": "حرب وسياسة", "action & adventure": "أكشن ومغامرة",
        "sci-fi & fantasy": "خيال علمي وفانتازيا", "tv movie": "فيلم تلفزيوني",
    ]

    static func display(_ genre: String, arabic isArabic: Bool) -> String {
        guard isArabic else { return genre }
        return arabic[genre.lowercased().trimmingCharacters(in: .whitespaces)] ?? genre
    }
}
