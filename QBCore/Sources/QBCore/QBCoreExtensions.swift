// إضافات Swift فوق الأنواع المولّدة من UniFFI.
// UniFFI يولّدها Sendable من نفسه، هنا بس Identifiable وأدوات صغيرة.
import Foundation


extension MetaPreview: Identifiable {}
extension RankedSource: Identifiable {}
extension SubtitleTrack: Identifiable {}
extension Video: Identifiable {}
extension HistoryEntry: Identifiable {
    public var id: String { "\(mediaId)-\(watchedAt)-\(sourceId.hashValue)" }
}
extension LibraryItem: Identifiable {
    public var id: String { mediaId }
}
extension Progress: Identifiable {
    public var id: String { mediaId }
}
extension CatalogRow: Identifiable {
    public var id: String { "\(addonId)/\(catalogId)/\(kind.wire)" }
}

public extension MediaKind {
    /// الاسم اللي يستخدمه بروتوكول Stremio
    var wire: String {
        switch self {
        case .movie: "movie"
        case .series: "series"
        }
    }
    init?(wire: String) {
        switch wire {
        case "movie": self = .movie
        case "series", "tv", "anime": self = .series
        default: return nil
        }
    }
}

public extension Progress {
    /// نسبة التقدّم لو المدة معروفة
    var fraction: Double? {
        guard let d = durationS, d > 0 else { return nil }
        return min(max(positionS / d, 0), 1)
    }
}

public extension RankedSource {
    var isAlive: Bool {
        if case .alive = health { return true }
        return false
    }
    var isUnreachable: Bool {
        if case .unreachable = health { return true }
        return false
    }
    var latencyMs: UInt32? {
        if case let .alive(_, latency) = health { return latency }
        return nil
    }
}
