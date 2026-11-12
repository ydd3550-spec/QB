import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import QBCore

/// الصوت والإضاءة بالسحب على طرف الشاشة: اليسار صوت، اليمين إضاءة.
/// المستوى يلحق الإصبع على طول، والكبسولة تطلع وقت السحب بس وتختفي بسرعة بعده.
/// الصوت يغيّر صوت الجهاز نفسه (نفس أزرار الصوت)، والكبسولة تطلع كمان لما تضغط أزرار الصوت.
/// الإضاءة ترجع لمستواها الأصلي لما تطلع من المشغّل أو من التطبيق.
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

    /// احتياط: لو النظام رفض تغيير صوت الجهاز، نغيّر صوت المشغّل نفسه
    @ObservationIgnored var onSoftwareVolume: ((Float) -> Void)?

    @ObservationIgnored private var startLevel: Double = 0
    @ObservationIgnored private var atEdge = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored fileprivate weak var volumeView: MPVolumeView?
    @ObservationIgnored private var volumeObserver: NSKeyValueObservation?
    /// آخر قيمة حطّيناها نحن لصوت الجهاز (عشان نفرّقها عن أزرار الصوت)
    @ObservationIgnored private var lastSetVolume: Float?
    @ObservationIgnored private var lastSetAt = Date.distantPast
    /// nil ما ندري للحين، false النظام ما يقبل نغيّر صوته فنستخدم صوت المشغّل
    @ObservationIgnored private var systemVolumeWorks: Bool?
    @ObservationIgnored private var softwareVolume: Double = 1
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    /// الإضاءة قبل ما نغيّرها أول مرة
    @ObservationIgnored private var originalBrightness: CGFloat?

    func level(_ kind: Kind) -> Double { kind == .volume ? volume : brightness }

    /// يبدأ يتابع صوت الجهاز (أزرار الصوت) وقت ما المشغّل ظاهر
    func startObserving() {
        guard volumeObserver == nil else { return }
        let session = AVAudioSession.sharedInstance()
        volume = systemVolumeWorks == false ? softwareVolume : Double(session.outputVolume)
        volumeObserver = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            Task { @MainActor in self?.systemVolumeChanged(v) }
        }
    }

    func stopObserving() {
        volumeObserver?.invalidate()
        volumeObserver = nil
    }

    private func systemVolumeChanged(_ v: Float) {
        if systemVolumeWorks == nil, let target = lastSetVolume, abs(v - target) < 0.04 {
            systemVolumeWorks = true
        }
        // تغيير جا منّا وقت السحب: الكبسولة أصلًا تلحق الإصبع
        if dragging, active == .volume { return }
        if let target = lastSetVolume, abs(v - target) < 0.02, Date().timeIntervalSince(lastSetAt) < 1 { return }
        // أزرار الصوت: الكبسولة تطلع بالمستوى الجديد (مؤشّر النظام مخفي وقت المشغّل)
        guard systemVolumeWorks != false else { return }
        hideTask?.cancel()
        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) { volume = Double(v) }
        if active != .volume {
            withAnimation(.easeOut(duration: 0.12)) { active = .volume }
        }
        scheduleHide(after: 900)
    }

    func begin(_ kind: Kind) {
        hideTask?.cancel()
        if kind == .volume {
            volume = systemVolumeWorks == false ? softwareVolume : Double(AVAudioSession.sharedInstance().outputVolume)
        } else {
            let current = Self.screen?.brightness ?? 0.5
            if originalBrightness == nil { originalBrightness = current }
            brightness = Double(current)
        }
        startLevel = level(kind)
        atEdge = false
        overshoot = 0
        dragging = true
        withAnimation(.easeOut(duration: 0.12)) { active = kind }
    }

    /// dy موجب = لتحت. السحب بنص ارتفاع الشاشة تقريبًا يغطي المدى كله
    func change(dy: CGFloat, height: CGFloat) {
        guard let kind = active, dragging else { return }
        let raw = PlayerLogic.sideLevel(start: startLevel, dy: dy, height: height)
        let clamped = min(max(raw, 0), 1)
        overshoot = raw - clamped
        let edge = clamped <= 0 || clamped >= 1
        if edge, !atEdge { Haptics.tap() }
        atEdge = edge
        switch kind {
        case .volume:
            volume = clamped
            setVolume(Float(clamped))
        case .brightness:
            brightness = clamped
            Self.screen?.brightness = CGFloat(clamped)
        }
    }

    func end() {
        dragging = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { overshoot = 0 }
        scheduleHide(after: 600)
    }

    private func scheduleHide(after ms: Int) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self, !self.dragging else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.active = nil }
        }
    }

    // MARK: - الصوت

    private func setVolume(_ v: Float) {
        if systemVolumeWorks == false {
            softwareVolume = Double(v)
            onSoftwareVolume?(v)
            return
        }
        guard let slider = volumeSlider else {
            // ما فيه طريقة نغيّر صوت الجهاز: صوت المشغّل نفسه
            systemVolumeWorks = false
            softwareVolume = Double(v)
            onSoftwareVolume?(v)
            return
        }
        lastSetVolume = v
        lastSetAt = Date()
        slider.setValue(v, animated: false)
        slider.sendActions(for: .valueChanged)
        guard systemVolumeWorks == nil else { return }
        // أول مرة: نتأكد إن صوت الجهاز تغيّر فعلًا، وإلا نحوّل لصوت المشغّل
        let before = AVAudioSession.sharedInstance().outputVolume
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.systemVolumeWorks == nil else { return }
            let now = AVAudioSession.sharedInstance().outputVolume
            if abs(now - v) < 0.04 || abs(now - before) > 0.01 {
                self.systemVolumeWorks = true
            } else if abs(before - v) > 0.06 {
                self.systemVolumeWorks = false
                self.softwareVolume = self.volume
                self.onSoftwareVolume?(Float(self.volume))
            }
        }
    }

    /// شريط الصوت داخل MPVolumeView (نبحث بكل الطبقات، مكانه يتغيّر بين إصدارات iOS)
    private var volumeSlider: UISlider? {
        guard let view = volumeView else { return nil }
        if view.window == nil { return nil }
        view.layoutIfNeeded()
        return Self.findSlider(in: view)
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        for sub in view.subviews {
            if let s = sub as? UISlider { return s }
            if let s = findSlider(in: sub) { return s }
        }
        return nil
    }

    // MARK: - الإضاءة

    /// نطلع من المشغّل أو من التطبيق: الإضاءة ترجع مثل ما كانت
    func restoreBrightness() {
        guard let original = originalBrightness else { return }
        Self.screen?.brightness = original
    }

    /// رجعنا للمشغّل من الخلفية: نرجّع الإضاءة اللي اخترتها
    func reapplyBrightness() {
        guard originalBrightness != nil else { return }
        Self.screen?.brightness = CGFloat(brightness)
    }

    /// المشغّل انقفل: الإضاءة ترجع ونبدأ من جديد المرة الجاية
    func playerClosed() {
        restoreBrightness()
        originalBrightness = nil
        stopObserving()
        hideTask?.cancel()
        active = nil
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
                // أقصر وأنحف، وداخل الحواف الآمنة (بعيد عن النوتش وطرف الشاشة)
                let h = min(geo.size.height * (landscape ? 0.36 : 0.2), landscape ? 128 : 150)
                let w: CGFloat = 26
                let inset: CGFloat = landscape ? 22 : 18
                let value = levels.level(kind)
                let stretch = 1 + min(abs(levels.overshoot), 0.25) * 0.35
                ZStack(alignment: .bottom) {
                    Capsule().fill(.black.opacity(0.25))
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(height: max(0, h * value))
                    Image(systemName: icon(kind, value))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(value > 0.12 ? .black.opacity(0.75) : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: w)
                        .padding(.bottom, 8)
                }
                .frame(width: w, height: h)
                .clipShape(Capsule())
                .glassEffect(.clear, in: .capsule)
                .scaleEffect(x: levels.dragging ? 1.06 : 1, y: stretch, anchor: levels.overshoot >= 0 ? .bottom : .top)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.85), value: value)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: levels.dragging)
                .position(x: kind == .volume ? inset + w / 2 : geo.size.width - inset - w / 2,
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

/// MPVolumeView مخفي: الطريقة الوحيدة نغيّر صوت الجهاز، ووجوده بالنافذة يخفي مؤشّر النظام فوق الفيديو
struct HiddenVolumeView: UIViewRepresentable {
    let levels: SideLevels

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        // لازم يكون داخل الشاشة وظاهر (ولو شوي) عشان النظام يقبل التغيير ويخفي مؤشّره
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        levels.volumeView = v
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if levels.volumeView !== uiView { levels.volumeView = uiView }
    }
}
