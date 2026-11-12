import Foundation
import UIKit
import ObjectiveC
import MobileVLCKit

/// ترويسات HTTP لـ VLC: ياخذ user agent وreferrer بس لكل ملف
nonisolated enum VLCHeaderOptions {
    static func options(for headers: [String: String]) -> [String] {
        var result: [String] = []
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let clean = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            switch name.lowercased() {
            case "user-agent": result.append(":http-user-agent=\(clean)")
            case "referer", "referrer": result.append(":http-referrer=\(clean)")
            default: continue
            }
        }
        return result
    }
}

/// MobileVLCKit 3.x يرسم من خيط خاص فيه، ولما يسوي الـ buffer يلمس طبقة المنظر برا الخيط الرئيسي
/// وUIKit على iOS 26 يعترض. هذا يرجّع "ما فيه حركة" لطبقة فيديو VLC برا الخيط الرئيسي،
/// وعلى الخيط الرئيسي يستخدم جواب UIKit العادي.
nonisolated enum VLCLayerThreadGuard {
    private static let done: Bool = {
        guard let viewClass = NSClassFromString("VLCOpenGLES2VideoView"),
              let parent = class_getSuperclass(viewClass) else { return false }
        let selector = NSSelectorFromString("actionForLayer:forKey:")
        guard let inherited = class_getInstanceMethod(parent, selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector, CALayer, NSString) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(inherited), to: Action.self)
        let answer: @convention(block) (AnyObject, CALayer, NSString) -> AnyObject? = { view, layer, key in
            if Thread.isMainThread { return original(view, selector, layer, key) }
            return NSNull()
        }
        return class_addMethod(viewClass, selector, imp_implementationWithBlock(answer), method_getTypeEncoding(inherited))
    }()

    static func install() { _ = done }
}

/// مشغّل VLC: MKV وAVI وWebM وTS وأي شي ما يقدر عليه AVPlayer.
/// الأوامر (تشغيل، إيقاف، تقديم) تروح لطابور واحد برا الخيط الرئيسي
/// لأن libVLC ممكن يعلّق المستدعي (خصوصًا التقديم في ملف على النت).
final class VLCEngine: PlaybackEngine {
    let kindName = "VLC"
    private let view: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        return v
    }()
    var surface: UIView { view }

    private let player = VLCMediaPlayer()
    private let commands = DispatchQueue(label: "qb.vlc.commands", qos: .userInitiated)
    private var tick: Task<Void, Never>?

    private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var elapsed: Double = 0
    private(set) var duration: Double?
    private(set) var isBuffering = false
    let supportsPiP = false
    let supportsAirPlay = false

    var onStateChange: ((PlaybackState) -> Void)?
    var onFailure: ((EngineFailure) -> Void)?
    var onTracksChanged: (() -> Void)?

    private var started = false
    private var finished = false
    private var shutDown = false
    private var hasPlayed = false
    private var opened = false
    private var wantsPlay = true
    private var wantedRate: Float = 1
    private var maxSeen: Double = 0
    private var loadStarted = Date()
    private var lastTrackCheck = Date.distantPast
    private var trackSignature = ""
    private var lastTime: Double = -1
    private var lastMove = Date()
    private var pendingSeekUntil = Date.distantPast

    private(set) var audioTracks: [TrackOption] = []
    private(set) var embeddedSubtitles: [TrackOption] = []
    private(set) var selectedAudio: String?
    private(set) var selectedEmbeddedSubtitle: String?

    func load(url: URL, headers: [String: String], startAt: Double) {
        guard !started else { return }
        started = true
        VLCLayerThreadGuard.install()
        let media = VLCMedia(url: url)
        for option in VLCHeaderOptions.options(for: headers) { media.addOption(option) }
        if startAt > 1 { media.addOption(":start-time=\(Int(startAt))") }
        media.addOption(":network-caching=3000")
        player.drawable = view
        player.media = media
        state = .loading
        isBuffering = true
        loadStarted = Date()
        player.play()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func poll() {
        guard !finished else { return }
        let s = player.state
        switch s {
        case .opening, .buffering:
            opened = true
        case .error:
            fail("vlc error")
            return
        case .ended:
            finished = true
            state = .ended
            isBuffering = false
            tick?.cancel()
            return
        case .stopped:
            if opened || hasPlayed {
                if hasPlayed {
                    finished = true
                    state = .ended
                    tick?.cancel()
                } else {
                    fail("stopped")
                }
                return
            }
        default:
            break
        }

        let t = Double(player.time.intValue) / 1000
        if t.isFinite, t >= 0, Date() > pendingSeekUntil { elapsed = t }
        if t > 0.05, abs(t - lastTime) > 0.05 {
            lastTime = t
            lastMove = Date()
            hasPlayed = true
        }
        maxSeen = max(maxSeen, elapsed)
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length.isFinite, length > 1 {
            duration = length
        } else if let remaining = player.remainingTime?.intValue, remaining < 0, t > 0 {
            duration = t + Double(-remaining) / 1000
        }

        if player.isPlaying {
            let moving = Date().timeIntervalSince(lastMove) < 1.5
            isBuffering = !moving && hasPlayed == false
            state = (hasPlayed && !moving) ? .stalled : (hasPlayed ? .playing : .loading)
            if !hasPlayed { isBuffering = true }
        } else if s == .paused {
            isBuffering = false
            state = .paused
        }

        // ما انفتح شي خلال 25 ثانية: المصدر ما يرد
        if !hasPlayed, wantsPlay, Date().timeIntervalSince(loadStarted) > 25 {
            fail("timeout")
            return
        }

        if Date().timeIntervalSince(lastTrackCheck) >= 2 || s == .esAdded {
            lastTrackCheck = Date()
            readTracks()
        }
    }

    private func readTracks() {
        let signature = "\(player.numberOfAudioTracks)|\(player.numberOfSubtitlesTracks)|\(player.currentAudioTrackIndex)|\(player.currentVideoSubTitleIndex)"
        guard signature != trackSignature else { return }
        trackSignature = signature
        audioTracks = Self.list(names: player.audioTrackNames, ids: player.audioTrackIndexes)
        embeddedSubtitles = Self.list(names: player.videoSubTitlesNames, ids: player.videoSubTitlesIndexes)
        let a = player.currentAudioTrackIndex
        selectedAudio = a >= 0 ? "\(a)" : nil
        let sub = player.currentVideoSubTitleIndex
        selectedEmbeddedSubtitle = sub >= 0 ? "\(sub)" : nil
        if audioTracks.count < 2 { audioTracks = audioTracks.count == 1 ? [] : audioTracks }
        onTracksChanged?()
    }

    /// VLC يرجّع الأسماء والأرقام بقائمتين، والعنصر -1 (إيقاف) نتركه
    nonisolated static func list(names: [Any], ids: [Any]) -> [TrackOption] {
        zip(names, ids).compactMap { name, id in
            guard let number = (id as? NSNumber)?.intValue, number >= 0 else { return nil }
            let text = (name as? String) ?? "\(number)"
            return TrackOption(id: "\(number)", name: text, language: nil)
        }
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        isBuffering = false
        tick?.cancel()
        state = .failed(reason)
        onFailure?(.sourceFailed(reason))
    }

    func play() {
        guard started, !shutDown else { return }
        wantsPlay = true
        if state == .ended {
            // بعد النهاية VLC يحتاج يبدأ من جديد
            finished = false
            hasPlayed = false
            loadStarted = Date()
            tick?.cancel()
            tick = Task { [weak self] in
                while !Task.isCancelled {
                    self?.poll()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        let box = UncheckedBox(player)
        let rate = wantedRate
        commands.async {
            box.value.play()
            if rate != 1 { box.value.rate = rate }
        }
        if hasPlayed { state = .playing }
    }

    func pause() {
        guard started, !shutDown else { return }
        wantsPlay = false
        let box = UncheckedBox(player)
        commands.async { box.value.pause() }
        state = .paused
    }

    func seek(to seconds: Double) {
        guard started, !shutDown else { return }
        let target = max(0, seconds)
        elapsed = target
        pendingSeekUntil = Date().addingTimeInterval(1.2)
        lastMove = Date()
        let box = UncheckedBox(player)
        let ms = Int32(clamping: Int(target * 1000))
        commands.async {
            guard box.value.isSeekable else { return }
            box.value.time = VLCTime(int: ms)
        }
    }

    func setRate(_ rate: Float) {
        wantedRate = rate
        guard started, !shutDown else { return }
        let box = UncheckedBox(player)
        commands.async { box.value.rate = rate }
    }

    func selectAudio(_ id: String) {
        guard let i = Int32(id) else { return }
        player.currentAudioTrackIndex = i
        trackSignature = ""
        readTracks()
    }

    func selectEmbeddedSubtitle(_ id: String?) {
        player.currentVideoSubTitleIndex = id.flatMap { Int32($0) } ?? -1
        trackSignature = ""
        readTracks()
    }

    func startPiP() {}
    func setAutoPiP(_ on: Bool) {}

    /// يوقف VLC من نفس طابور الأوامر (بعد أي أمر باقي)، ويفك المنظر على الخيط الرئيسي.
    /// المنظر ينحفظ لين يخلص الإيقاف عشان VLC ما يرسم في منظر انحذف.
    func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        finished = true
        tick?.cancel()
        tick = nil
        state = .idle
        guard started else { return }
        let box = UncheckedBox(player)
        let surface = UncheckedBox(view)
        commands.async {
            box.value.stop()
            DispatchQueue.main.async {
                box.value.drawable = nil
                surface.value.removeFromSuperview()
            }
        }
    }
}
