import SwiftUI
import QBCore

enum AppTab: Hashable {
    case home, discover, library, settings, search
}

/// شاشات الإعدادات الداخلية
enum SettingsRoute: Hashable {
    case addons
    case history
}

/// كتالوج كامل ("الكل" من الرئيسية)
struct CatalogRoute: Hashable {
    let addonId: String
    let catalogId: String
    let kind: MediaKind
    let title: String
}

/// العنصر اللي نفتح صفحته
struct MediaRef: Hashable, Sendable {
    let id: String
    let kind: MediaKind
    let name: String
    let poster: String?
    let background: String?
    /// معرّف مصدر حركة التكبير (نفس العمل ممكن يكون في أكثر من رف)
    let zoomID: String

    init(id: String, kind: MediaKind, name: String, poster: String? = nil, background: String? = nil, zoomID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.poster = poster
        self.background = background
        self.zoomID = zoomID ?? id
    }

    init(_ m: MetaPreview, zoomID: String? = nil) {
        self.init(id: m.id, kind: m.kind, name: m.name, poster: m.poster, background: m.background, zoomID: zoomID)
    }

    init(_ m: MetaDetail) {
        self.init(id: m.id, kind: m.kind, name: m.name, poster: m.poster, background: m.background)
    }
}

/// يربط شاشات التفاصيل والكتالوجات بمسار التنقل مع حركة التكبير
struct MediaDestinations: ViewModifier {
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MediaRef.self) { ref in
                DetailsView(ref: ref)
                    .navigationTransition(.zoom(sourceID: ref.zoomID, in: namespace))
            }
            .navigationDestination(for: CatalogRoute.self) { route in
                CatalogGridView(route: route, namespace: namespace)
            }
    }
}

extension View {
    func mediaDestinations(_ namespace: Namespace.ID) -> some View {
        modifier(MediaDestinations(namespace: namespace))
    }
}
