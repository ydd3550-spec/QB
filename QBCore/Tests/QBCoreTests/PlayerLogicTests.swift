import CoreGraphics
import Testing
@testable import QBCore

@Suite("منطق المشغّل")
struct PlayerLogicTests {
    @Test func loadingIsNotLive() {
        // وقت التحميل (0:00 والمدة ما وصلت) ما تطلع «مباشر»
        #expect(PlayerLogic.trailingTime(elapsed: 0, duration: nil, live: false) == .unknown)
        #expect(PlayerLogic.trailingTime(elapsed: 0, duration: 0, live: false) == .unknown)
    }

    @Test func remainingOnceDurationKnown() {
        #expect(PlayerLogic.trailingTime(elapsed: 30, duration: 100, live: false) == .remaining(70))
        #expect(PlayerLogic.trailingTime(elapsed: 130, duration: 100, live: false) == .remaining(0))
        // لو المدة معروفة الباقي يغلب حتى لو المشغّل قال مباشر
        #expect(PlayerLogic.trailingTime(elapsed: 30, duration: 100, live: true) == .remaining(70))
    }

    @Test func liveOnlyForRealLive() {
        #expect(PlayerLogic.trailingTime(elapsed: 12, duration: nil, live: true) == .live)
    }

    @Test func landscapeDetection() {
        #expect(PlayerLogic.isLandscapeVideo(CGSize(width: 1920, height: 800)))
        #expect(!PlayerLogic.isLandscapeVideo(CGSize(width: 1080, height: 1920)))
        #expect(!PlayerLogic.isLandscapeVideo(CGSize(width: 1000, height: 1000)))
        #expect(!PlayerLogic.isLandscapeVideo(.zero))
    }

    @Test func swipeThreshold() {
        #expect(PlayerLogic.swipeDismisses(translation: 200, predicted: 200))
        #expect(PlayerLogic.swipeDismisses(translation: 60, predicted: 500))
        #expect(!PlayerLogic.swipeDismisses(translation: 60, predicted: 120))
    }
}
