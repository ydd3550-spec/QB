import SwiftUI
import QBCore

/// يجمع المصادر من كل الإضافات أول بأول، مع تحديث النقاط (شغّال / جاري الفحص / ما يرد)
@Observable
@MainActor
final class SourcesLoader {
    private(set) var sources: [RankedSource] = []
    private(set) var finished = false
    private(set) var loading = false
    private(set) var id: String?
    private var task: Task<Void, Never>?

    var playable: [RankedSource] {
        sources.filter { if case .direct = $0.target { true } else { false } }
    }

    /// أفضل مصدر: أول شغّال بالترتيب، ولو ما فيه أول واحد مو ميت
    var best: RankedSource? {
        playable.first(where: \.isAlive) ?? playable.first(where: { !$0.isUnreachable }) ?? sources.first(where: \.isAlive)
    }

    func load(core: QbCore?, kind: MediaKind, id: String) {
        guard let core else { return }
        if self.id == id, loading || finished { return }
        task?.cancel()
        self.id = id
        sources = []
        finished = false
        loading = true
        task = Task {
            for await event in CoreClient.sources(core, kind: kind, id: id) {
                if Task.isCancelled || self.id != id { return }
                switch event {
                case let .sources(list):
                    withAnimation(Motion.standard) { sources = list }
                case let .health(sourceId, health):
                    if let i = sources.firstIndex(where: { $0.id == sourceId }) { sources[i].health = health }
                case .finished:
                    break
                }
            }
            if self.id == id {
                loading = false
                finished = true
            }
        }
    }

    func reload(core: QbCore?, kind: MediaKind) {
        guard let id else { return }
        self.id = nil
        load(core: core, kind: kind, id: id)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if !finished { id = nil }
        loading = false
    }

    /// ينتظر أول مصدر شغّال (لزر تشغيل المباشر) حدّه 12 ثانية
    func waitForBest() async -> RankedSource? {
        let start = Date()
        while !Task.isCancelled {
            if let alive = playable.first(where: \.isAlive) { return alive }
            if finished || Date().timeIntervalSince(start) > 12 { return best }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
