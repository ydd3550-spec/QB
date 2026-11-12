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
        mask = .portrait
        refresh()
        if isLandscapeNow { request(.portrait) }
    }

    /// قبل إغلاق المشغّل: يرجّع عمودي. يرجّع true لو كانت أفقي ويبي وقت يدور
    @discardableResult
    static func restorePortrait() -> Bool {
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
