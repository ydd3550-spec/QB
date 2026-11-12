import Testing
@testable import QBCore

@Suite("سجل البحث")
struct SearchHistoryTests {
    @Test func savesTrimmedAndMovesRepeatToFront() {
        var l = SearchHistory.adding("  Gorge ", to: [])
        l = SearchHistory.adding("batman", to: l)
        l = SearchHistory.adding("gorge", to: l)
        #expect(l == ["gorge", "batman"])
    }

    @Test func longerQueryReplacesItsPrefixes() {
        let l = SearchHistory.adding("Gorge", to: ["Gor", "Go", "batman"])
        #expect(l == ["Gorge", "batman"])
    }

    @Test func prefixOfSavedQueryIsNotAdded() {
        let l = SearchHistory.adding("Gor", to: ["batman", "Gorge"])
        #expect(l == ["Gorge", "batman"])
    }

    @Test func ignoresTooShort() {
        #expect(SearchHistory.adding(" G ", to: ["x y"]) == ["x y"])
    }

    @Test func cleansTypedJunk() {
        let junk = ["Gorge", "Gor", "Go", "game", "gam", "Gen", "Ge", "the gorge"]
        #expect(SearchHistory.cleaned(junk) == ["Gorge", "game", "Gen", "the gorge"])
    }
}
