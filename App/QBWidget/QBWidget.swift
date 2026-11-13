import WidgetKit
import SwiftUI
import UIKit

/// ويدجت "كمّل المشاهدة": يقرا القائمة اللي يكتبها التطبيق في مجلد المجموعة
nonisolated struct ContinueEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload?
}

nonisolated struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry {
        ContinueEntry(date: .now, payload: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        completion(ContinueEntry(date: .now, payload: WidgetShared.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        let entry = ContinueEntry(date: .now, payload: WidgetShared.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

private enum WText {
    static func title(_ lang: String) -> String { lang == "en" ? "Continue watching" : "كمّل المشاهدة" }
    static func empty(_ lang: String) -> String { lang == "en" ? "Nothing to continue yet" : "ما فيه شي تكمّله الحين" }
}

private let gold = Color(red: 0.87, green: 0.75, blue: 0.50)
private let bg = Color(red: 0.067, green: 0.057, blue: 0.050)

struct ContinueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueEntry

    private var lang: String { entry.payload?.lang ?? "ar" }
    private var items: [WidgetItem] { entry.payload?.items ?? [] }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        WidgetLogoMark(size: 22)
                        Text("QB").font(.system(.headline, design: .rounded).weight(.heavy)).foregroundStyle(gold)
                    }
                    Spacer()
                    Text(WText.empty(lang)).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if family == .systemSmall, let first = items.first {
                Link(destination: WidgetShared.deepLink(first) ?? URL(string: "qb://")!) {
                    ItemTile(item: first, compact: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        WidgetLogoMark(size: 15)
                        Text(WText.title(lang)).font(.caption.weight(.bold)).foregroundStyle(gold)
                    }
                    HStack(spacing: 10) {
                        ForEach(items.prefix(3), id: \.self) { item in
                            Link(destination: WidgetShared.deepLink(item) ?? URL(string: "qb://")!) {
                                ItemTile(item: item, compact: false)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.layoutDirection, lang == "en" ? .leftToRight : .rightToLeft)
        .containerBackground(for: .widget) { bg }
    }
}

private struct ItemTile: View {
    let item: WidgetItem
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            poster
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title).font(.caption2.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
            if let label = item.label {
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(gold).frame(width: g.size.width * min(max(item.fraction, 0), 1))
                }
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder private var poster: some View {
        if let file = item.imageFile,
           let url = WidgetShared.container?.appendingPathComponent(file),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.white.opacity(0.06)
                WidgetLogoMark(size: 26)
            }
        }
    }
}

struct QBContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.kind, provider: ContinueProvider()) { entry in
            ContinueWidgetView(entry: entry)
        }
        .configurationDisplayName("كمّل المشاهدة")
        .description("آخر اللي كنت تشاهده في QB")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct QBWidgetBundle: WidgetBundle {
    var body: some Widget {
        QBContinueWidget()
    }
}


/// شعار QB الجديد (زر تشغيل بلون التطبيق على خلفية سودا) بزوايا مدوّرة مثل أيقونة التطبيق
struct WidgetLogoMark: View {
    let size: CGFloat
    var body: some View {
        Image("WidgetLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}
