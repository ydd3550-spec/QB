import SwiftUI
import os
import UIKit
import QBCore

/// اتجاه الشاشة: التطبيق كله عمودي، والمشغّل بس يقبل الأفقي (ويدوّر له تلقائي لو الفيديو عرضي)
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func allowPlayerRotation() {
        mask = .allButUpsideDown
        refresh()
    }

    /// بعد ما تختفي شاشة المشغّل
    static func lockPortrait() {
        holding = false
        mask = .portrait
        refresh()
        if isLandscapeNow { request(.portrait) }
    }

    private static var holding = false

    /// وقت السحب لتحت: نثبّت الاتجاه الحالي عشان ميلان الجوال ما يلف الشاشة والبطاقة بين يديك
    static func holdCurrent() {
        guard !holding, mask == .allButUpsideDown, let o = scene?.effectiveGeometry.interfaceOrientation else { return }
        let m: UIInterfaceOrientationMask
        switch o {
        case .landscapeLeft: m = .landscapeLeft
        case .landscapeRight: m = .landscapeRight
        case .portrait: m = .portrait
        default: return
        }
        holding = true
        mask = m
        refresh()
    }

    /// السحب رجع أو انلغى: الدوران يرجع مسموح مثل قبل
    static func releaseHold() {
        guard holding else { return }
        holding = false
        let held = mask
        mask = .allButUpsideDown
        // نطلب نفس الاتجاه اللي هي فيه، فما تلف الشاشة لحالها لحظة ما يرجع الدوران مسموح
        request(held)
    }

    /// قبل إغلاق المشغّل: يرجّع عمودي. يرجّع true لو كانت أفقي ويبي وقت يدور
    @discardableResult
    static func restorePortrait() -> Bool {
        if holding {
            holding = false
            mask = .allButUpsideDown
        }
        let wasLandscape = isLandscapeNow
        if wasLandscape { request(.portrait) }
        return wasLandscape
    }

    static func rotate(toLandscape: Bool) {
        if toLandscape, !mask.contains(.landscapeRight) { mask = .allButUpsideDown; refresh() }
        request(toLandscape ? .landscapeRight : .portrait)
    }

    static var isLandscapeNow: Bool {
        scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
    }

    /// العرض أكبر من الطول بوضوح (مو مربع)
    static func isLandscapeVideo(_ size: CGSize) -> Bool {
        PlayerLogic.isLandscapeVideo(size)
    }

    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    private static func request(_ m: UIInterfaceOrientationMask) {
        guard let scene else { return }
        refresh()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { error in
            coreLog.info("orientation request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// يخلّي كل الشاشات المعروضة تعيد قراءة الاتجاهات المسموحة
    private static func refresh() {
        guard let scene else { return }
        for window in scene.windows {
            var vc = window.rootViewController
            while let c = vc {
                c.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = c.presentedViewController
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }
}
