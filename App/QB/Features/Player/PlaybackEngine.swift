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
    /// the line under the name in the tracks sheet (nil = the default for its section)
    var detail: String? = nil
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
    /// صوت المشغّل نفسه (0…1). احتياط لو ما قدرنا نغيّر صوت الجهاز
    func setVolume(_ volume: Float)
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

    /// التكبير بالإصبع: true يملّي الشاشة (يقص الأطراف)، false الحجم الأصلي بحواف سودا.
    /// viewport مقاس الشاشة كاملة، يحتاجه VLC عشان يقص على نسبتها
    func setVideoFill(_ fill: Bool, viewport: CGSize)
    /// الوقت الحي للتشغيل الحين (للترجمة): من المشغّل نفسه مو آخر قراءة كل ربع ثانية
    var liveTime: Double { get }
    /// المقاس تغيّر أو رجع التطبيق: نعيد ترتيب الصورة بالنسبة الصح (الحجم الأصلي أو التكبير بالقص)
    func refreshLayout()

    func startPiP()
    /// يرجّع الفيديو من الصورة للمشغّل
    func stopPiP()
    func setAutoPiP(_ on: Bool)
}

/// يركّب منظر المشغّل داخل أي مكان (المشغّل الكامل أو المصغّر).
/// آخر واحد ينضاف للنافذة ياخذ الفيديو، وما نوقف التشغيل لما ينشال.
///
/// التكبير وقص الزوايا هنا بـ UIKit نفسه: طبقة AVPlayerLayer ومنظر VLC ما يتقصّون بقناع SwiftUI،
/// فنقصّهم بطبقة هذا المنظر (نفس نصف قطر زوايا البطاقة بالضبط)، ونكبّر الفيديو داخلها بتحويل رسم بس
/// (نفس النسبة بالطول والعرض، من النص)، فمقاس منظر المشغّل ما يتغيّر أبدًا وما ينعاد بناء الصورة.
final class SurfaceHostView: UIView {
    weak var surface: UIView? {
        didSet { attach() }
    }

    /// تكبير الفيديو داخل الشاشة (1 = الحجم الأصلي)
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { applyZoom() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.cornerCurve = .continuous
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
            surface.transform = .identity
            surface.frame = bounds
            surface.autoresizingMask = []
            addSubview(surface)
        }
        place(surface)
        applyZoom()
    }

    /// بالمقاس والنص بس (مو frame): الـ frame مع تحويل غير الأصلي يخرب الحساب
    private func place(_ surface: UIView) {
        if surface.bounds.size != bounds.size { surface.bounds = CGRect(origin: .zero, size: bounds.size) }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if surface.center != c { surface.center = c }
    }

    private func applyZoom() {
        guard let surface, surface.superview === self else { return }
        let t = zoom == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: zoom, y: zoom)
        if surface.transform != t { surface.transform = t }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let surface, surface.superview === self {
            place(surface)
            applyZoom()
        }
    }

    /// المنظر يتشال من هنا (يروح للمصغّر أو لمشغّل جديد): يرجع بدون تكبير
    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        subview.transform = .identity
    }
}

struct EngineSurface: UIViewRepresentable {
    let surface: UIView?
    /// تكبير الفيديو (1 = الحجم الأصلي). يتحرّك مع حركة SwiftUI نفسها (نفس الـ spring)
    var zoom: CGFloat = 1
    /// زوايا البطاقة وقت السحب لتحت، تتقصّ فيها الصورة نفسها
    var cornerRadius: CGFloat = 0
    /// تختفي الصورة نفسها (طبقة الفيديو ما تلحق opacity حق SwiftUI دايمًا وقت دوران الشاشة)
    var hidden = false

    func makeUIView(context: Context) -> SurfaceHostView {
        let v = SurfaceHostView()
        v.surface = surface
        v.zoom = zoom
        v.layer.cornerRadius = cornerRadius
        return v
    }

    func updateUIView(_ uiView: SurfaceHostView, context: Context) {
        if uiView.surface !== surface { uiView.surface = surface }
        if uiView.isHidden != hidden { uiView.isHidden = hidden }
        let changes = uiView.zoom != zoom || uiView.layer.cornerRadius != cornerRadius
        guard changes else { return }
        let apply = {
            uiView.zoom = zoom
            uiView.layer.cornerRadius = cornerRadius
        }
        if context.transaction.animation != nil, !context.transaction.disablesAnimations {
            // نفس حركة SwiftUI بالضبط (spring التكبير أو رجوع البطاقة)
            context.animate(changes: apply)
        } else {
            apply()
        }
    }
}

/// صندوق عشان نمرر كائنات UIKit/VLC لطابور الأوامر (الوصول لها مرتّب من طابور واحد)
nonisolated final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
