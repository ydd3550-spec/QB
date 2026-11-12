import Foundation
import UIKit
import QBCore
import WidgetKit

/// يكتب قائمة "كمّل المشاهدة" وصورها المصغّرة في مجلد المجموعة عشان الويدجت يقراها
enum WidgetBridge {
    private static var task: Task<Void, Never>?

    static func write(_ items: [WatchProgress], language: AppLanguage) {
        task?.cancel()
        guard let dir = WidgetShared.container else { return }
        let top = Array(items.prefix(3))
        task = Task {
            var out: [WidgetItem] = []
            for p in top {
                var file: String?
                if let poster = p.poster, let url = URL(string: poster) {
                    let name = "w_\(abs(poster.hashValue)).jpg"
                    let path = dir.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: path.path) {
                        file = name
                    } else if let image = await ImagePipeline.shared.image(for: url, maxPixel: 320),
                              let jpg = image.jpegData(compressionQuality: 0.8) {
                        try? jpg.write(to: path, options: .atomic)
                        file = name
                    }
                }
                if Task.isCancelled { return }
                var label: String?
                if let ep = p.episodeId, let (s, e) = Self.seasonEpisode(ep) {
                    label = L("م%@ ح%@", "\(s)", "\(e)")
                }
                out.append(WidgetItem(mediaId: p.mediaId, kind: p.kind.wire, title: p.title,
                                      fraction: p.fraction ?? 0, label: label, imageFile: file))
            }
            let payload = WidgetPayload(lang: language.rawValue, items: out)
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: dir.appendingPathComponent(WidgetShared.fileName), options: .atomic)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.kind)
        }
    }

    /// "tt123:2:5" -> (2, 5)
    static func seasonEpisode(_ id: String) -> (Int, Int)? {
        let parts = id.split(separator: ":")
        guard parts.count >= 3, let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) else { return nil }
        return (s, e)
    }
}
