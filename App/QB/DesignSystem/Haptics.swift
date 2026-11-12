import SwiftUI
import UIKit

/// الاهتزاز: خفيف بس، عند التشغيل واختيار مصدر ونهاية السحب
enum Haptics {
    static let light = SensoryFeedback.impact(weight: .light)
    static let select = SensoryFeedback.selection
    static let success = SensoryFeedback.success

    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func notifySuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func notifyError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
