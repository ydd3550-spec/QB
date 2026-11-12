import AVFoundation
import AVKit
import UIKit

/// منظر طبقته AVPlayerLayer
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
            fail(item.error?.localizedDescription ?? "failed")
            return
        case .readyToPlay:
            if readyAt == nil {
                readyAt = Date()
                lastProgressAt = Date()
                if startAt > 1, !didInitialSeek {
                    didInitialSeek = true
                    player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600))
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
        guard let readyAt, wantsPlay else { return }
        let sinceReady = Date().timeIntervalSince(readyAt)
        if sinceReady >= 6, !everPlayed {
            let stuck = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && Date().timeIntervalSince(lastProgressAt) >= 6
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

    func play() {
        wantsPlay = true
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
