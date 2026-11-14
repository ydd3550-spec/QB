import SwiftUI
import UIKit
import QBCore

/// سحب من طرف البداية (اليمين بالعربي، اليسار بالإنجليزي) يرجّعك للصفحة اللي قبل، مثل رجوع iOS الأصلي:
/// الصفحة تمشي مع إصبعك، والصفحة اللي قبلها تبان تحتها (تدخل من طرفها بحركة أبطأ وتنوّر)، مو سواد
struct EdgeSwipeBack: ViewModifier {
    let enabled: Bool
    /// شكل الصفحة اللي قبل (تنرسم تحت الصفحة وانت تسحب)
    let backdrop: UIImage?
    let action: () -> Void
    @Environment(\.layoutDirection) private var direction
    @State private var progress: CGFloat = 0
    @State private var leaving = false

    func body(content: Content) -> some View {
        let rtl = direction == .rightToLeft
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let p = min(progress / width, 1)
            // الحركة كلها بإحداثيات الشاشة نفسها (يسار ويمين حقيقيين)، والصفحة داخلها تبقى بالعربي.
            // بالعربي: تسحب من اليمين، الصفحة تمشي لليسار مع إصبعك، واللي قبلها تدخل من اليمين
            content
                .environment(\.layoutDirection, direction)
                // ظل خفيف على حافة الصفحة اللي تمشي (مثل iOS)
                .overlay(alignment: rtl ? .trailing : .leading) {
                    if progress > 0 {
                        LinearGradient(colors: rtl ? [.black.opacity(0.22 * (1 - p)), .clear] : [.clear, .black.opacity(0.22 * (1 - p))],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 14)
                            .offset(x: rtl ? 14 : -14)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
                .offset(x: rtl ? -progress : progress)
                .background {
                    if progress > 0 || leaving {
                        underlay(width: width, p: p, rtl: rtl)
                    }
                }
                .overlay(alignment: rtl ? .trailing : .leading) {
                    if enabled {
                        Color.clear
                            .frame(width: 22)
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .highPriorityGesture(drag(width: width))
                    }
                }
        }
        .environment(\.layoutDirection, .leftToRight)
        // رجعت للصفحة (فتحت البحث من جديد): تبدأ بمكانها، بدون حركة
        .onAppear { reset() }
    }

    private func reset() {
        guard progress != 0 || leaving else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            progress = 0
            leaving = false
        }
    }


    /// الصفحة اللي قبل: تبدأ مزحومة لطرفها ومعتّمة، وتوصل مكانها مع آخر السحب
    @ViewBuilder
    private func underlay(width: CGFloat, p: CGFloat, rtl: Bool) -> some View {
        ZStack {
            if let backdrop {
                Image(uiImage: backdrop)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color(uiColor: .systemBackground)
            }
            Color.black.opacity(0.18 * (1 - p))
        }
        // تبدأ مزحومة 30% لجهة طرف السحب وتوصل مكانها مع آخر السحب (نفس رجوع iOS)
        .offset(x: (rtl ? 1 : -1) * (width - progress) * 0.3)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                guard !leaving else { return }
                progress = max(0, inward(v.translation.width))
            }
            .onEnded { v in
                guard !leaving else { return }
                if PlayerLogic.edgeSwipeCompletes(progress: inward(v.translation.width), predicted: inward(v.predictedEndTranslation.width), width: width) {
                    leaving = true
                    Haptics.tap()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.92)) { progress = width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(240))
                        action()
                        // الصفحة تبقى برا الشاشة لين يخلص تبديل التبويب كله. قبل كانت ترجع مكانها بنفس اللحظة،
                        // فتبان شفافة ربع ثانية فوق الصفحة اللي رجعت لها وتختفي
                        try? await Task.sleep(for: .milliseconds(700))
                        // بعد ما صارت مخفية (لو انفتحت من جديد بهالوقت، onAppear رجّعها قبل)
                        reset()
                    }
                } else {
                    // يرجع بنطّة خفيفة
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) { progress = 0 }
                }
            }
    }

    /// المسافة باتجاه داخل الشاشة من طرف البداية (الإحداثيات العامة ما تنعكس بالعربي)
    private func inward(_ dx: CGFloat) -> CGFloat {
        direction == .rightToLeft ? -dx : dx
    }
}

/// صورة للنافذة مثل ما هي على الشاشة الحين (للصفحة اللي تبان تحت وانت تسحب للرجوع)
enum WindowSnapshot {
    @MainActor
    static func capture() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}

extension View {
    func edgeSwipeBack(enabled: Bool, backdrop: UIImage? = nil, action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, backdrop: backdrop, action: action))
    }
}
