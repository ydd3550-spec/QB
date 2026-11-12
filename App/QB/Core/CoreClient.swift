import Foundation
import QBCore
import os

/// نتيجة تشغيل النواة: النواة نفسها، ونص الخطأ الحقيقي لو فشلت، وتنبيه لو اشتغلت بدون حفظ
struct CoreStartup {
    var core: QbCore?
    /// نص الخطأ كامل (لو ما اشتغلت النواة أبد)
    var error: String?
    /// اشتغلت بالذاكرة بس (ما تنحفظ الأشياء)، وهذا سبب فشل التخزين
    var warning: String?
}

let coreLog = Logger(subsystem: "app.qb", category: "core")

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
    /// يجرّب يبدأ النواة في Application Support، بعدين Caches، بعدين tmp، وآخر حل بالذاكرة.
    /// كل خطأ ينحفظ بنصه الحقيقي عشان يبان في شاشة الخطأ بدل ما ينبلع.
    static func make() -> CoreStartup {
        let fm = FileManager.default
        var candidates: [(String, URL)] = []
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(("ApplicationSupport", support.appendingPathComponent("QB", isDirectory: true)))
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(("Caches", caches.appendingPathComponent("QB", isDirectory: true)))
        }
        candidates.append(("tmp", fm.temporaryDirectory.appendingPathComponent("QB", isDirectory: true)))

        var failures: [String] = []
        for (name, url) in candidates {
            var dir = url
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dir.setResourceValues(values)
            } catch {
                failures.append("[\(name)] mkdir: \(describe(error))")
                coreLog.error("core dir \(name, privacy: .public) mkdir failed: \(describe(error), privacy: .public)")
                continue
            }
            do {
                let core = try QbCore(dataDir: dir.path)
                // لو اشتغلت في مجلد بديل فالحفظ شغّال، نكتفي بالسجل
                coreLog.info("core started in \(name, privacy: .public); earlier failures: \(failures.joined(separator: " | "), privacy: .public)")
                return CoreStartup(core: core, error: nil, warning: nil)
            } catch {
                failures.append("[\(name)] \(describe(error))")
                coreLog.error("core start in \(name, privacy: .public) failed: \(describe(error), privacy: .public)")
            }
        }
        // آخر حل: بالذاكرة
        do {
            let core = try QbCore.inMemory()
            let detail = failures.joined(separator: "\n")
            coreLog.error("core running in memory only: \(detail, privacy: .public)")
            return CoreStartup(core: core, error: nil, warning: detail)
        } catch {
            failures.append("[memory] \(describe(error))")
            let detail = failures.joined(separator: "\n")
            coreLog.fault("core failed to start: \(detail, privacy: .public)")
            NSLog("QB core failed to start: %@", detail)
            return CoreStartup(core: nil, error: detail, warning: nil)
        }
    }

    /// نص الخطأ الحقيقي كامل (للتشخيص، مو للمستخدم العادي)
    static func describe(_ error: Error) -> String {
        if let e = error as? CoreError {
            switch e {
            case .Network(let m): return "network: \(m)"
            case .Addon(let m): return "addon: \(m)"
            case .Storage(let m): return "storage: \(m)"
            case .Cancelled: return "cancelled"
            }
        }
        return String(describing: error)
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
