import SwiftUI
import UIKit

/// حالة التشغيل
enum PlaybackState: Equatable {
    case idle, loading, playing, paused, stalled, ended
    case failed(String)

    var isActive: Bool {
        switch self {
        case .playing, .stalled, .loading: true
        default: false
        }
    }
}

/// مسار صوت أو ترجمة داخل الملف
struct TrackOption: Identifiable, Hashable {
    let id: String
    let name: String
    var language: String?
}

/// سبب الفشل: هل يستاهل نجرب VLC؟
enum EngineFailure: Error {
    /// المشغّل الأصلي ما قدر يشغّل الملف (صيغة، صورة ما طلعت، علق)
    case nativeCannotPlay(String)
    /// المصدر نفسه ما يرد أو الملف خربان
    case sourceFailed(String)
}

/// المشغّلات: الأصلي (AVPlayer) وVLC. نفس الواجهة للاثنين عشان التحكم والترجمة واحدة.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kindName: String { get }
    /// المنظر اللي ينرسم فيه الفيديو
    var surface: UIView { get }
    var state: PlaybackState { get }
    var elapsed: Double { get }
    /// nil لو المدة مو معروفة (بث مباشر أو ملف بدون فهرس)
    var duration: Double? { get }
    var isBuffering: Bool { get }
    /// بث مباشر فعلًا (مو بس مدة ما وصلت للحين)
    var isLive: Bool { get }
    /// مقاس صورة الفيديو، صفر لين يُعرف
    var videoSize: CGSize { get }
    var supportsPiP: Bool { get }
    var supportsAirPlay: Bool { get }

    var onStateChange: ((PlaybackState) -> Void)? { get set }
    var onFailure: ((EngineFailure) -> Void)? { get set }
    var onTracksChanged: (() -> Void)? { get set }

    func load(url: URL, headers: [String: String], startAt: Double)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Float)
    /// يوقف ويفك الموارد. آمن لو اننادى أكثر من مرة
    func shutdown()

    var audioTracks: [TrackOption] { get }
    var selectedAudio: String? { get }
    func selectAudio(_ id: String)
    /// الترجمات اللي داخل الملف
    var embeddedSubtitles: [TrackOption] { get }
    var selectedEmbeddedSubtitle: String? { get }
    /// nil يطفي ترجمة الملف
    func selectEmbeddedSubtitle(_ id: String?)

    func startPiP()
    /// يرجّع الفيديو من الصورة للمشغّل
    func stopPiP()
    func setAutoPiP(_ on: Bool)
}

/// يركّب منظر المشغّل داخل أي مكان (المشغّل الكامل أو المصغّر).
/// آخر واحد ينضاف للنافذة ياخذ الفيديو، وما نوقف التشغيل لما ينشال.
final class SurfaceHostView: UIView {
    weak var surface: UIView? {
        didSet { attach() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { attach() }
    }

    private func attach() {
        guard let surface, window != nil || superview != nil else { return }
        if surface.superview !== self {
            surface.removeFromSuperview()
            surface.frame = bounds
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(surface)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let surface, surface.superview === self { surface.frame = bounds }
    }
}

struct EngineSurface: UIViewRepresentable {
    let surface: UIView?

    func makeUIView(context: Context) -> SurfaceHostView {
        let v = SurfaceHostView()
        v.surface = surface
        return v
    }

    func updateUIView(_ uiView: SurfaceHostView, context: Context) {
        if uiView.surface !== surface { uiView.surface = surface }
    }
}

/// صندوق عشان نمرر كائنات UIKit/VLC لطابور الأوامر (الوصول لها مرتّب من طابور واحد)
nonisolated final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
