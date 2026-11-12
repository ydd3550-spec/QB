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

    @Test func playButtonIsSmall() {
        // أصغر من نسخة 8 (كان 84)
        #expect(PlayerLogic.Transport.play <= 56)
    }

    @Test func seekBurstStacks() {
        #expect(PlayerLogic.nextSeekBurst(previous: nil) == 10)
        #expect(PlayerLogic.nextSeekBurst(previous: 10) == 20)
        #expect(PlayerLogic.nextSeekBurst(previous: 20) == 30)
    }

    @Test func rippleStaysAwayFromCenterButton() {
        // القوس ما يوصل لزر التشغيل اللي بالنص حتى بأضيق شاشة عمودي
        let width: CGFloat = 375
        let arc = width * PlayerLogic.rippleWidthFraction
        #expect(arc < width / 2 - PlayerLogic.Transport.play / 2)
    }

    @Test func sideLevelIsFast() {
        // ربع الشاشة لفوق = نص المدى
        #expect(abs(PlayerLogic.sideLevel(start: 0.2, dy: -200, height: 800) - 0.7) < 0.0001)
        #expect(PlayerLogic.sideLevel(start: 0.5, dy: 400, height: 800) < 0)
    }

    @Test func verticalDragZones() {
        let size = CGSize(width: 900, height: 400)
        #expect(PlayerLogic.verticalDrag(startX: 100, startY: 200, size: size) == .volume)
        #expect(PlayerLogic.verticalDrag(startX: 800, startY: 200, size: size) == .brightness)
        #expect(PlayerLogic.verticalDrag(startX: 450, startY: 200, size: size) == .dismiss)
        // من فوق دايمًا خروج حتى على الطرف
        #expect(PlayerLogic.verticalDrag(startX: 100, startY: 20, size: size) == .dismiss)
    }

    @Test func edgeSwipeBackThreshold() {
        #expect(PlayerLogic.edgeSwipeCompletes(progress: 150, predicted: 150, width: 400))
        #expect(PlayerLogic.edgeSwipeCompletes(progress: 60, predicted: 260, width: 400))
        #expect(!PlayerLogic.edgeSwipeCompletes(progress: 60, predicted: 100, width: 400))
    }

    @Test func swipeThreshold() {
        #expect(PlayerLogic.swipeDismisses(translation: 200, predicted: 200))
        #expect(PlayerLogic.swipeDismisses(translation: 60, predicted: 500))
        #expect(!PlayerLogic.swipeDismisses(translation: 60, predicted: 120))
    }

    @Test func pinchZoom() {
        // تفتح أصابعك: ملء الشاشة، تضمّها: الحجم الأصلي
        #expect(PlayerLogic.pinchZoomDecision(magnification: 1.3, filled: false) == true)
        #expect(PlayerLogic.pinchZoomDecision(magnification: 0.7, filled: true) == false)
        // نفس الوضع أو حركة صغيرة: ما يتغيّر شي
        #expect(PlayerLogic.pinchZoomDecision(magnification: 1.3, filled: true) == nil)
        #expect(PlayerLogic.pinchZoomDecision(magnification: 0.7, filled: false) == nil)
        #expect(PlayerLogic.pinchZoomDecision(magnification: 1.03, filled: false) == nil)
        #expect(PlayerLogic.pinchZoomDecision(magnification: 0.97, filled: true) == nil)
        // المعاينة محدودة
        #expect(PlayerLogic.pinchPreviewScale(1) == 1)
        #expect(PlayerLogic.pinchPreviewScale(5) <= 1.08)
        #expect(PlayerLogic.pinchPreviewScale(0.1) >= 0.94)
    }
}
