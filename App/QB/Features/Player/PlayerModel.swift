import SwiftUI
import UIKit
import QBCore

/// اللي ينشغّل الحين: العمل والحلقة وقائمة المصادر اللي نجرّب منها
struct PlayContext {
    let ref: MediaRef
    let meta: MetaDetail?
    let video: Video?
    var sources: [RankedSource]

    /// معرّف البث: معرّف الحلقة للمسلسلات، ومعرّف الفيلم للأفلام
    var streamId: String { video?.id ?? ref.id }

    var title: String { meta?.name ?? ref.name }

    var subtitle: String? {
        guard let video else { return nil }
        if let s = video.season, let e = video.episode {
            let label = L("الموسم %@ · الحلقة %@", "\(s)", "\(e)")
            return video.title.isEmpty ? label : "\(label) · \(video.title)"
        }
        return video.title
    }
}

/// يدير التشغيل كله: يختار المشغّل، يحوّل لـ VLC لو فشل الأصلي، يجرب مصدر ثاني،
/// يحمّل الترجمات، يحفظ التقدّم، ويشغّل الحلقة الجاية.
@Observable
@MainActor
final class PlayerModel {
    weak var app: AppModel?

    // العرض
    /// كم انسحبت شاشة المشغّل لتحت (0…1): الصفحة اللي وراها تكبر وتفتح معها
    var dismissProgress: Double = 0

    var isPresented = false {
        didSet {
            if isPresented, !oldValue {
                coverOnScreen = true
                OrientationLock.allowPlayerRotation()
            }
        }
    }
    /// شاشة المشغّل لسا على الشاشة (حتى وهي تنزل). المصغّر ما يطلع لين تختفي تمامًا،
    /// عشان ما يتغيّر شكل التبويبات وقت حركة الإغلاق.
    private(set) var coverOnScreen = false
    var miniHidden = false
    private(set) var pipActive = false
    var showsMini: Bool { engine != nil && context != nil && !isPresented && !coverOnScreen && !miniHidden && !pipActive }

    // التشغيل
    private(set) var engine: (any PlaybackEngine)?
    private(set) var context: PlayContext?
    private(set) var source: RankedSource?
    private(set) var state: PlaybackState = .idle
    private(set) var elapsed: Double = 0
    /// آخر مكان صحيح وصله التشغيل (PlaybackRecovery.swift): ما يرجع للصفر بتعليق ولا خطأ ولا مشغّل جديد لسا يحمّل.
    /// كل استعادة وتحديث ورابط جديد ومصدر ثاني ورجوع للتطبيق تبدأ منه، وهو اللي ينحفظ بالتقدّم
    @ObservationIgnored private var resume = ResumeTracker()
    var resumePoint: Double { resume.position }
    /// الصورة واقفة والوقت ماشي (الترجمة والصوت يكمّلون)
    @ObservationIgnored private var frameWatch = FrameWatch()
    @ObservationIgnored private var frameRecoveries = 0
    @ObservationIgnored private var frameRecoveredAt = Date.distantPast
    /// آخر مرة وصلت بيانات جديدة من الشبكة (للتعليق: ننتظر طول ما فيه بيانات توصل)
    @ObservationIgnored private var lastBytes: Int64 = -1
    @ObservationIgnored private var bytesAt = Date()
    /// كم مرة قال المشغّل "خلص" وهو بالنص (انقطاع)
    @ObservationIgnored private var earlyEnds = 0
    private(set) var duration: Double?
    private(set) var isBuffering = false
    /// بث مباشر فعلًا (حسب المشغّل)، مو بس مدة ما وصلت
    private(set) var isLive = false
    private(set) var videoSize: CGSize = .zero
    /// آخر مصدر دوّرنا الشاشة له تلقائيًا، عشان ما نعاند المستخدم لو رجّعها عمودي
    private var autoRotatedFor: String?
    private(set) var engineName = ""
    /// The engine shown in the controls (label, PiP, AirPlay): only changes once a picture plays,
    /// so the controls don't jump while loading tries AVPlayer then VLC
    private(set) var settledEngineName = ""
    private(set) var settledSupportsPiP = false
    private(set) var settledSupportsAirPlay = false
    /// AVPlayer already couldn't play a source of this title: the next sources start straight in VLC
    /// (before: every source went AVPlayer -> VLC -> next source AVPlayer -> VLC ...)
    private var nativeFailedThisTitle = false
    /// The user's own engine choice from the player (true = native, false = VLC), kept for this title
    private(set) var manualNative: Bool?
    private(set) var errorMessage: String?
    /// تفاصيل الفشل الحقيقية (المشغّل، السبب، الموقع، رد السيرفر) تطلع تحت الرسالة ومعها زر نسخ
    private(set) var failureDetail: String?
    private var failureLog: [String] = []
    /// المصادر اللي عطيناها محاولة ثانية بمشغّل جديد قبل ما ننتقل لغيرها
    private var freshRetried: Set<String> = []
    /// كمّلنا من هالثانية (يطلع زر "من البداية" شوي)
    private(set) var resumedFrom: Double?
    private(set) var showTryAnother = false
    private(set) var rate: Float = 1
    /// التكبير بالإصبع (ملء الشاشة). ينحفظ طول ما نفس العمل شغّال، ويظل بعد التدوير والتحويل لـ VLC
    private(set) var videoFill = false
    /// مقاس شاشة المشغّل كاملة (يتغيّر مع التدوير)
    private var zoomViewport: CGSize = .zero
    var surface: UIView? { engine?.surface }
    var isPlaying: Bool { state == .playing || state == .stalled }

    // المسارات
    private(set) var audioTracks: [TrackOption] = []
    private(set) var selectedAudio: String?
    private(set) var embeddedSubtitles: [TrackOption] = []
    private(set) var selectedEmbedded: String?

    // الترجمات الخارجية (من الإضافات، تنقرا بمحلّل النواة)
    private(set) var externalSubtitles: [SubtitleTrack] = []
    private(set) var selectedExternal: String?
    private(set) var loadingSubtitle = false
    private var cues: [Cue] = []
    private(set) var subtitleOffset: Double = 0
    private(set) var cueText: String?

    // الحلقة الجاية
    private(set) var nextUp: Video?
    private(set) var nextCountdown: Int?
    private var nextTask: Task<Void, Never>?

    // مشابه
    private(set) var similar: [MetaPreview] = []

    private var tickTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var autoSourceTask: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private var loadingSince = Date()
    private var reportedOk = false
    private var triedSources: Set<String> = []
    private var autoAdvances = 0
    private var core: QbCore? { app?.core }

    // MARK: - بدء التشغيل

    /// يشغّل مصدر معيّن. startAt nil يعني يكمّل من آخر مكان محفوظ
    func play(_ source: RankedSource, context: PlayContext, startAt: Double? = nil, freshTitle: Bool = false) {
        saveProgress(force: true)
        nextTask?.cancel()
        nextUp = nil
        nextCountdown = nil
        triedSources = []
        autoAdvances = 0
        freshRetried = []
        nativeFailedThisTitle = false
        manualNative = nil
        lastKnownDuration = ((try? core?.progress(mediaId: context.ref.id)) ?? nil)?.durationS
        failureLog = []
        failureDetail = nil
        // كل مرة تفتح الفيلم يدوّر للأفقي من جديد (قبل كان يتذكر إنه دوّر لنفس المصدر فما يدوّر ثاني مرة)
        autoRotatedFor = nil
        let changedTitle = freshTitle || self.context?.streamId != context.streamId
        self.context = context
        if changedTitle {
            // التكبير يتذكّره طول ما التطبيق مفتوح (مثل يوتيوب)، ما يرجع للأصلي مع كل فيلم
            externalSubtitles = []
            subtitleChosenByUser = false
            selectedExternal = nil
            cues = []
            cueText = nil
            subtitleOffset = 0
            similar = []
            loadExternalSubtitles(context: context, source: source)
            loadSimilar(context: context)
        } else {
            mergeSourceSubtitles(source)
        }
        let resume = startAt ?? resumePosition(for: context)
        resumedFrom = (startAt == nil && resume > 1) ? resume : nil
        if changedTitle {
            self.resume.reset(to: resume)
            earlyEnds = 0
            videoSize = .zero
        } else if abs(resume - self.resume.position) > 0.5 {
            self.resume.reset(to: resume)
        }
        start(source, startAt: resume, forceVLC: false)
        miniHidden = false
        isPresented = true
    }

    /// يكمّل من آخر مكان لو نفس الحلقة وما خلصت
    func resumePosition(for context: PlayContext) -> Double {
        guard let p = (try? core?.progress(mediaId: context.ref.id)) ?? nil else { return 0 }
        guard p.episodeId == context.video?.id else { return 0 }
        if let f = p.fraction, f > 0.95 { return 0 }
        return p.positionS > 15 ? p.positionS - 3 : 0
    }

    private func start(_ source: RankedSource, startAt: Double, forceVLC: Bool, forceNative: Bool = false) {
        stopEngine()
        self.source = source
        triedSources.insert(source.id)
        errorMessage = nil
        failureDetail = nil
        showTryAnother = false
        reportedOk = false
        loadingSince = Date()
        // مشغّل جديد: لو هو استكمال لنفس المكان نكمّل نفس المتتبّع، وإلا (اختيار مكان ثاني) نبدأ منه
        if abs(startAt - resume.position) < 0.5 { resume.engineRestarted() } else { resume.reset(to: startAt) }
        frameWatch.reset()
        lastBytes = -1
        bytesAt = Date()
        elapsed = startAt
        duration = nil
        isLive = false
        // مقاس الفيديو يبقى مثل ما هو لين المشغّل الجديد يعرف مقاسه (ينصفّر بس مع فيلم أو حلقة جديدة):
        // المقاس الصفري كان ينزّل الترجمة لتحت الشاشة ويرجّع التكبير للأصلي بعد كل استعادة
        audioTracks = []
        embeddedSubtitles = []
        selectedAudio = nil
        selectedEmbedded = nil

        switch source.target {
        case let .youTube(ytId):
            openExternal(URL(string: "https://www.youtube.com/watch?v=\(ytId)"))
            return
        case let .external(url):
            openExternal(URL(string: url))
            return
        case let .direct(urlString, headers):
            guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                fail(L("رابط المصدر غير صالح"))
                return
            }
            // Native first for everything it can open (smoothest); VLC only when the source needs it
            // or native already failed on this title. The user's own choice in the player wins.
            let automaticVLC = source.engine == .vlc || app?.preferredEngine == "vlc" || nativeFailedThisTitle
            let useVLC: Bool
            if forceNative { useVLC = false }
            else if forceVLC { useVLC = true }
            else if let manualNative { useVLC = !manualNative }
            else { useVLC = automaticVLC }
            // Hybrid: a source that would go to VLC only because of its container (MKV) is remuxed on the fly
            // to HLS so the native player plays it (smoother, hardware, PiP/AirPlay). If the codec can't play
            // natively (DTS, TrueHD, VP9 ...) or the file has no index, it plays in VLC as before.
            // also when the user picked the native player for a source that needs VLC as-is
            let needsContainerHelp = useVLC ? manualNative == nil : (source.engine == .vlc || nativeFailedThisTitle)
            let tryRemux = !forceVLC && needsContainerHelp && remuxable(url: url, source: source)
            let engine: any PlaybackEngine
            if useVLC && !tryRemux {
                let vlc = VLCEngine()
                // a track picked in the native player's menu that only VLC plays (DTS, TrueHD, VobSub ...)
                vlc.startAudioTrack = pendingVLCAudio
                vlc.startSubtitleTrack = pendingVLCSubtitle
                engine = vlc
            } else {
                engine = makeNative()
            }
            pendingVLCAudio = nil
            pendingVLCSubtitle = nil
            wire(engine)
            self.engine = engine
            engineName = engine.kindName
            applyZoom()
            state = .loading
            isBuffering = true
            engine.setRate(rate)
            if softwareVolume < 1 { engine.setVolume(softwareVolume) }
            startTicking()
            closeRemux()
            if tryRemux {
                let token = UUID()
                remuxToken = token
                let headerMap = headers
                Task { [weak self, weak engine] in
                    let opened: RemuxedStream?
                    do {
                        opened = try await remuxOpen(url: url.absoluteString, headers: headerMap)
                    } catch {
                        print("[QB] remux not possible: \(error)")
                        opened = nil
                    }
                    guard let self, self.remuxToken == token, let engine, engine === self.engine else {
                        if let opened { remuxClose(playlistUrl: opened.playlistUrl) }
                        return
                    }
                    if let opened, let local = URL(string: opened.playlistUrl) {
                        self.remuxURL = opened.playlistUrl
                        self.remuxInfo = opened
                        self.remuxedSourceId = source.id
                        engine.load(url: local, headers: [:], startAt: startAt)
                    } else {
                        // not remuxable: same source, same second, in VLC (no toast, no flicker in the controls)
                        self.remuxFailed.insert(source.id)
                        self.start(source, startAt: startAt, forceVLC: true)
                    }
                }
                return
            }
            if useVLC, VLCEngine.stopping > 0 {
                // نسخة VLC القديمة لسا تسكّر اتصالها بنفس الرابط: ننتظرها بدل ما نفتح الرابط مرتين
                Task { [weak self, weak engine] in
                    await VLCEngine.waitForPreviousStop()
                    guard let self, let engine, engine === self.engine else { return }
                    engine.load(url: url, headers: headers, startAt: startAt)
                }
            } else {
                engine.load(url: url, headers: headers, startAt: startAt)
            }
        }
    }

    // MARK: - remux (MKV -> HLS for the native player)

    private var remuxURL: String?
    /// what the remuxer found in the file: PGS tracks drawn by the app, tracks only VLC plays
    private var remuxInfo: RemuxedStream?
    private var remuxedSourceId: String?
    /// VLC starts on these tracks (picked in the native player's menu, playable by VLC only)
    private var pendingVLCAudio: Int?
    private var pendingVLCSubtitle: Int?
    /// PGS track drawn over the native player (index into remuxInfo.pgs), and what's on screen
    private var selectedPGS: Int?
    private var pgsShownId: Int64 = -1
    private var pgsBusy = false
    /// the user turned subtitles off or picked one: no automatic PGS after that
    private var subtitleChosenByUser = false
    private var remuxToken: UUID?
    /// sources that turned out not remuxable (don't try again this session)
    private var remuxFailed: Set<String> = []

    private func remuxable(url: URL, source: RankedSource) -> Bool {
        guard !remuxFailed.contains(source.id) else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let path = url.path.lowercased()
        let name = (source.title + " " + (source.description ?? "")).lowercased()
        // only Matroska (or no extension, checked by the remuxer itself); AVI, TS, FLV ... stay in VLC
        let other = [".avi", ".ts", ".flv", ".wmv", ".m2ts", ".mpg", ".mpeg", ".ogv", ".rmvb", ".3gp", ".webm"]
        if other.contains(where: { path.hasSuffix($0) }) { return false }
        // codecs the native player can't decode: skip the attempt (the remuxer would refuse them anyway)
        // (DTS / TrueHD audio is fine: the remuxer plays a compatible track of the same language natively,
        // or says no and VLC takes over at the same second)
        let noNative = ["vp9", "av1", "xvid", "divx"]
        if noNative.contains(where: { name.contains($0) }) { return false }
        return true
    }

    private func closeRemux() {
        remuxToken = nil
        if let remuxURL { remuxClose(playlistUrl: remuxURL) }
        remuxURL = nil
        remuxInfo = nil
        remuxedSourceId = nil
        selectedPGS = nil
        pgsShownId = -1
        (engine as? NativeEngine)?.setImageSubtitle(nil, canvas: .zero, rect: .zero)
    }

    // MARK: - PGS (image subtitles) over the native player

    private func selectPGS(_ index: Int?) {
        guard let remuxURL else { return }
        selectedPGS = index
        pgsShownId = -1
        (engine as? NativeEngine)?.setImageSubtitle(nil, canvas: .zero, rect: .zero)
        remuxPgsSelect(playlistUrl: remuxURL, index: index.map { UInt32($0) })
        if index != nil { updatePGS() }
    }

    /// what's on screen now (called with the subtitle tick); the bitmap is built off the main thread
    private func updatePGS() {
        guard let remuxURL, selectedPGS != nil, !pgsBusy, let native = engine as? NativeEngine else { return }
        let now = native.liveTime
        guard now.isFinite else { return }
        pgsBusy = true
        let known = pgsShownId
        let ms = Int64((now * 1000).rounded())
        Task.detached(priority: .userInitiated) { [weak self] in
            let frame = remuxPgsAt(playlistUrl: remuxURL, timeMs: ms, knownId: known)
            let image = frame.flatMap { $0.rgba.isEmpty ? nil : PlayerModel.makeImage($0) }
            await MainActor.run {
                guard let self else { return }
                self.pgsBusy = false
                guard self.remuxURL == remuxURL, self.selectedPGS != nil, let native = self.engine as? NativeEngine else { return }
                guard let frame else {
                    if self.pgsShownId != -1 {
                        self.pgsShownId = -1
                        native.setImageSubtitle(nil, canvas: .zero, rect: .zero)
                    }
                    return
                }
                guard frame.id != self.pgsShownId, let image else { return }
                self.pgsShownId = frame.id
                native.setImageSubtitle(image,
                                        canvas: CGSize(width: Int(frame.canvasW), height: Int(frame.canvasH)),
                                        rect: CGRect(x: Int(frame.x), y: Int(frame.y), width: Int(frame.w), height: Int(frame.h)))
            }
        }
    }

    nonisolated private static func makeImage(_ f: RemuxPgsFrame) -> CGImage? {
        let w = Int(f.w), h = Int(f.h)
        guard w > 0, h > 0, f.rgba.count >= w * h * 4 else { return nil }
        // straight alpha -> premultiplied (what Core Animation draws)
        var px = [UInt8](f.rgba.prefix(w * h * 4))
        var i = 0
        while i < px.count {
            let a = UInt16(px[i + 3])
            if a < 255 {
                px[i] = UInt8((UInt16(px[i]) * a + 127) / 255)
                px[i + 1] = UInt8((UInt16(px[i + 1]) * a + 127) / 255)
                px[i + 2] = UInt8((UInt16(px[i + 2]) * a + 127) / 255)
            }
            i += 4
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// switches to VLC at the same second, starting on a track only VLC plays
    private func reopenInVLC(audio: Int?, subtitle: Int?) {
        guard let source else { return }
        pendingVLCAudio = audio
        pendingVLCSubtitle = subtitle
        manualNative = nil
        triedSources.remove(source.id)
        start(source, startAt: resumePoint, forceVLC: true)
    }

    private func makeNative() -> NativeEngine {
        let native = NativeEngine()
        native.setAutoPiP(app?.autoPiP ?? true)
        native.onPiPActive = { [weak self] active in
            self?.pipActive = active
        }
        native.onPiPRestore = { [weak self] in
            self?.miniHidden = false
            self?.isPresented = true
        }
        return native
    }

    private func wire(_ engine: any PlaybackEngine) {
        engine.onFailure = { [weak self, weak engine] failure in
            guard let self, let engine, engine === self.engine else { return }
            self.handle(failure)
        }
        engine.onTracksChanged = { [weak self, weak engine] in
            guard let self, let engine, engine === self.engine else { return }
            self.readTracks()
        }
        engine.onStateChange = { [weak self, weak engine] state in
            guard let self, let engine, engine === self.engine else { return }
            self.engineStateChanged(state)
        }
    }

    private func openExternal(_ url: URL?) {
        guard let url else {
            fail(L("رابط المصدر غير صالح"))
            return
        }
        UIApplication.shared.open(url)
        context = nil
        source = nil
        state = .idle
        isPresented = false
    }

    // MARK: - الفشل والتحويل

    private func handle(_ failure: EngineFailure) {
        guard let source else { return }
        let position = resumePoint
        noteFailure(failure, source: source, position: position)
        var isDrop = true
        if case .nativeCannotPlay = failure { isDrop = reportedOk }
        let canRecover = isDrop && (reportedOk || pendingRestore != nil) && recoveryAttempts < 2
        if !canRecover {
            pendingRestore = nil
            isReloading = false
        }
        switch failure {
        case .nativeCannotPlay where remuxedSourceId == source.id && !canRecover:
            // the remuxed stream didn't play natively: same second in VLC, quietly (source itself is fine)
            remuxFailed.insert(source.id)
            closeRemux()
            start(source, startAt: position, forceVLC: true)
        case _ where canRecover:
            // المصدر كان شغّال وانقطع (رجوع من الخلفية، النت فصل، الرابط انتهى): نستعيده هو نفسه بهدوء
            // من نفس الثانية بدل ما نقول "المصدر ما اشتغل" وننقل لغيره
            let keep = pendingRestore?.keepPaused ?? false
            recoverSource(reason: "failure", keepPaused: keep)
        case .sourceFailed where remuxedSourceId == source.id && !reportedOk:
            remuxFailed.insert(source.id)
            closeRemux()
            start(source, startAt: position, forceVLC: true)
        case .nativeCannotPlay:
            // الأصلي ما قدر: نحفظ إن هذا المصدر يحتاج VLC ونحوّل من نفس الثانية
            try? core?.markSourceFailed(sourceId: source.id, nativeFailed: true)
            nativeFailedThisTitle = true
            if manualNative == true { manualNative = nil }
            app?.showToast(L("نحوّل لمشغّل VLC"))
            start(source, startAt: position, forceVLC: true)
        case .sourceFailed:
            // ما اشتغل أبد: نعطيه محاولة وحدة بمشغّل جديد (بعد ما يسكّر القديم) قبل ما نحكم إنه خربان
            if !reportedOk, !freshRetried.contains(source.id) {
                freshRetried.insert(source.id)
                let vlc = engineName == "VLC"
                stopEngine()
                state = .loading
                isBuffering = true
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let self, self.source?.id == source.id, self.errorMessage == nil else { return }
                    self.start(source, startAt: position, forceVLC: vlc)
                }
                return
            }
            try? core?.markSourceFailed(sourceId: source.id, nativeFailed: false)
            // ينقل لحاله للي بعده لين تخلص المصادر، وبعدها بس تطلع رسالة الخطأ
            if autoAdvances < 8, let next = nextCandidate() {
                autoAdvances += 1
                app?.showToast(L("المصدر ما اشتغل، نجرب مصدر ثاني"))
                mergeSourceSubtitles(next)
                start(next, startAt: position, forceVLC: false)
            } else {
                fail(L("ما قدرنا نشغّل هذا المصدر"))
            }
        }
    }

    /// يسجّل وش صار بالضبط: المشغّل والسبب والموقع ومن أي ثانية
    private func noteFailure(_ failure: EngineFailure, source: RankedSource, position: Double) {
        let reason: String
        switch failure {
        case let .nativeCannotPlay(r): reason = r
        case let .sourceFailed(r): reason = r
        }
        var host = "-"
        var urlString = ""
        if case let .direct(u, _) = source.target {
            urlString = u
            host = URL(string: u)?.host() ?? "-"
        }
        let line = "\(engineName.isEmpty ? "?" : engineName): \(reason) · \(host) · \(L("من")) \(TimeFormat.clock(position))"
        failureLog.append(line)
        if failureLog.count > 6 { failureLog.removeFirst(failureLog.count - 6) }
        failureDetail = failureLog.joined(separator: "\n")
        probe(urlString, source: source)
    }

    /// نسأل السيرفر مباشرة عشان نعرف رده (403، 404، انتهى الرابط…)
    private func probe(_ urlString: String, source: RankedSource) {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        if case let .direct(_, headers) = source.target {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }
        Task { [weak self] in
            let line: String
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let http = response as? HTTPURLResponse
                let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "-"
                line = "HTTP \(http?.statusCode ?? 0) · \(type)"
            } catch {
                line = "HTTP: \(error.localizedDescription)"
            }
            guard let self, self.source?.id == source.id else { return }
            self.failureLog.append(line)
            self.failureDetail = self.failureLog.joined(separator: "\n")
        }
    }

    /// النص اللي ينسخه زر النسخ: التفاصيل كلها مع الرابط
    var failureReport: String {
        var lines = [errorMessage ?? "", failureDetail ?? ""]
        if let source, case let .direct(u, _) = source.target { lines.append(u) }
        lines.append("\(context?.title ?? "") · \(source?.addon ?? "")")
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func startOver() {
        resumedFrom = nil
        seek(to: 0)
    }

    func dismissResumeHint() { resumedFrom = nil }

    private func fail(_ message: String) {
        pendingRestore = nil
        isReloading = false
        stopEngine()
        errorMessage = message
        state = .failed(message)
        isBuffering = false
    }

    /// المصدر الجاي: أول مصدر شغّال ما جربناه، ولو ما فيه أول مصدر ما هو ميت
    private func nextCandidate() -> RankedSource? {
        guard let list = context?.sources else { return nil }
        let playable = list.filter { if case .direct = $0.target { return !triedSources.contains($0.id) } else { return false } }
        return playable.first(where: \.isAlive) ?? playable.first(where: { !$0.isUnreachable })
    }

    var canTryAnother: Bool { nextCandidate() != nil }

    /// زر "جرّب مصدر ثاني"
    func tryAnotherSource() {
        guard let next = nextCandidate() else {
            app?.showToast(L("ما فيه مصادر ثانية"))
            return
        }
        mergeSourceSubtitles(next)
        start(next, startAt: resumePoint, forceVLC: false)
    }

    /// اختيار مصدر من داخل المشغّل
    func switchSource(_ s: RankedSource) {
        guard s.id != source?.id else { return }
        mergeSourceSubtitles(s)
        start(s, startAt: resumePoint, forceVLC: false)
    }

    func retry() {
        guard let source else { return }
        triedSources.remove(source.id)
        start(source, startAt: resumePoint, forceVLC: source.engine == .vlc || engineName == "VLC")
    }

    /// صورة من الفيديو عند ثانية معيّنة، لمعاينة السحب. nil = المشغّل ما يقدر يعطيها (نعرض الغلاف)
    func previewFrame(at seconds: Double) async -> UIImage? {
        guard let engine, !isReloading else { return nil }
        if case .failed = state { return nil }
        return await engine.frameImage(at: seconds)
    }

    // MARK: - إعادة التحميل والاستعادة (زر التحديث، الرجوع من الخلفية، انقطاع مصدر كان شغّال)

    /// وش كان مختار قبل إعادة التحميل، نرجّعه أول ما تجهز المسارات بالمشغّل الجديد
    private struct PendingRestore {
        var audio: String?
        var embedded: String?
        var pgs: Int?
        var keepPaused: Bool
        var audioDone = false
        var subtitleDone = false
        var pauseDone = false
        let since = Date()
    }

    private var pendingRestore: PendingRestore?
    /// كم مرة استعدنا نفس المصدر بدون ما يشتغل بينها (عشان ما نلف للأبد على مصدر خربان)
    private var recoveryAttempts = 0
    private var lastRecoveryAt: Date?
    /// زر التحديث شغّال (يطلع مكانه مؤشر صغير)
    private(set) var isReloading = false
    /// وقت ما راح التطبيق للخلفية، وهل كان شغّال قبلها
    private var backgroundedAt: Date?
    private var playingBeforeBackground = false
    /// وقت ما بدأ التقطّع (شغّال بس الوقت واقف)
    private var stalledSince: Date?

    /// زر التحديث: نفس المصدر ونفس الثانية ونفس الصوت والترجمة والسرعة، بدون ما ينقفل المشغّل
    func reloadInPlace() {
        guard source != nil, !isReloading else { return }
        recoveryAttempts = 0
        recoverSource(reason: "manual", keepPaused: !(isPlaying || state == .loading) && errorMessage == nil && reportedOk)
    }

    /// يعيد بناء المشغّل لنفس المصدر من نفس الثانية. لو المصدر نفسه ما رد (الرابط انتهى) نطلب روابط المصادر
    /// من جديد بهدوء ونكمّل بنفس المصدر برابطه الجديد. ما تطلع رسالة "ما فيه مصدر" إلا لو فعلًا ما فيه شي يشتغل
    private func recoverSource(reason: String, keepPaused: Bool) {
        guard let source else { return }
        let position = resumePoint
        recoveryAttempts += 1
        lastRecoveryAt = Date()
        isReloading = true
        stalledSince = nil
        let wasVLC = engineName == "VLC"
        if let prev = pendingRestore {
            // استعادة داخل استعادة: المسارات الحالية انمسحت مع المشغّل الجديد، فنكمّل باللي كان محفوظ
            pendingRestore = PendingRestore(audio: prev.audio, embedded: prev.embedded, pgs: prev.pgs,
                                            keepPaused: prev.keepPaused || keepPaused)
        } else {
            pendingRestore = PendingRestore(audio: selectedAudio,
                                            embedded: selectedPGS == nil ? selectedEmbedded : nil,
                                            pgs: selectedPGS,
                                            keepPaused: keepPaused)
        }
        coreLog.info("player recover (\(reason, privacy: .public)) attempt \(self.recoveryAttempts) at \(position)")
        triedSources.remove(source.id)
        errorMessage = nil
        if recoveryAttempts <= 1 {
            start(source, startAt: position, forceVLC: wasVLC, forceNative: !wasVLC && manualNative == true)
        } else {
            // المرة الثانية: الرابط نفسه غالبًا انتهى. نجيب روابط جديدة لنفس العمل ونلقى نفس المصدر فيها
            reresolve(source, position: position, wasVLC: wasVLC)
        }
        if keepPaused, let engine { engine.setVolume(0) }
    }

    private func reresolve(_ old: RankedSource, position: Double, wasVLC: Bool) {
        guard let core, let context else {
            start(old, startAt: position, forceVLC: wasVLC)
            return
        }
        stopEngine()
        state = .loading
        isBuffering = true
        let kind = context.ref.kind
        let streamId = context.streamId
        Task { [weak self] in
            var fresh: [RankedSource] = []
            let stream = CoreClient.sources(core, kind: kind, id: streamId)
            let deadline = Date().addingTimeInterval(15)
            for await event in stream {
                if case let .sources(list) = event { fresh = list }
                if case .finished = event { break }
                if fresh.contains(where: { Self.sameSource($0, old) }) || Date() > deadline { break }
            }
            guard let self, self.context?.streamId == streamId, self.source?.id == old.id || self.source == nil else { return }
            let match = fresh.first { Self.sameSource($0, old) }
            if let match {
                if var ctx = self.context, !fresh.isEmpty {
                    ctx.sources = fresh
                    self.context = ctx
                }
                self.start(match, startAt: position, forceVLC: wasVLC)
                if self.pendingRestore?.keepPaused == true { self.engine?.setVolume(0) }
            } else {
                // ما رجع نفس المصدر: نرجع لمسار الفشل العادي (يجرب اللي بعده، وبعدها بس تطلع الرسالة)
                self.isReloading = false
                self.pendingRestore = nil
                self.source = old
                self.handle(.sourceFailed(L("الرابط انتهى")))
            }
        }
    }

    /// نفس المصدر حتى لو تغيّر رابطه (الرابط فيه توكن يتجدد): نفس الإضافة والعنوان والوصف والجودة
    nonisolated private static func sameSource(_ a: RankedSource, _ b: RankedSource) -> Bool {
        if a.id == b.id { return true }
        return a.addon == b.addon && a.title == b.title && a.description == b.description && a.quality == b.quality
    }

    /// المشغّل الجديد جهز: نرجّع الصوت والترجمة، ولو كان واقف نوقفه بعد ما تطلع أول صورة.
    /// كل خطوة تنحفظ قبل ما نكلّم المشغّل، لأن اختيار مسار ينادي readTracks من جديد (وما نبيها تتكرر)
    private func applyPendingRestore() {
        guard var r = pendingRestore, let engine else { return }
        if Date().timeIntervalSince(r.since) > 20 {
            finishRestore()
            return
        }
        if !r.audioDone, !audioTracks.isEmpty {
            r.audioDone = true
            pendingRestore = r
            if let a = r.audio, a != selectedAudio, audioTracks.contains(where: { $0.id == a }) {
                engine.selectAudio(a)
            }
        }
        if !r.subtitleDone, !audioTracks.isEmpty || !embeddedSubtitles.isEmpty || remuxInfo != nil {
            if let pgs = r.pgs {
                if remuxURL != nil, remuxInfo != nil {
                    r.subtitleDone = true
                    pendingRestore = r
                    (engine as? NativeEngine)?.deselectLegible()
                    selectPGS(pgs)
                }
            } else if let e = r.embedded {
                if embeddedSubtitles.contains(where: { $0.id == e }) {
                    r.subtitleDone = true
                    pendingRestore = r
                    if engine.selectedEmbeddedSubtitle != e { engine.selectEmbeddedSubtitle(e) }
                }
            } else {
                r.subtitleDone = true
                pendingRestore = r
                // ما كان فيه ترجمة داخلية: نطفي اللي يختارها المشغّل الجديد لحاله (عشان ما تطلع مع الخارجية)
                if engine.selectedEmbeddedSubtitle != nil, selectedExternal != nil || subtitleChosenByUser {
                    engine.selectEmbeddedSubtitle(nil)
                }
            }
        }
        guard pendingRestore != nil else { return }
        if r.keepPaused, !r.pauseDone, engine.state == .playing {
            r.pauseDone = true
            pendingRestore = r
            engine.setVolume(0)
            // نخليه يرسم أول صورة ثم نوقفه، فترجع لنفس الصورة واقفة بدل شاشة سودا
            let token = ObjectIdentifier(engine)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, let e = self.engine, ObjectIdentifier(e) == token else { return }
                e.pause()
                e.setVolume(self.softwareVolume)
                self.sync()
                self.finishRestoreIfDone()
            }
            return
        }
        pendingRestore = r
        finishRestoreIfDone()
    }

    private func finishRestoreIfDone() {
        guard let r = pendingRestore else { return }
        if Date().timeIntervalSince(r.since) > 20 {
            finishRestore()
            return
        }
        let subsDone = r.subtitleDone || Date().timeIntervalSince(r.since) > 6
        if r.audioDone || Date().timeIntervalSince(r.since) > 6, subsDone, !r.keepPaused || r.pauseDone {
            if engine?.state == .playing || engine?.state == .paused || !r.keepPaused { finishRestore() }
        }
    }

    private func finishRestore() {
        if pendingRestore?.keepPaused == true { engine?.setVolume(softwareVolume) }
        pendingRestore = nil
        isReloading = false
    }

    /// The engine picker in the player: reopen the same source in the chosen engine from the same second
    func chooseEngine(native: Bool) {
        guard let source else { return }
        manualNative = native
        let isNative = engineName != "VLC"
        guard native != isNative || errorMessage != nil else { return }
        triedSources.remove(source.id)
        if !native { try? core?.markSourceFailed(sourceId: source.id, nativeFailed: true) }
        start(source, startAt: resumePoint, forceVLC: !native, forceNative: native)
    }

    /// يجبر VLC للمصدر الحالي (من قائمة المشغّل)
    func reopenInVLC() {
        guard let source, engineName != "VLC" else { return }
        try? core?.markSourceFailed(sourceId: source.id, nativeFailed: true)
        start(source, startAt: resumePoint, forceVLC: true)
    }

    // MARK: - التحكم

    func togglePlay() {
        guard let engine else {
            if case .failed = state { retry() }
            return
        }
        if isPlaying || state == .loading {
            engine.pause()
            saveProgress(force: true)
        } else {
            engine.play()
        }
        sync()
    }

    /// من شاشة القفل / السماعات
    func resumeFromRemote() {
        guard let engine, !isPlaying else { return }
        engine.play()
        sync()
    }

    func pauseFromRemote() {
        guard isPlaying else { return }
        togglePlay()
    }

    func pause() {
        engine?.pause()
        saveProgress(force: true)
        sync()
    }

    func seek(to seconds: Double) {
        guard let engine else { return }
        var t = max(0, seconds)
        if let d = duration, d > 0 { t = min(t, d - 1) }
        engine.seek(to: t)
        resume.userSeek(to: t, now: Self.clock)
        frameWatch.reset()
        elapsed = t
        updateCue()
    }

    func skip(_ delta: Double) {
        // elapsed يبقى على الهدف المعلّق لين يوصل له المشغّل (SeekGuard بالمشغّلين)،
        // فالضغطات المتتالية تنحسب من الهدف: +10 +10 = +20، مو من المكان القديم
        seek(to: elapsed + delta)
    }

    /// صوت المشغّل نفسه (احتياط لو صوت الجهاز ما تغيّر). ينطبق على أي مشغّل يبدأ بعده
    private(set) var softwareVolume: Float = 1

    func setSoftwareVolume(_ v: Float) {
        softwareVolume = v
        engine?.setVolume(v)
    }

    func setRate(_ r: Float) {
        rate = r
        engine?.setRate(r)
    }

    func startPiP() {
        engine?.startPiP()
    }

    var supportsPiP: Bool { engine?.supportsPiP ?? false }
    var supportsAirPlay: Bool { engine?.supportsAirPlay ?? false }

    /// يصغّر المشغّل (يكمل بالمشغّل المصغّر فوق التبويبات)
    /// تصغير: من زر السهم (بحركة) أو بعد السحب لتحت (الشاشة طالعة أصلًا، فبدون حركة ثانية)
    func minimize(animated: Bool = true) {
        miniHidden = false
        dismissCover(animated: animated)
    }

    /// يرجّع الشاشة عمودي أول (لو كانت أفقي) وبعدين يقفل شاشة المشغّل
    private func dismissCover(animated: Bool) {
        guard isPresented else { return }
        let rotating = OrientationLock.restorePortrait()
        let apply: () -> Void = { [weak self] in
            guard let self, self.isPresented else { return }
            if animated {
                self.isPresented = false
            } else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { self.isPresented = false }
            }
        }
        if rotating {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(420))
                apply()
            }
        } else {
            apply()
        }
    }

    /// شاشة المشغّل ظهرت: ندوّر للأفقي لو الفيديو عرضي
    func coverAppeared() {
        coverOnScreen = true
        applyZoom()
        autoRotatedFor = nil
        autoRotateIfNeeded()
    }

    /// فيديو عرضي بجوال عمودي: ندوّر للأفقي مرة وحدة لكل مصدر
    func autoRotateIfNeeded() {
        guard isPresented, let key = source?.id ?? context?.streamId, autoRotatedFor != key else { return }
        guard OrientationLock.isLandscapeVideo(videoSize) else { return }
        autoRotatedFor = key
        OrientationLock.rotate(toLandscape: true)
    }

    /// زر التدوير بالمشغّل
    func toggleOrientation() {
        autoRotatedFor = source?.id ?? context?.streamId
        OrientationLock.rotate(toLandscape: !OrientationLock.isLandscapeNow)
    }

    func expand() {
        guard context != nil else { return }
        miniHidden = false
        isPresented = true
    }

    /// سحب المصغّر لتحت: يختفي ويوقف مؤقتًا
    func hideMini() {
        pause()
        miniHidden = true
    }

    /// يقفل التشغيل نهائيًا
    func close() {
        saveProgress(force: true)
        nextTask?.cancel()
        autoSourceTask?.cancel()
        subtitleTask?.cancel()
        stopEngine()
        context = nil
        source = nil
        state = .idle
        errorMessage = nil
        nextUp = nil
        nextCountdown = nil
        cues = []
        cueText = nil
        externalSubtitles = []
        selectedExternal = nil
        dismissCover(animated: true)
        app?.refreshContinueWatching()
    }

    // MARK: - التكبير

    func setVideoFill(_ on: Bool) {
        videoFill = on
        applyZoom()
    }

    /// الشاشة تغيّر مقاسها (تدوير): VLC يحتاج نسبة القص الجديدة
    func setZoomViewport(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1, size != zoomViewport else { return }
        zoomViewport = size
        applyZoom()
    }

    /// المصغّر يعرض الحجم الأصلي دايمًا، والتكبير يرجع أول ما ترجع شاشة المشغّل
    private func applyZoom() {
        // التكبير صار رسم فوق الفيديو (في شاشة المشغّل نفسها)، فالمشغّل يبقى دايم بالحجم الأصلي:
        // ما فيه قص من VLC ولا تغيير بـ videoGravity يخلّي الصورة تنط أو تتمطط
        engine?.setVideoFill(false, viewport: zoomViewport)
    }

    func didDismiss() {
        coverOnScreen = false
        applyZoom()
        OrientationLock.lockPortrait()
        if case .failed = state { close() }
        if engine == nil, context != nil, state == .idle { close() }
    }

    private func stopEngine() {
        closeRemux()
        tickTask?.cancel()
        tickTask = nil
        engine?.onFailure = nil
        engine?.onStateChange = nil
        engine?.onTracksChanged = nil
        engine?.shutdown()
        engine = nil
        pipActive = false
        NowPlaying.shared.clear()
    }

    private var playingBeforeInterruption = false

    /// Calls / alarms / unplugged headphones
    func hookAudioSession() {
        let keeper = AudioSessionKeeper.shared
        keeper.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            self.playingBeforeInterruption = self.isPlaying
        }
        keeper.onInterruptionEnded = { [weak self] shouldResume in
            guard let self, self.engine != nil else { return }
            if shouldResume, self.playingBeforeInterruption, !self.isPlaying { self.engine?.play() }
            self.playingBeforeInterruption = false
        }
        keeper.onOutputLost = { [weak self] in
            guard let self, self.engine != nil, self.isPlaying else { return }
            self.pause()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard engine != nil else { return }
        switch phase {
        case .background:
            saveProgress(force: true)
            backgroundedAt = Date()
            playingBeforeBackground = isPlaying
            // VLC ما يدعم صورة داخل صورة، نوقفه بدل ما يرسم بالخلفية
            if engineName == "VLC" { pause() }
        case .active:
            AudioSessionKeeper.shared.activate(force: true)
            engine?.refreshLayout()
            sync()
            settleEngine()
            let wasInBackground = backgroundedAt != nil
            backgroundedAt = nil
            lastForeground = Date()
            // VLC: مخرج الصورة واتصاله ما يعيشون بعد الخلفية (هذا سبب الشاشة السودا والتعليق). نبنيه من جديد
            // بنفس المصدر والثانية والمسارات، ويبقى واقف مثل ما تركته (نوقفه احنا وقت الخلفية)
            if wasInBackground, engineName == "VLC", !pipActive, errorMessage == nil, source != nil, !isReloading {
                recoveryAttempts = 0
                recoverSource(reason: "foreground", keepPaused: true)
            }
            // رجعت للتطبيق والفيديو بالصورة: نرجّعه للمشغّل بنفس المكان وهو شغّال
            if pipActive {
                miniHidden = false
                isPresented = true
                engine?.stopPiP()
            }
        default:
            break
        }
    }

    // MARK: - المؤقّت

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                // Subtitles every 100 ms from the live clock; the rest of the state every 200 ms
                if beat % 2 == 0 { self?.sync() } else { self?.updateCue(); self?.updatePGS() }
                beat &+= 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sync() {
        guard let engine else { return }
        let now = Self.clock
        // الوقت المعروض والمحفوظ من المتتبّع: المشغّل اللي يبلّغ صفر وهو يحمّل أو يعلّق أو يخرب ما يرجّعه لورا
        let advancing = engine.state == .playing && !engine.isBuffering
        let reading = engine.isLive ? ResumeTracker.Reading(display: engine.elapsed) : resume.observe(engine.elapsed, playing: advancing, now: now)
        if let back = reading.correctTo {
            // المشغّل رجع يشتغل من البداية لحاله (خادم التحويل أو VLC ابتدا من الصفر): نرجّعه لمكانه
            coreLog.info("player restarted from \(engine.elapsed) by itself, back to \(back)")
            engine.seek(to: back)
        }
        if elapsed != reading.display { elapsed = reading.display }
        if duration != engine.duration { duration = engine.duration }
        if isLive != engine.isLive { isLive = engine.isLive }
        let size = StickyVideoSize.merge(current: (Double(videoSize.width), Double(videoSize.height)),
                                         reported: (Double(engine.videoSize.width), Double(engine.videoSize.height)))
        let stickySize = CGSize(width: size.w, height: size.h)
        if videoSize != stickySize { videoSize = stickySize }
        watchNetwork(engine)
        watchFrames(engine, now: now)
        if isBuffering != engine.isBuffering { isBuffering = engine.isBuffering }
        if state != engine.state, engine.state != .idle { state = engine.state }
        updateCue()
        let waiting = state == .loading || (isBuffering && !reportedOk)
        // وقت الاستعادة نعطيه وقت أطول قبل ما نعرض "جرّب مصدر ثاني" (المصدر نفسه شغّال، بس يرجع يتصل)
        let shouldOffer = waiting && Date().timeIntervalSince(loadingSince) > (pendingRestore != nil ? 12 : 5)
        if pendingRestore != nil { finishRestoreIfDone() }
        if showTryAnother != shouldOffer { showTryAnother = shouldOffer }
        if isPlaying { saveProgress(force: false) }
        watchStall()
        // وقّف (إيقاف مؤقت أو انقطع): نحفظ المكان على طول
        if wasPlayingAtSync, !isPlaying { saveProgress(force: true) }
        wasPlayingAtSync = isPlaying
        if let context {
            NowPlaying.shared.attach(self)
            NowPlaying.shared.update(title: context.title, subtitle: context.subtitle,
                                     artworkURL: context.meta?.poster ?? context.ref.poster,
                                     elapsed: elapsed, duration: duration, playing: isPlaying)
        }
    }

    /// شغّال بس ما يتقدّم (بعد الرجوع من الخلفية غالبًا الاتصال مات): نستعيد نفس المصدر بهدوء
    private func watchStall() {
        if let at = lastRecoveryAt, recoveryAttempts > 0, state == .playing, !isBuffering,
           Date().timeIntervalSince(at) > 30 {
            recoveryAttempts = 0
        }
        guard reportedOk, pendingRestore == nil, !isReloading, engine != nil else { stalledSince = nil; return }
        let stuck = state == .stalled || (state == .playing && isBuffering)
        guard stuck else { stalledSince = nil; return }
        if stalledSince == nil { stalledSince = Date() }
        let justBack = backgroundedAt == nil && lastForeground.map { Date().timeIntervalSince($0) < 20 } == true
        let stalled = stalledSince.map { Date().timeIntervalSince($0) } ?? 0
        // شبكة ضعيفة: طول ما البيانات توصل ننتظر والمؤشر يدور، وما نعيد التحميل إلا لما الشبكة تسكت فعلًا
        let quiet: Double? = lastBytes >= 0 ? Date().timeIntervalSince(bytesAt) : nil
        if StallPolicy.shouldReload(stalled: stalled, quiet: quiet, justReturned: justBack) {
            if recoveryAttempts < 3 {
                recoverSource(reason: "stall", keepPaused: false)
            } else if stalled > 45, errorMessage == nil {
                // جرّبنا إعادة التحميل وما نفع: نوضّح للمستخدم بدل ما تبقى الصورة واقفة بلا نهاية
                fail(L("انقطع الاتصال بالمصدر. اضغط تشغيل عشان نكمّل من نفس المكان"))
            }
        }
    }

    /// البيانات اللي توصل من الشبكة (لو المشغّل يعطيها)
    private func watchNetwork(_ engine: any PlaybackEngine) {
        guard let bytes = engine.bytesReceived else { return }
        if bytes != lastBytes {
            lastBytes = bytes
            bytesAt = Date()
        }
    }

    /// الصورة واقفة والوقت ماشي: الترجمة توقف عند آخر إطار، وبعدها نستعيد من آخر إطار انعرض، مو من الصفر
    private func watchFrames(_ engine: any PlaybackEngine, now: TimeInterval) {
        guard let frames = engine.framesShown else { return }
        let playing = engine.state == .playing && !engine.isBuffering && pendingRestore == nil && !isReloading
        let verdict = frameWatch.observe(frames: frames, time: engine.elapsed, playing: playing, now: now)
        if Date().timeIntervalSince(frameRecoveredAt) > 60 { frameRecoveries = 0 }
        guard verdict == .frozen, Date().timeIntervalSince(frameRecoveredAt) > PictureRecovery.backoff(attempt: frameRecoveries + 1) else { return }
        frameRecoveredAt = Date()
        frameRecoveries += 1
        let at = frameWatch.frameTime > 1 ? frameWatch.frameTime : max(resumePoint, 0)
        coreLog.info("player picture frozen at \(at) (time \(engine.elapsed)), recovery \(self.frameRecoveries)")
        frameWatch.reset()
        // الأخف أول: نرجّع مخرج الصورة على نفس الاتصال ونفس الثانية (بدون ما نعيد الترجمة ولا نلمس المكان).
        // إعادة المصدر كامل آخر حل، وبعدها رسالة — بدل ما نبدّل بينهم من أول مرة.
        switch PictureRecovery.step(attempt: frameRecoveries) {
        case .restartOutput:
            engine.recoverPicture(at: at)
            elapsed = at
        case .reopen:
            resume.userSeek(to: at, now: now)
            recoveryAttempts = 0
            recoverSource(reason: "frozen picture", keepPaused: false)
        case .giveUp:
            resume.userSeek(to: at, now: now)
            if errorMessage == nil {
                fail(L("انقطع الاتصال بالمصدر. اضغط تشغيل عشان نكمّل من نفس المكان"))
            }
        }
    }

    static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var lastForeground: Date?

    private func engineStateChanged(_ s: PlaybackState) {
        state = s
        switch s {
        case .playing:
            settleEngine()
            if !reportedOk { reportFirstPlay() }
            if pendingRestore != nil { applyPendingRestore() } else { isReloading = false }
        case .paused:
            settleEngine()
            saveProgress(force: true)
            if pendingRestore != nil { finishRestoreIfDone() }
        case .ended:
            // VLC مع بث من النت يقول "خلص" لما تنقطع الشبكة وهو بالنص. كان هذا يمسح مكان المشاهدة،
            // وزر التشغيل بعدها يعيد الفيلم من البداية. نفرّق: نهاية فعلية، ولا انقطاع نستعيده من نفس المكان
            let total = duration ?? lastKnownDuration ?? Self.runtimeSeconds(context?.meta?.runtime) ?? 0
            if !isLive, !PlaybackEnd.isReal(position: resumePoint, duration: total) {
                earlyEnds += 1
                coreLog.info("player ended early at \(self.resumePoint) of \(total), recovering")
                saveProgress(force: true)
                if earlyEnds <= 4 {
                    recoveryAttempts = min(recoveryAttempts, 1)
                    recoverSource(reason: "early end", keepPaused: false)
                } else {
                    fail(L("انقطع الاتصال بالمصدر. اضغط تشغيل عشان نكمّل من نفس المكان"))
                }
                return
            }
            finished()
        default:
            break
        }
    }

    private func settleEngine() {
        guard let engine else { return }
        if settledEngineName != engine.kindName { settledEngineName = engine.kindName }
        if settledSupportsPiP != engine.supportsPiP { settledSupportsPiP = engine.supportsPiP }
        if settledSupportsAirPlay != engine.supportsAirPlay { settledSupportsAirPlay = engine.supportsAirPlay }
    }

    /// أول ما يشتغل: نحفظ إن المصدر شغال بهالمشغّل، ونضيفه للسجل
    private func reportFirstPlay() {
        reportedOk = true
        showTryAnother = false
        guard let source, let context, let core else { return }
        let engine: Engine = engineName == "VLC" ? .vlc : .native
        try? core.markSourceOk(sourceId: source.id, engine: engine)
        try? core.addHistory(entry: HistoryEntry(mediaId: context.ref.id, title: context.title, poster: context.meta?.poster ?? context.ref.poster,
                                                 kind: context.ref.kind, sourceId: source.id, engine: engine, watchedAt: CoreClient.now))
        app?.libraryVersion += 1
    }

    // MARK: - التقدّم

    private var lastKnownDuration: Double?
    private var wasPlayingAtSync = false

    /// "2h 9min" أو "129 min" أو "2:09" → ثواني
    static func runtimeSeconds(_ raw: String?) -> Double? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        var h = 0.0, m = 0.0
        if let r = raw.range(of: #"(\d+)\s*h"#, options: .regularExpression) {
            h = Double(raw[r].filter(\.isNumber)) ?? 0
        }
        if let r = raw.range(of: #"(\d+)\s*m"#, options: .regularExpression) {
            m = Double(raw[r].filter(\.isNumber)) ?? 0
        }
        if h == 0, m == 0, let n = Double(raw.filter(\.isNumber)), !raw.contains(":") { m = n }
        let total = (h * 60 + m) * 60
        return total >= 600 ? total : nil
    }

    private func saveProgress(force: Bool) {
        guard let context, let core, reportedOk || force else { return }
        guard force || Date().timeIntervalSince(lastSave) >= 10 else { return }
        let position = resumePoint
        guard position > 10 else { return }
        lastSave = Date()
        if let d = duration, d > 0, position / d > 0.95 {
            try? core.removeProgress(mediaId: context.ref.id)
            return
        }
        // المدة: من المشغّل، وإلا آخر مدة عرفناها لنفس العمل، وإلا مدة العمل من بياناته (عشان "باقي X د" تطلع لـ VLC بعد)
        let knownDuration = duration.flatMap { $0 > 0 ? $0 : nil }
            ?? lastKnownDuration
            ?? Self.runtimeSeconds(context.meta?.runtime)
        if let knownDuration { lastKnownDuration = knownDuration }
        let p = WatchProgress(mediaId: context.ref.id, episodeId: context.video?.id, kind: context.ref.kind, title: context.title,
                              poster: context.meta?.poster ?? context.ref.poster, positionS: position, durationS: knownDuration, updatedAt: CoreClient.now)
        try? core.saveProgress(progress: p)
        if force { app?.refreshContinueWatching() }
    }

    // MARK: - النهاية والحلقة الجاية

    private func finished() {
        if let context { try? core?.removeProgress(mediaId: context.ref.id) }
        app?.refreshContinueWatching()
        guard let context, let meta = context.meta, let current = context.video,
              let next = core?.nextEpisode(meta: meta, currentId: current.id) else { return }
        nextUp = next
        guard app?.autoNext ?? true else { return }
        nextTask?.cancel()
        nextTask = Task { [weak self] in
            for s in stride(from: 5, through: 1, by: -1) {
                self?.nextCountdown = s
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.nextCountdown = nil
            self?.playNext()
        }
    }

    /// ما تبي الحلقة الجاية تشتغل تلقائي
    func cancelNext() {
        nextTask?.cancel()
        nextCountdown = nil
    }

    /// يجيب مصادر الحلقة الجاية ويشغّل أفضل مصدر شغّال
    func playNext() {
        guard let context, let next = nextUp ?? context.meta.flatMap({ m in context.video.flatMap { core?.nextEpisode(meta: m, currentId: $0.id) } }) else { return }
        nextTask?.cancel()
        nextCountdown = nil
        playEpisode(next)
    }

    /// يشغّل حلقة من نفس المسلسل (يجيب مصادرها أول)
    func playEpisode(_ video: Video) {
        guard let context, let core else { return }
        saveProgress(force: true)
        stopEngine()
        nextUp = nil
        elapsed = 0
        resume.reset(to: 0)
        earlyEnds = 0
        duration = nil
        isLive = false
        videoSize = .zero
        reportedOk = false
        triedSources = []
        state = .loading
        isBuffering = true
        errorMessage = nil
        loadingSince = Date()
        let newContext = PlayContext(ref: context.ref, meta: context.meta, video: video, sources: [])
        self.context = newContext
        externalSubtitles = []
        selectedExternal = nil
        cues = []
        cueText = nil
        autoSourceTask?.cancel()
        autoSourceTask = Task { [weak self] in
            var latest: [RankedSource] = []
            let started = Date()
            for await event in CoreClient.sources(core, kind: .series, id: video.id) {
                if Task.isCancelled { return }
                switch event {
                case let .sources(list): latest = list
                case let .health(id, h):
                    if let i = latest.firstIndex(where: { $0.id == id }) { latest[i].health = h }
                case .finished: break
                }
                // أول مصدر شغّال بالترتيب يكفي، أو بعد 12 ثانية أي شي موجود
                if latest.first(where: \.isAlive) != nil || Date().timeIntervalSince(started) > 12 { break }
            }
            guard let self, !Task.isCancelled else { return }
            let direct = latest.filter { if case .direct = $0.target { true } else { false } }
            guard let pick = direct.first(where: \.isAlive) ?? direct.first(where: { !$0.isUnreachable }) else {
                self.fail(L("ما لقينا مصادر لهذي الحلقة"))
                return
            }
            var ctx = newContext
            ctx.sources = latest
            self.play(pick, context: ctx, startAt: nil, freshTitle: true)
        }
    }

    // MARK: - المسارات

    private func readTracks() {
        guard let engine else { return }
        var audio = engine.audioTracks
        var subs = engine.embeddedSubtitles
        var embedded = engine.selectedEmbeddedSubtitle
        if let info = remuxInfo, engine is NativeEngine {
            // the remuxed file's other tracks: PGS drawn here, the rest a tap away in VLC (same second)
            let locale = L10n.language.locale
            func label(_ name: String, _ lang: String, _ n: Int) -> String {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                let language = lang.isEmpty || lang == "und" ? "" : LanguageNames.displayName(lang, locale: locale)
                if !trimmed.isEmpty, !language.isEmpty, !trimmed.localizedCaseInsensitiveContains(language) { return "\(language) · \(trimmed)" }
                if !trimmed.isEmpty { return trimmed }
                return language.isEmpty ? L("مسار") + " \(n + 1)" : language
            }
            for t in info.pgs {
                let forced = t.forced ? " · " + L("إجبارية") : ""
                subs.append(TrackOption(id: "pgs:\(t.index)", name: label(t.name, t.language, Int(t.ordinal)) + forced,
                                        language: t.language, detail: L("داخل الملف") + " · PGS"))
            }
            if let selectedPGS { embedded = "pgs:\(selectedPGS)" }
            for t in info.vlcOnly {
                let option = TrackOption(id: "vlc-\(t.kind):\(t.ordinal)", name: label(t.name, t.language, Int(t.ordinal)),
                                         language: t.language, detail: t.codec + " · " + L("يشتغل بـ VLC"))
                if t.kind == "audio" { audio.append(option) } else { subs.append(option) }
            }
        }
        audioTracks = audio
        selectedAudio = engine.selectedAudio
        embeddedSubtitles = subs
        selectedEmbedded = embedded
        if pendingRestore == nil { autoSelectPGS() }
        if pendingRestore != nil { applyPendingRestore() }
    }

    func selectAudio(_ id: String) {
        if id.hasPrefix("vlc-audio:"), let n = Int(id.dropFirst("vlc-audio:".count)) {
            reopenInVLC(audio: n, subtitle: nil)
            return
        }
        engine?.selectAudio(id)
        readTracks()
    }

    func selectEmbedded(_ id: String?) {
        subtitleChosenByUser = true
        if let id, id.hasPrefix("vlc-subtitle:"), let n = Int(id.dropFirst("vlc-subtitle:".count)) {
            reopenInVLC(audio: nil, subtitle: n)
            return
        }
        if id != nil { clearExternal() }
        if let id, id.hasPrefix("pgs:"), let n = Int(id.dropFirst("pgs:".count)) {
            (engine as? NativeEngine)?.deselectLegible()
            selectPGS(n)
            readTracks()
            return
        }
        if selectedPGS != nil { selectPGS(nil) }
        engine?.selectEmbeddedSubtitle(id)
        readTracks()
    }

    /// يطفي كل الترجمات
    func subtitlesOff() {
        subtitleChosenByUser = true
        clearExternal()
        if selectedPGS != nil { selectPGS(nil) }
        engine?.selectEmbeddedSubtitle(nil)
        readTracks()
    }

    /// PGS in the file and nothing else showing: the forced track (foreign dialogue) always, or the
    /// track in the user's subtitle language when no other subtitle in that language exists
    private func autoSelectPGS() {
        guard let info = remuxInfo, !info.pgs.isEmpty, selectedPGS == nil, !subtitleChosenByUser,
              selectedExternal == nil, selectedEmbedded == nil, engine is NativeEngine else { return }
        let lang = app?.subtitleLang ?? "off"
        var pick: RemuxPgsTrack?
        if lang != "off" {
            let hasText = externalSubtitles.contains { LanguageNames.matches($0.lang, lang) }
                || embeddedSubtitles.contains { !$0.id.hasPrefix("pgs:") && !$0.id.hasPrefix("vlc-") && LanguageNames.matches($0.language ?? "", lang) }
            if !hasText { pick = info.pgs.first { !$0.forced && LanguageNames.matches($0.language, lang) } }
        }
        if pick == nil {
            let audioLang = audioTracks.first { $0.id == selectedAudio }?.language ?? ""
            pick = info.pgs.first { $0.forced && (audioLang.isEmpty || LanguageNames.matches($0.language, audioLang)) }
                ?? info.pgs.first { $0.forced && $0.isDefault }
        }
        guard let pick else { return }
        (engine as? NativeEngine)?.deselectLegible()
        selectPGS(Int(pick.index))
        selectedEmbedded = "pgs:\(pick.index)"
    }

    private func clearExternal() {
        subtitleTask?.cancel()
        selectedExternal = nil
        cues = []
        cueText = nil
        loadingSubtitle = false
    }

    // MARK: - الترجمات الخارجية

    private func mergeSourceSubtitles(_ source: RankedSource) {
        var seen = Set(externalSubtitles.map(\.url))
        for t in source.subtitles where !seen.contains(t.url) {
            externalSubtitles.append(t)
            seen.insert(t.url)
        }
    }

    private func loadExternalSubtitles(context: PlayContext, source: RankedSource) {
        mergeSourceSubtitles(source)
        guard let core else { return }
        let kind = context.ref.kind
        let id = context.streamId
        Task { [weak self] in
            let fromAddons = await core.subtitles(kind: kind, id: id)
            guard let self, self.context?.streamId == id else { return }
            var seen = Set(self.externalSubtitles.map(\.url))
            for t in fromAddons where !seen.contains(t.url) {
                self.externalSubtitles.append(t)
                seen.insert(t.url)
            }
            self.autoSelectSubtitle()
        }
        autoSelectSubtitle()
    }

    /// يختار ترجمة باللغة المفضلة لو ما فيه وحدة مختارة
    private func autoSelectSubtitle() {
        guard selectedExternal == nil, selectedEmbedded == nil, let lang = app?.subtitleLang, lang != "off" else { return }
        if let track = externalSubtitles.first(where: { LanguageNames.matches($0.lang, lang) }) {
            selectExternal(track)
        }
    }

    func selectExternal(_ track: SubtitleTrack) {
        guard let core else { return }
        if selectedPGS != nil { selectPGS(nil) }
        engine?.selectEmbeddedSubtitle(nil)
        selectedExternal = track.id
        cues = []
        cueText = nil
        loadingSubtitle = true
        subtitleTask?.cancel()
        subtitleTask = Task { [weak self] in
            do {
                let parsed = try await core.parseSubtitle(url: track.url)
                guard let self, !Task.isCancelled, self.selectedExternal == track.id else { return }
                self.cues = parsed
                self.loadingSubtitle = false
                self.updateCue()
                if parsed.isEmpty { self.app?.showToast(L("ملف الترجمة فاضي")) }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.loadingSubtitle = false
                self.selectedExternal = nil
                self.app?.showToast(L("تعذّر تحميل الترجمة"))
            }
        }
        readTracks()
    }

    /// تقديم أو تأخير الترجمة (بالثواني)
    func shiftSubtitles(by delta: Double) {
        subtitleOffset = (subtitleOffset + delta).rounded(toPlaces: 2)
        updateCue()
    }

    func resetSubtitleOffset() {
        subtitleOffset = 0
        updateCue()
    }

    /// Subtitles follow the player's live clock (not the last 250 ms poll), with the user's sync offset kept
    private func updateCue() {
        var now = engine?.liveTime ?? elapsed
        // مشغّل جديد لسا يحمّل يبلّغ صفر: الترجمة تبقى على المكان المحفوظ، ما تقفز لأول جملة بالفيلم
        if isReloading || pendingRestore != nil || abs(now - elapsed) > 6 { now = elapsed }
        // الترجمة تتبع الصورة: لو الإطارات وقفت، توقف عند وقت آخر إطار انعرض
        if frameWatch.everFrames, frameWatch.lagging, engine?.state == .playing, now - frameWatch.frameTime > FrameWatch.lagAfter {
            now = frameWatch.frameTime
        }
        let text = CueIndex.text(in: cues, at: now.isFinite ? now : elapsed, offset: subtitleOffset)
        if text != cueText { cueText = text }
    }

    // MARK: - مشابه

    private func loadSimilar(context: PlayContext) {
        guard let core else { return }
        let kind = context.ref.kind, id = context.ref.id
        Task { [weak self] in
            let items = (try? await core.similar(kind: kind, id: id)) ?? []
            guard let self, self.context?.ref.id == id else { return }
            self.similar = items
        }
    }

    /// يفتح عمل مشابه: المشغّل يصغر ويكمل، وصفحة العمل تنفتح
    func openSimilar(_ item: MetaPreview) {
        minimize()
        app?.open(MediaRef(item))
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
