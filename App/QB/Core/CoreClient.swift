import Foundation
import QBCore

/// أحداث المصادر وهي توصل من Rust
enum SourceEvent: Sendable {
    case sources([RankedSource])
    case health(String, Health)
    case finished
}

/// يحوّل callbacks النواة (تجي من خيوط tokio) إلى AsyncStream نقراه على الـ MainActor
final class SourceStream: SourceListener, @unchecked Sendable {
    let stream: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: SourceEvent.self, bufferingPolicy: .bufferingNewest(64))
    }

    func onSources(sources: [RankedSource]) { continuation.yield(.sources(sources)) }
    func onHealth(sourceId: String, health: Health) { continuation.yield(.health(sourceId, health)) }
    func onFinished() {
        continuation.yield(.finished)
        continuation.finish()
    }
}

/// نتائج البحث رف رف
final class SearchStream: SearchListener, @unchecked Sendable {
    let stream: AsyncStream<CatalogRow>
    private let continuation: AsyncStream<CatalogRow>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: CatalogRow.self)
    }

    func onRow(row: CatalogRow) { continuation.yield(row) }
    func finish() { continuation.finish() }
}

/// غلاف بسيط حول النواة: يبدأها، ويرجّع رسائل خطأ مفهومة
enum CoreClient {
    static func make() -> QbCore? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QB", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try? QbCore(dataDir: dir.path)
    }

    /// يبدأ جمع المصادر ويرجّع الأحداث أول بأول. إلغاء الـ Task يلغي الطلب في Rust.
    static func sources(_ core: QbCore, kind: MediaKind, id: String) -> AsyncStream<SourceEvent> {
        let listener = SourceStream()
        let task = Task.detached {
            try? await core.loadSources(kind: kind, id: id, listener: listener)
        }
        return AsyncStream { cont in
            let inner = Task {
                for await e in listener.stream { cont.yield(e) }
                cont.finish()
            }
            cont.onTermination = { _ in
                task.cancel()
                inner.cancel()
            }
        }
    }

    static func message(for error: Error) -> String {
        guard let e = error as? CoreError else {
            if error is CancellationError { return L("تم الإلغاء") }
            return L("صار خطأ غير متوقع")
        }
        switch e {
        case .Network: return L("تعذّر الاتصال. تأكد من الإنترنت وجرّب مرة ثانية")
        case .Addon: return L("الإضافة ردّت بشي ما نفهمه")
        case .Storage: return L("تعذّر الحفظ على الجهاز")
        case .Cancelled: return L("تم الإلغاء")
        }
    }

    static var now: Int64 { Int64(Date().timeIntervalSince1970) }
}
