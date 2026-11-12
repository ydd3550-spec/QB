import Foundation

/// بيانات ويدجت "كمّل المشاهدة" (مشتركة بين التطبيق والويدجت)
nonisolated struct WidgetItem: Codable, Sendable, Hashable {
    var mediaId: String
    var kind: String
    var title: String
    var fraction: Double
    var label: String?
    var imageFile: String?
}

nonisolated struct WidgetPayload: Codable, Sendable {
    var lang: String
    var items: [WidgetItem]
}

nonisolated enum WidgetShared {
    static let appGroup = "group.com.y.qb"
    static let fileName = "continue.json"
    static let kind = "QBContinueWidget"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func read() -> WidgetPayload? {
        guard let url = container?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }

    static func deepLink(_ item: WidgetItem) -> URL? {
        var c = URLComponents()
        c.scheme = "qb"
        c.host = "title"
        c.path = "/\(item.kind)/\(item.mediaId)"
        c.queryItems = [URLQueryItem(name: "name", value: item.title)]
        return c.url
    }
}
