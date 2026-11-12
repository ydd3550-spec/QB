import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import QBCore

/// الصوت والإضاءة بالسحب على طرف الشاشة: اليسار صوت، اليمين إضاءة.
/// المستوى يلحق الإصبع على طول، والكبسولة تطلع وقت السحب بس وتختفي بسرعة بعده.
@MainActor
@Observable
final class SideLevels {
    enum Kind { case volume, brightness }

    private(set) var active: Kind?
    private(set) var volume: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    private(set) var brightness: Double = 0.5
    /// مطّ خفيف لما توصل لأقل أو أعلى وتكمّل تسحب
    private(set) var overshoot: Double = 0
    private(set) var dragging = false

    @ObservationIgnored private var startLevel: Double = 0
    @ObservationIgnored private var atEdge = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored fileprivate weak var volumeSlider: UISlider?

    func level(_ kind: Kind) -> Double { kind == .volume ? volume : brightness }

    func begin(_ kind: Kind) {
        hideTask?.cancel()
        if kind == .volume {
            volume = Double(AVAudioSession.sharedInstance().outputVolume)
        } else {
            brightness = Double(Self.screen?.brightness ?? 0.5)
        }
        startLevel = level(kind)
        atEdge = false
        overshoot = 0
        dragging = true
        withAnimation(.easeOut(duration: 0.12)) { active = kind }
    }

    /// dy موجب = لتحت. السحب بنص ارتفاع الشاشة تقريبًا يغطي المدى كله
    func change(dy: CGFloat, height: CGFloat) {
        guard let kind = active else { return }
        let raw = PlayerLogic.sideLevel(start: startLevel, dy: dy, height: height)
        let clamped = min(max(raw, 0), 1)
        overshoot = raw - clamped
        let edge = clamped <= 0 || clamped >= 1
        if edge, !atEdge { Haptics.tap() }
        atEdge = edge
        switch kind {
        case .volume:
            volume = clamped
            volumeSlider?.value = Float(clamped)
        case .brightness:
            brightness = clamped
            Self.screen?.brightness = CGFloat(clamped)
        }
    }

    func end() {
        dragging = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { overshoot = 0 }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self?.active = nil }
        }
    }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
}

/// الكبسولة العمودية (يسار للصوت، يمين للإضاءة). تمتد شوي وقت السحب وترجع بنعومة
struct SideLevelPill: View {
    let levels: SideLevels

    var body: some View {
        GeometryReader { geo in
            if let kind = levels.active {
                let landscape = geo.size.width > geo.size.height
                let h = min(landscape ? geo.size.height * 0.5 : geo.size.height * 0.26, 190)
                let value = levels.level(kind)
                let stretch = 1 + min(abs(levels.overshoot), 0.25) * 0.35
                ZStack(alignment: .bottom) {
                    Capsule().fill(.black.opacity(0.25))
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(height: max(0, h * value))
                    Image(systemName: icon(kind, value))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(value > 0.12 ? .black.opacity(0.75) : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.bottom, 10)
                }
                .frame(width: 34, height: h)
                .clipShape(Capsule())
                .glassEffect(.clear, in: .capsule)
                .scaleEffect(x: levels.dragging ? 1.06 : 1, y: stretch, anchor: levels.overshoot >= 0 ? .bottom : .top)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.85), value: value)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: levels.dragging)
                .position(x: kind == .volume ? 40 + (landscape ? 24 : 0) : geo.size.width - 40 - (landscape ? 24 : 0),
                          y: geo.size.height / 2)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }

    private func icon(_ kind: SideLevels.Kind, _ v: Double) -> String {
        switch kind {
        case .brightness: return v < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if v <= 0.001 { return "speaker.slash.fill" }
            return v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }
}

/// MPVolumeView مخفي: الطريقة الوحيدة نغيّر صوت الجهاز، ووجوده يخفي مؤشّر النظام فوق الفيديو
struct HiddenVolumeView: UIViewRepresentable {
    let levels: SideLevels

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        v.alpha = 0.001
        v.isUserInteractionEnabled = false
        Task { @MainActor in
            levels.volumeSlider = v.subviews.compactMap { $0 as? UISlider }.first
        }
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if levels.volumeSlider == nil {
            levels.volumeSlider = uiView.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}
