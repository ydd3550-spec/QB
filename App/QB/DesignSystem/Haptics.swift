import SwiftUI

/// الاهتزاز: خفيف بس، عند التشغيل واختيار مصدر ونهاية السحب
enum Haptics {
    static let light = SensoryFeedback.impact(weight: .light)
    static let select = SensoryFeedback.selection
}
