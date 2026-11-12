import Foundation
import Testing
@testable import QBCore

@Suite("نواة QB من Swift")
struct QBCoreTests {
    func makeCore() throws -> QbCore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qb-tests-\(UUID().uuidString)")
        return try QbCore(dataDir: dir.path)
    }

    @Test func helloReachesRust() {
        #expect(hello() == "QB core ready")
    }

    @Test func settingsRoundtrip() throws {
        let core = try makeCore()
        try core.setSetting(key: "lang", value: "ar")
        #expect(try core.setting(key: "lang") == "ar")
    }

    @Test func libraryAndProgress() throws {
        let core = try makeCore()
        try core.addToLibrary(item: LibraryItem(mediaId: "tt1", kind: .movie, title: "A", poster: nil, addedAt: 1))
        #expect(try core.inLibrary(mediaId: "tt1"))
        try core.saveProgress(progress: Progress(mediaId: "tt1", episodeId: nil, kind: .movie, title: "A", poster: nil, positionS: 60, durationS: nil, updatedAt: 2))
        #expect(core.continueWatching().first?.mediaId == "tt1")
        #expect(core.continueWatching().first?.fraction == nil)
    }

    @Test func subtitlesParse() throws {
        let core = try makeCore()
        let cues = core.parseSubtitleText(text: "1\n00:00:01,000 --> 00:00:02,000\nمرحبا\n", nameHint: nil)
        #expect(cues.count == 1)
        #expect(cues[0].text == "مرحبا")
        #expect(core.shiftCues(cues: cues, offsetMs: 500)[0].startMs == 1500)
    }

    @Test func badAddonFailsCleanly() async throws {
        let core = try makeCore()
        await #expect(throws: CoreError.self) {
            _ = try await core.installAddon(url: "http://127.0.0.1:9/x")
        }
        #expect(await core.addons().isEmpty)
    }

    @Test func normalizesUrls() throws {
        #expect(try normalizeAddonUrl(url: "stremio://a.com/x") == "https://a.com/x/manifest.json")
    }
}
