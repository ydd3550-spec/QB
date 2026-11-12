import SwiftUI
import QBCore

/// سحب من طرف البداية (اليمين بالعربي، اليسار بالإنجليزي) يرجّعك للصفحة اللي قبل، والصفحة تمشي مع إصبعك
struct EdgeSwipeBack: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    @Environment(\.layoutDirection) private var direction
    @State private var progress: CGFloat = 0
    @State private var leaving = false

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            content
                .offset(x: progress)
                .opacity(1 - Double(min(progress / max(width, 1), 1)) * 0.25)
                .overlay(alignment: .leading) {
                    if enabled {
                        Color.clear
                            .frame(width: 22)
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .highPriorityGesture(drag(width: width))
                    }
                }
        }
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
                    withAnimation(.easeOut(duration: 0.18)) { progress = width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(190))
                        action()
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { progress = 0 }
                        leaving = false
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { progress = 0 }
                }
            }
    }

    /// المسافة باتجاه داخل الشاشة من طرف البداية (الإحداثيات العامة ما تنعكس بالعربي)
    private func inward(_ dx: CGFloat) -> CGFloat {
        direction == .rightToLeft ? -dx : dx
    }
}

extension View {
    func edgeSwipeBack(enabled: Bool, action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, action: action))
    }
}
