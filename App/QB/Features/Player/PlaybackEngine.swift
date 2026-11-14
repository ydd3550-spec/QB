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

    /// كم بايت وصل من الشبكة لين الحين (nil = ما نعرف). للتعليق: ننتظر طول ما فيه بيانات توصل
    var bytesReceived: Int64? { get }
    /// عدّاد يزيد مع كل إطار ينعرض (nil = ما نعرف). للصورة الواقفة والوقت ماشي
    var framesShown: Int? { get }
    /// صورة من الفيديو عند ثانية معيّنة (لمعاينة السحب). nil = المشغّل ما يقدر يعطيها
    func frameImage(at seconds: Double) async -> UIImage?
    /// الصورة واقفة: نربط مخرج الصورة من جديد ونرجع لآخر إطار انعرض، بدون ما نوقف المشغّل
    func recoverPicture(at seconds: Double)
}

extension PlaybackEngine {
    var bytesReceived: Int64? { nil }
    var framesShown: Int? { nil }
    func frameImage(at seconds: Double) async -> UIImage? { nil }
    func recoverPicture(at seconds: Double) { seek(to: seconds); refreshLayout() }
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

    /// زوايا البطاقة (بمقاس الشاشة الكاملة)
    var cardCorner: CGFloat = 0 {
        didSet { if cardCorner != oldValue { applyZoom() } }
    }

    /// مقاس الشاشة الكامل اللي تنرسم عليه الصورة. وقت السحب لتحت لو صغّر SwiftUI مقاس هذا المنظر نفسه
    /// (بدل ما يحرّكه بتحويل)، كان منظر المشغّل يتغيّر مقاسه كل إطار، وAVPlayerLayer وVLC يعيدون حساب مكان
    /// الصورة بعده بإطار أو أكثر، فتتحرك الصورة داخل البطاقة لحالها. الحين منظر المشغّل يبقى بنفس المقاس دايمًا،
    /// ويصغر بتحويل رسم بس بنفس النسبة وبنفس الإطار، فالصورة قطعة وحدة مع البطاقة
    private var baseSize: CGSize = .zero

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

    /// نفس الشكل وأصغر (تصغير البطاقة)، ولا مقاس جديد فعلًا (دوران، مصغّر، أول مرة)؟
    private func updateBase() {
        let b = bounds.size
        guard b.width > 1, b.height > 1 else { return }
        let base = baseSize
        if base.width < 1 || b.width > base.width + 0.5 || b.height > base.height + 0.5 {
            baseSize = b
            return
        }
        let sameShape = abs(b.width / b.height - base.width / base.height) < 0.01 * (base.width / base.height)
        if !sameShape { baseSize = b }
    }

    /// كم مصغّر هذا المنظر عن مقاس الشاشة الكامل (1 = مو مصغّر)
    private var cardScale: CGFloat {
        guard baseSize.width > 1 else { return 1 }
        return min(1, bounds.width / baseSize.width)
    }

    /// بالمقاس والنص بس (مو frame): الـ frame مع تحويل غير الأصلي يخرب الحساب
    private func place(_ surface: UIView) {
        updateBase()
        let size = baseSize.width > 1 ? baseSize : bounds.size
        if surface.bounds.size != size { surface.bounds = CGRect(origin: .zero, size: size) }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if surface.center != c { surface.center = c }
    }

    private func applyZoom() {
        let s = cardScale
        // الزوايا بنفس تصغير البطاقة، فتطابق زوايا قناع SwiftUI بالضبط
        let corner = cardCorner * s
        if layer.cornerRadius != corner { layer.cornerRadius = corner }
        guard let surface, surface.superview === self else { return }
        let k = zoom * s
        let t = k == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: k, y: k)
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
        v.cardCorner = cornerRadius
        return v
    }

    func updateUIView(_ uiView: SurfaceHostView, context: Context) {
        if uiView.surface !== surface { uiView.surface = surface }
        if uiView.isHidden != hidden { uiView.isHidden = hidden }
        // الزوايا تتبع السحب إطار بإطار وبدون حركة UIKit خاصة فيها: حركة UIKit على طبقة الفيديو كانت
        // تمشي بتوقيت غير توقيت البطاقة، فتطلع الصورة متحركة داخلها
        if uiView.cardCorner != cornerRadius {
            UIView.performWithoutAnimation { uiView.cardCorner = cornerRadius }
        }
        guard uiView.zoom != zoom else { return }
        if context.transaction.animation != nil, !context.transaction.disablesAnimations {
            // نفس حركة SwiftUI بالضبط (spring التكبير)
            context.animate { uiView.zoom = zoom }
        } else {
            uiView.zoom = zoom
        }
    }
}

/// صندوق عشان نمرر كائنات UIKit/VLC لطابور الأوامر (الوصول لها مرتّب من طابور واحد)
nonisolated final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

