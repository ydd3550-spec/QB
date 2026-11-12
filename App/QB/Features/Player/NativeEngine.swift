import AVFoundation
import AVKit
import UIKit

/// منظر طبقته AVPlayerLayer
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// ترجمة صورية (PGS) فوق الفيديو: صورتها ومكانها على لوحة الترجمة (= إطار الفيديو)
    private let imageSubLayer = CALayer()
    private var imageSub: (canvas: CGSize, rect: CGRect)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageSubLayer.contentsGravity = .resize
        imageSubLayer.isHidden = true
        imageSubLayer.zPosition = 10
        imageSubLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer.addSublayer(imageSubLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // الطبقة هي طبقة المنظر نفسه، بس نتأكد إن ما فيه حركة ناقصة بعد التدوير أو القفل
        playerLayer.removeAllAnimations()
        placeImageSubtitle(animated: false)
    }

    func setImageSubtitle(_ image: CGImage?, canvas: CGSize, rect: CGRect) {
        guard let image, canvas.width > 0, canvas.height > 0 else {
            imageSub = nil
            imageSubLayer.contents = nil
            imageSubLayer.isHidden = true
            return
        }
        imageSub = (canvas, rect)
        imageSubLayer.contents = image
        placeImageSubtitle(animated: false)
        imageSubLayer.isHidden = false
    }

    /// اللوحة تنطبق على مكان الفيديو الفعلي، وبالتكبير (ملء الشاشة) الترجمة تنسحب لداخل الشاشة
    /// عشان ما تنقص من تحت أو من الجوانب
    func placeImageSubtitle(animated: Bool) {
        guard let s = imageSub else { return }
        var video = playerLayer.videoRect
        if video.isEmpty || !video.width.isFinite { video = bounds }
        guard video.width > 0, video.height > 0 else { return }
        let sx = video.width / s.canvas.width
        let sy = video.height / s.canvas.height
        var r = CGRect(x: video.minX + s.rect.minX * sx, y: video.minY + s.rect.minY * sy,
                       width: s.rect.width * sx, height: s.rect.height * sy)
        let visible = bounds.insetBy(dx: 6, dy: 6)
        if visible.width > 0, r.width > visible.width {
            let k = visible.width / r.width
            r.size = CGSize(width: r.width * k, height: r.height * k)
        }
        if visible.height > 0, r.height > visible.height {
            let k = visible.height / r.height
            r.size = CGSize(width: r.width * k, height: r.height * k)
        }
        r.origin.x = min(max(r.minX, visible.minX), visible.maxX - r.width)
        r.origin.y = min(max(r.minY, visible.minY), visible.maxY - r.height)
        CATransaction.begin()
        if animated {
            imageSubLayer.removeAnimation(forKey: "place")
            let from = imageSubLayer.presentation()?.frame ?? imageSubLayer.frame
            imageSubLayer.frame = r
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: CGPoint(x: from.midX, y: from.midY))
            move.duration = 0.25
            let size = CABasicAnimation(keyPath: "bounds.size")
            size.fromValue = NSValue(cgSize: from.size)
            size.duration = 0.25
            let group = CAAnimationGroup()
            group.animations = [move, size]
            group.duration = 0.25
            imageSubLayer.add(group, forKey: "place")
        } else {
            CATransaction.setDisableActions(true)
            imageSubLayer.frame = r
        }
        CATransaction.commit()
    }
}

/// المشغّل الأصلي: MP4 وHLS وكل شي يقدر عليه AVPlayer.
/// بعد الجاهزية نراقب 6 ثواني: لو علق والوقت ما يتحرك، أو ما طلعت صورة، أو فشل الملف
/// يرجّع nativeCannotPlay وPlayerModel يحوّل لـ VLC بنفس الثانية.
final class NativeEngine: NSObject, PlaybackEngine {
    let kindName = "AVPlayer"
    private let view = PlayerLayerView()
    var surface: UIView { view }

    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var pip: AVPictureInPictureController?
    private var tick: Task<Void, Never>?

    private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var elapsed: Double = 0
    private(set) var duration: Double?
    private(set) var isBuffering = false
    /// مدة العنصر "غير محدودة" بعد ما اشتغل فعلًا = بث مباشر
    var isLive: Bool { everPlayed && player.currentItem?.duration.isIndefinite == true }
    var videoSize: CGSize { player.currentItem?.presentationSize ?? .zero }
    var supportsPiP: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    let supportsAirPlay = true

    var onStateChange: ((PlaybackState) -> Void)?
    var onFailure: ((EngineFailure) -> Void)?
    var onTracksChanged: (() -> Void)?
    var onPiPRestore: (() -> Void)?
    var onPiPActive: ((Bool) -> Void)?

    private var wantsPlay = true
    private var rate: Float = 1
    private var readyAt: Date?
    private var loadStarted = Date()
    private var lastProgressTime: Double = -1
    private var lastProgressAt = Date()
    private var everPlayed = false
    private var failed = false
    private var tracksLoaded = false
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var startAt: Double = 0
    private var didInitialSeek = false
    /// وقت التقديم لمكان الاستكمال: المراقب ينتظر لين يخلص (التقديم بملف كبير على النت يطول)
    private var seekingToStart = false

    override init() {
        super.init()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
            controller?.delegate = self
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            pip = controller
        }
        // Back from background / screen lock: make sure the layer is attached to the player and rendering
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                AudioSessionKeeper.shared.activate()
                // Only if it really got detached; a layer that is just warming up is left alone (the watchdog covers it)
                if self.view.playerLayer.player !== self.player { self.reattachLayer() }
                self.refreshLayout()
            }
        }
    }

    private var foregroundObserver: NSObjectProtocol?
    private var notReadySince: Date?
    private var lastReattach = Date.distantPast

    /// Detach and re-attach the layer so the picture comes back if it got disconnected (not while in PiP)
    private func reattachLayer() {
        guard pip?.isPictureInPictureActive != true else { return }
        lastReattach = Date()
        let gravity = view.playerLayer.videoGravity
        view.playerLayer.player = nil
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity == .resize ? .resizeAspect : gravity
    }

    func load(url: URL, headers: [String: String], startAt: Double) {
        failed = false
        everPlayed = false
        readyAt = nil
        loadStarted = Date()
        tracksLoaded = false
        didInitialSeek = false
        self.startAt = startAt
        var options: [String: Any] = [:]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        self.item = item
        player.replaceCurrentItem(with: item)
        state = .loading
        isBuffering = true
        wantsPlay = true
        player.playImmediately(atRate: rate)
        startTicking()
    }

    private func startTicking() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// قراءة الحالة 4 مرات بالثانية بدل KVO (أبسط وآمن مع Swift 6)
    private func poll() {
        guard let item, !failed else { return }
        switch item.status {
        case .failed:
            let e = item.error as NSError?
            let log = item.errorLog()?.events.last
            var reason = e.map { "\($0.localizedDescription) [\($0.domain) \($0.code)]" } ?? "failed"
            if let log, log.errorStatusCode != 0 { reason += " · log \(log.errorStatusCode) \(log.errorComment ?? "")" }
            fail(reason)
            return
        case .readyToPlay:
            if readyAt == nil {
                readyAt = Date()
                lastProgressAt = Date()
                if startAt > 1, !didInitialSeek {
                    didInitialSeek = true
                    seekingToStart = true
                    player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                                toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                                toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            // نبدأ عد المراقب من بعد ما يوصل لمكان الاستكمال
                            self.seekingToStart = false
                            self.readyAt = Date()
                            self.lastProgressAt = Date()
                            if self.wantsPlay { self.player.playImmediately(atRate: self.rate) }
                        }
                    }
                }
                loadTracks()
            }
        default:
            // ما صار جاهز خلال 15 ثانية: غالبًا صيغة ما يفهمها
            if Date().timeIntervalSince(loadStarted) > 15 {
                fail("not ready")
                return
            }
        }

        let t = item.currentTime().seconds
        if t.isFinite { elapsed = max(0, t) }
        duration = Self.duration(of: item)

        if t.isFinite, abs(t - lastProgressTime) > 0.05 {
            lastProgressTime = t
            lastProgressAt = Date()
            if player.timeControlStatus == .playing { everPlayed = true }
        }

        // Watchdog: time advances and the video has a picture, but the layer shows nothing for ~2s: re-attach it
        if everPlayed, player.timeControlStatus == .playing, videoSize != .zero,
           !view.playerLayer.isReadyForDisplay, pip?.isPictureInPictureActive != true {
            if notReadySince == nil { notReadySince = Date() }
            if let since = notReadySince, Date().timeIntervalSince(since) > 2, Date().timeIntervalSince(lastReattach) > 4 {
                reattachLayer()
                notReadySince = nil
            }
        } else {
            notReadySince = nil
        }

        if let end = duration, end > 0, t.isFinite, t >= end - 0.3, player.timeControlStatus != .playing, readyAt != nil, everPlayed {
            state = .ended
            isBuffering = false
            return
        }

        switch player.timeControlStatus {
        case .playing:
            isBuffering = false
            state = .playing
        case .paused:
            isBuffering = false
            if readyAt != nil { state = .paused }
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
            state = readyAt == nil ? .loading : .stalled
        @unknown default:
            break
        }

        watchdog(item)
    }

    /// بعد readyToPlay نراقب 6 ثواني أول مرة، وبعدها أي علق طويل قبل أول تشغيل
    private func watchdog(_ item: AVPlayerItem) {
        guard let readyAt, wantsPlay, !seekingToStart else { return }
        let sinceReady = Date().timeIntervalSince(readyAt)
        // الاستكمال من نص الملف يحتاج وقت أطول يعبّي فيه
        let grace: Double = startAt > 1 ? 12 : 6
        if sinceReady >= grace, !everPlayed {
            let stuck = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && Date().timeIntervalSince(lastProgressAt) >= grace
            let noPicture = item.presentationSize == .zero && hasVideoTrackUnknown(item)
            if stuck || noPicture {
                fail(stuck ? "stalled" : "no picture")
                return
            }
        }
        if let log = item.errorLog(), let last = log.events.last, last.errorStatusCode == -12927 || last.errorStatusCode == -11828 {
            fail("error log \(last.errorStatusCode)")
        }
    }

    /// لو الملف فيه مسار فيديو بس الصورة ما طلعت، أو ما نعرف المسارات (ملف ما انقرا)
    private func hasVideoTrackUnknown(_ item: AVPlayerItem) -> Bool {
        let tracks = item.tracks
        if tracks.isEmpty { return true }
        return tracks.contains { $0.assetTrack?.mediaType == .video }
    }

    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        isBuffering = false
        tick?.cancel()
        player.pause()
        onFailure?(.nativeCannotPlay(reason))
    }

    static func duration(of item: AVPlayerItem) -> Double? {
        let d = item.duration.seconds
        if d.isFinite, d > 0 { return d }
        if let last = item.seekableTimeRanges.last?.timeRangeValue {
            let end = CMTimeRangeGetEnd(last).seconds
            // بث مباشر نافذته قصيرة: ما نعتبره مدة
            if end.isFinite, end > 60 { return end }
        }
        return nil
    }

    /// للترجمة: وقت AVPlayer الحي مباشرة
    var liveTime: Double {
        if seekingToStart { return elapsed }
        let t = player.currentTime().seconds
        return t.isFinite && t >= 0 ? t : elapsed
    }

    func refreshLayout() {
        // الحجم الأصلي أو التكبير: الاثنين يحافظون على النسبة (resizeAspect / resizeAspectFill)، ما نستخدم resize أبد
        if view.playerLayer.videoGravity == .resize { view.playerLayer.videoGravity = .resizeAspect }
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func play() {
        wantsPlay = true
        AudioSessionKeeper.shared.activate()
        if state == .ended { seek(to: 0) }
        player.playImmediately(atRate: rate)
        if readyAt != nil { state = .playing }
    }

    func pause() {
        wantsPlay = false
        player.pause()
        if readyAt != nil { state = .paused }
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        elapsed = target
        lastProgressAt = Date()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
        if state == .ended, wantsPlay { player.playImmediately(atRate: rate) }
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if wantsPlay { player.rate = rate }
    }

    func shutdown() {
        tick?.cancel()
        tick = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        pip?.delegate = nil
        pip = nil
        item = nil
        state = .idle
    }

    // MARK: - المسارات

    private func loadTracks() {
        guard !tracksLoaded, let asset = item?.asset else { return }
        tracksLoaded = true
        Task { [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self else { return }
            self.audioGroup = audio
            self.legibleGroup = legible
            self.onTracksChanged?()
        }
    }

    private func option(_ o: AVMediaSelectionOption, index: Int) -> TrackOption {
        TrackOption(id: "\(index)", name: o.displayName(with: L10n.language.locale), language: o.extendedLanguageTag ?? o.locale?.language.languageCode?.identifier)
    }

    var audioTracks: [TrackOption] {
        guard let g = audioGroup, g.options.count > 1 else { return [] }
        return g.options.enumerated().map { option($1, index: $0) }
    }

    var selectedAudio: String? {
        guard let g = audioGroup, let sel = item?.currentMediaSelection.selectedMediaOption(in: g) else { return nil }
        return g.options.firstIndex(of: sel).map { "\($0)" }
    }

    func selectAudio(_ id: String) {
        guard let g = audioGroup, let i = Int(id), g.options.indices.contains(i) else { return }
        item?.select(g.options[i], in: g)
        onTracksChanged?()
    }

    var embeddedSubtitles: [TrackOption] {
        guard let g = legibleGroup else { return [] }
        return g.options.enumerated().compactMap { i, o in
            o.hasMediaCharacteristic(.containsOnlyForcedSubtitles) ? nil : option(o, index: i)
        }
    }

    var selectedEmbeddedSubtitle: String? {
        guard let g = legibleGroup, let sel = item?.currentMediaSelection.selectedMediaOption(in: g) else { return nil }
        return g.options.firstIndex(of: sel).map { "\($0)" }
    }

    func selectEmbeddedSubtitle(_ id: String?) {
        guard let g = legibleGroup else { return }
        if let id, let i = Int(id), g.options.indices.contains(i) {
            item?.select(g.options[i], in: g)
        } else {
            item?.select(nil, in: g)
        }
        onTracksChanged?()
    }

    // MARK: - صورة داخل صورة

    func startPiP() {
        guard let pip, pip.isPictureInPicturePossible else { return }
        pip.startPictureInPicture()
    }

    func stopPiP() {
        guard let pip, pip.isPictureInPictureActive else { return }
        pip.stopPictureInPicture()
    }

    /// ملء الشاشة = resizeAspectFill، الحجم الأصلي = resizeAspect
    func setVideoFill(_ fill: Bool, viewport: CGSize) {
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        guard view.playerLayer.videoGravity != gravity else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        view.playerLayer.videoGravity = gravity
        CATransaction.commit()
        view.placeImageSubtitle(animated: true)
    }

    /// PGS subtitle bitmap over the video (nil hides it)
    func setImageSubtitle(_ image: CGImage?, canvas: CGSize, rect: CGRect) {
        view.setImageSubtitle(image, canvas: canvas, rect: rect)
    }

    /// AVPlayer's own subtitle selection off (a PGS track drawn by the app replaces it)
    func deselectLegible() {
        guard let g = legibleGroup else { return }
        item?.select(nil, in: g)
    }

    func setAutoPiP(_ on: Bool) {
        pip?.canStartPictureInPictureAutomaticallyFromInline = on
    }
}

extension NativeEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onPiPActive?(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onPiPActive?(false) }
    }

    /// الرجوع من الصورة يكمّل داخل المشغّل
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            onPiPRestore?()
        }
        completionHandler(true)
    }
}
