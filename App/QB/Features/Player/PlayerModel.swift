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
    private(set) var duration: Double?
    private(set) var isBuffering = false
    /// بث مباشر فعلًا (حسب المشغّل)، مو بس مدة ما وصلت
    private(set) var isLive = false
    private(set) var videoSize: CGSize = .zero
    /// آخر مصدر دوّرنا الشاشة له تلقائيًا، عشان ما نعاند المستخدم لو رجّعها عمودي
    private var autoRotatedFor: String?
    private(set) var engineName = ""
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
        lastKnownDuration = ((try? core?.progress(mediaId: context.ref.id)) ?? nil)?.durationS
        failureLog = []
        failureDetail = nil
        // كل مرة تفتح الفيلم يدوّر للأفقي من جديد (قبل كان يتذكر إنه دوّر لنفس المصدر فما يدوّر ثاني مرة)
        autoRotatedFor = nil
        let changedTitle = freshTitle || self.context?.streamId != context.streamId
        self.context = context
        if changedTitle {
            videoFill = false
            externalSubtitles = []
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

    private func start(_ source: RankedSource, startAt: Double, forceVLC: Bool) {
        stopEngine()
        self.source = source
        triedSources.insert(source.id)
        errorMessage = nil
        failureDetail = nil
        showTryAnother = false
        reportedOk = false
        loadingSince = Date()
        elapsed = startAt
        duration = nil
        isLive = false
        videoSize = .zero
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
            let useVLC = forceVLC || source.engine == .vlc || app?.preferredEngine == "vlc"
            let engine: any PlaybackEngine = useVLC ? VLCEngine() : makeNative()
            wire(engine)
            self.engine = engine
            engineName = engine.kindName
            applyZoom()
            state = .loading
            isBuffering = true
            engine.setRate(rate)
            startTicking()
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
        let position = elapsed
        noteFailure(failure, source: source, position: position)
        switch failure {
        case .nativeCannotPlay:
            // الأصلي ما قدر: نحفظ إن هذا المصدر يحتاج VLC ونحوّل من نفس الثانية
            try? core?.markSourceFailed(sourceId: source.id, nativeFailed: true)
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
        start(next, startAt: elapsed, forceVLC: false)
    }

    /// اختيار مصدر من داخل المشغّل
    func switchSource(_ s: RankedSource) {
        guard s.id != source?.id else { return }
        mergeSourceSubtitles(s)
        start(s, startAt: elapsed, forceVLC: false)
    }

    func retry() {
        guard let source else { return }
        triedSources.remove(source.id)
        start(source, startAt: elapsed, forceVLC: source.engine == .vlc || engineName == "VLC")
    }

    /// يجبر VLC للمصدر الحالي (من قائمة المشغّل)
    func reopenInVLC() {
        guard let source, engineName != "VLC" else { return }
        try? core?.markSourceFailed(sourceId: source.id, nativeFailed: true)
        start(source, startAt: elapsed, forceVLC: true)
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
        elapsed = t
        updateCue()
    }

    func skip(_ delta: Double) {
        seek(to: elapsed + delta)
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
        videoFill = false
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
        engine?.setVideoFill(videoFill && coverOnScreen, viewport: zoomViewport)
    }

    func didDismiss() {
        coverOnScreen = false
        applyZoom()
        OrientationLock.lockPortrait()
        if case .failed = state { close() }
        if engine == nil, context != nil, state == .idle { close() }
    }

    private func stopEngine() {
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

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard engine != nil else { return }
        switch phase {
        case .background:
            saveProgress(force: true)
            // VLC ما يدعم صورة داخل صورة، نوقفه بدل ما يرسم بالخلفية
            if engineName == "VLC" { pause() }
        case .active:
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
            while !Task.isCancelled {
                self?.sync()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func sync() {
        guard let engine else { return }
        if elapsed != engine.elapsed { elapsed = engine.elapsed }
        if duration != engine.duration { duration = engine.duration }
        if isLive != engine.isLive { isLive = engine.isLive }
        if videoSize != engine.videoSize { videoSize = engine.videoSize }
        if isBuffering != engine.isBuffering { isBuffering = engine.isBuffering }
        if state != engine.state, engine.state != .idle { state = engine.state }
        updateCue()
        let waiting = state == .loading || (isBuffering && !reportedOk)
        let shouldOffer = waiting && Date().timeIntervalSince(loadingSince) > 5
        if showTryAnother != shouldOffer { showTryAnother = shouldOffer }
        if isPlaying { saveProgress(force: false) }
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

    private func engineStateChanged(_ s: PlaybackState) {
        state = s
        switch s {
        case .playing:
            if !reportedOk { reportFirstPlay() }
        case .paused:
            saveProgress(force: true)
        case .ended:
            finished()
        default:
            break
        }
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
        guard elapsed > 10 else { return }
        lastSave = Date()
        if let d = duration, d > 0, elapsed / d > 0.95 {
            try? core.removeProgress(mediaId: context.ref.id)
            return
        }
        // المدة: من المشغّل، وإلا آخر مدة عرفناها لنفس العمل، وإلا مدة العمل من بياناته (عشان "باقي X د" تطلع لـ VLC بعد)
        let knownDuration = duration.flatMap { $0 > 0 ? $0 : nil }
            ?? lastKnownDuration
            ?? Self.runtimeSeconds(context.meta?.runtime)
        if let knownDuration { lastKnownDuration = knownDuration }
        let p = WatchProgress(mediaId: context.ref.id, episodeId: context.video?.id, kind: context.ref.kind, title: context.title,
                              poster: context.meta?.poster ?? context.ref.poster, positionS: elapsed, durationS: knownDuration, updatedAt: CoreClient.now)
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
        audioTracks = engine.audioTracks
        selectedAudio = engine.selectedAudio
        embeddedSubtitles = engine.embeddedSubtitles
        selectedEmbedded = engine.selectedEmbeddedSubtitle
    }

    func selectAudio(_ id: String) {
        engine?.selectAudio(id)
        readTracks()
    }

    func selectEmbedded(_ id: String?) {
        if id != nil { clearExternal() }
        engine?.selectEmbeddedSubtitle(id)
        readTracks()
    }

    /// يطفي كل الترجمات
    func subtitlesOff() {
        clearExternal()
        engine?.selectEmbeddedSubtitle(nil)
        readTracks()
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

    private func updateCue() {
        let text = CueIndex.text(in: cues, at: elapsed, offset: subtitleOffset)
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
