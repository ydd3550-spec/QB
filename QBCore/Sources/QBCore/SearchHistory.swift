// سجل البحث: يحفظ بس اللي بحثت عنه فعلًا، بدون تكرار ولا أجزاء الكلمة وقت الكتابة
import Foundation

public enum SearchHistory {
    public static let limit = 12

    /// يضيف بحث جديد لأول القائمة. يشيل المكرر (بدون حساب الحروف الكبيرة) والبدايات الأقصر منه،
    /// ولو هو بداية بحث أطول محفوظ ما يضيفه (يقدّم الأطول بس)
    public static func adding(_ query: String, to list: [String]) -> [String] {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return list }
        var out = list
        if let i = out.firstIndex(where: { same($0, t) }) {
            out.remove(at: i)
            out.insert(t, at: 0)
            return Array(out.prefix(limit))
        }
        if let longer = out.first(where: { isPrefix(of: $0, t) }) {
            out.removeAll { $0 == longer }
            out.insert(longer, at: 0)
            return Array(out.prefix(limit))
        }
        out.removeAll { $0.compare(t, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame || isPrefix(of: t, $0) }
        out.insert(t, at: 0)
        return Array(out.prefix(limit))
    }

    /// ينظّف قائمة قديمة انحفظت وقت الكتابة: يشيل الفاضي والمكرر وأي بحث هو بداية بحث ثاني
    public static func cleaned(_ list: [String]) -> [String] {
        var out: [String] = []
        for raw in list {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { continue }
            if out.contains(where: { same($0, t) || isPrefix(of: $0, t) }) { continue }
            if list.contains(where: { isPrefix(of: $0.trimmingCharacters(in: .whitespacesAndNewlines), t) }) { continue }
            out.append(t)
        }
        return Array(out.prefix(limit))
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// short بداية أقصر من long (بدون حساب الحروف الكبيرة)
    static func isPrefix(of long: String, _ short: String) -> Bool {
        let l = long.lowercased(), s = short.lowercased()
        return l.count > s.count && l.hasPrefix(s)
    }
}
