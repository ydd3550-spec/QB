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
/// منظر رسم VLC: لما يتغيّر مقاسه (تدوير عادي أو مفروض) أو يرجع التطبيق (قفل الشاشة، الخلفية)
/// يبلّغ عشان نعيد ترتيب الصورة. VLC على iOS يتجاهل تغيير المقاس اللي يصير والتطبيق مو نشط
/// (وسط حركة التدوير أو وهو بالخلفية)، فيظل يرسم بالمقاس القديم وتتمطّط الصورة.
final class VLCSurfaceView: UIView {
    var onRelayout: (() -> Void)?
    private var lastSize: CGSize = .zero
    private var pending: [DispatchWorkItem] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        let center = NotificationCenter.default
        // Back from background / screen lock (not just Control Center, which doesn't touch the picture)
        center.addObserver(self, selector: #selector(appCameBack), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func appCameBack() {
        needsReapply = true
        scheduleRelayout()
    }

    /// The aspect only gets re-sent to VLC when something really changed (size, back from background)
    private var needsReapply = false

    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews where sub.frame != bounds { sub.frame = bounds }
        if bounds.size != lastSize {
            lastSize = bounds.size
            needsReapply = true
            scheduleRelayout()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            needsReapply = true
            scheduleRelayout()
        }
    }

    /// مرتين: أول ما يهدأ التدوير، ومرة بعد ما يرجع التطبيق نشط أكيد
    func scheduleRelayout() {
        pending.forEach { $0.cancel() }
        pending = [0.15, 0.6, 1.4].map { delay in
            let last = delay == 1.4
            let work = DispatchWorkItem { [weak self] in self?.relayoutNow(reapply: last) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    /// reapply: only the last pass re-sends the aspect to VLC (once per change, so playback doesn't hitch)
    private func relayoutNow(reapply: Bool) {
        guard window != nil, UIApplication.shared.applicationState == .active else { return }
        // نجبر منظر VLC يعيد حساب مقاسه حتى لو الإطار نفسه: هذا اللي يرسل المقاس الجديد لـ VLC
        func touch(_ v: UIView) {
            v.setNeedsLayout()
            v.layoutIfNeeded()
            v.subviews.forEach(touch)
        }
        for sub in subviews { sub.frame = bounds; touch(sub) }
        if reapply, needsReapply {
            needsReapply = false
            onRelayout?()
        }
    }
}

final class VLCEngine: PlaybackEngine {
    let kindName = "VLC"
    private let view = VLCSurfaceView()
    var surface: UIView { view }
    /// position of the audio / subtitle track to start with, among the file's tracks of that kind
    var startAudioTrack: Int?
    var startSubtitleTrack: Int?

    private let player = VLCMediaPlayer()
    private let commands = DispatchQueue(label: "qb.vlc.commands", qos: .userInitiated)
    private var tick: Task<Void, Never>?

    private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var elapsed: Double = 0
    private(set) var duration: Double?
    private(set) var isBuffering = false
    private(set) var isLive = false
    private(set) var videoSize: CGSize = .zero
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
    /// صوت VLC نفسه (0…1)، احتياط لو صوت الجهاز ما تغيّر
    private var wantedVolume: Float = 1
    private var maxSeen: Double = 0
    private var loadStarted = Date()
    private var lastTrackCheck = Date.distantPast
    private var trackSignature = ""
    private var lastTime: Double = -1
    private var lastMove = Date()
    private var pendingSeekUntil = Date.distantPast
    /// يمسك مكان التقديم لين VLC يوصله فعلًا. قبل كان فيه مهلة ثابتة 1.2 ثانية، ومع النت التقديم يطوّل
    /// أكثر منها، فيرجع الوقت القديم يكتب فوق الجديد ويرجع الشريط لورا ثم قدام
    private var seekGuard = SeekGuard()
    private static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// مكان الاستكمال: لو VLC تجاهل start-time (بعض روابط النت) نقدّم له بأنفسنا أول ما يشتغل
    private var resumeAt: Double = 0
    private var resumeChecked = false
    /// قص الصورة على نسبة الشاشة ("عرض:طول") لما يكون التكبير شغّال، nil = الحجم الأصلي
    private var cropRatio: String?
    /// للترجمة: آخر وقت تغيّر من VLC ومتى، عشان نكمّل العد بين القراءات
    private var clockTime: Double = 0
    private var clockAt = Date.distantPast

    // المراقب: الوقت يمشي بس ما فيه صور جديدة أو صوت = مخرج الصورة/الصوت مات
    private var sourceURL: URL?
    private var sourceHeaders: [String: String] = [:]
    private var reopening = false
    private var lastPictures = 0
    private var picturesAt = Date()
    private var everPictures = false
    private var lastAudioBuffers = 0
    private var audioAt = Date()
    private var everAudio = false
    /// وقت آخر صورة انعرضت فعلًا (الترجمة ما تسبق صورة واقفة)
    private var frameTime: Double = 0
    private var recoveryStage = 0
    private var recoveries = 0
    private var lastRecoveryAt = Date.distantPast
    /// طفينا مسار الصورة واحنا بالخلفية (مثل تطبيق VLC): نرجّعه أول ما نرجع
    private var parkedVideoTrack: Int32?
    private var observers: [NSObjectProtocol] = []

    private(set) var audioTracks: [TrackOption] = []
    private(set) var embeddedSubtitles: [TrackOption] = []
    private(set) var selectedAudio: String?
    private(set) var selectedEmbeddedSubtitle: String?

    func load(url: URL, headers: [String: String], startAt: Double) {
        guard !started else { return }
        started = true
        VLCLayerThreadGuard.install()
        sourceURL = url
        sourceHeaders = headers
        let media = makeMedia(url: url, headers: headers, startAt: startAt)
        resumeAt = startAt
        // الاستكمال: الشريط على مكان الاستكمال من البداية، مو صفر وبعدين ينط
        if startAt > 1 {
            seekGuard.begin(startAt, now: Self.clock)
            elapsed = startAt
        }
        view.onRelayout = { [weak self] in self?.applyCrop() }
        observeApp()
        player.drawable = view
        player.media = media
        state = .loading
        isBuffering = true
        loadStarted = Date()
        AudioSessionKeeper.shared.activate()
        player.play()
        applyCrop()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func makeMedia(url: URL, headers: [String: String], startAt: Double) -> VLCMedia {
        let media = VLCMedia(url: url)
        for option in VLCHeaderOptions.options(for: headers) { media.addOption(option) }
        if startAt > 1 { media.addOption(":start-time=\(Int(startAt))") }
        // شبكة ضعيفة: مخزون أكبر، فيصبر على الانقطاعات القصيرة بدل ما يوقف
        media.addOption(":network-caching=5000")
        // الاتصال ينقطع (رجوع من الخلفية، تبديل شبكة): يتصل من جديد بدل ما يوقف للأبد
        media.addOption(":http-reconnect")
        // Hardware decoding (VideoToolbox) first, software only if the codec isn't supported by the hardware
        media.addOption(":codec=videotoolbox,any")
        // VLC يرسم الوقت واسم الملف داخل الصورة بعد التقديم: نطفيه، الوقت عندنا بالشريط
        media.addOption(":no-osd")
        media.addOption(":no-video-title-show")
        // عدّاد الصور المعروضة والصوت المشغّل (للمراقب)
        media.addOption(":stats")
        // المسار اللي اختاره المستخدم من قائمة المشغّل الأصلي (DTS، TrueHD، VobSub ...): VLC يبدأ فيه
        if let audio = startAudioTrack { media.addOption(":audio-track=\(audio)") }
        if let sub = startSubtitleTrack { media.addOption(":sub-track=\(sub)") }
        return media
    }

    /// الخلفية والرجوع: مخرج الصورة في VLC ما ينجا من الخلفية (الصورة توقف والوقت يمشي)،
    /// فنطفي مسار الصورة ونرجّعه أول ما يرجع التطبيق، فينولد مخرج جديد مربوط بالمنظر.
    private func observeApp() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.parkVideo() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignedAt = Date() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unparkVideo() }
        })
    }

    private func parkVideo() {
        guard started, !shutDown, !finished, parkedVideoTrack == nil else { return }
        let current = player.currentVideoTrackIndex
        guard current >= 0 else { return }
        parkedVideoTrack = current
        let box = UncheckedBox(player)
        commands.async { box.value.currentVideoTrackIndex = -1 }
    }

    /// The user's screen recording after coming back showed two pictures alternating every refresh (the old
    /// video output's stale buffer and the live one) and then judder: VLC's video output on iOS doesn't survive
    /// the app going inactive. So it is always rebuilt on return: from the parked track after the background,
    /// or by restarting it after a longer inactive spell (screen lock, Control Center held open) without background.
    private var resignedAt: Date?

    private func unparkVideo() {
        guard started, !shutDown else { return }
        AudioSessionKeeper.shared.activate()
        let inactiveFor = resignedAt.map { Date().timeIntervalSince($0) } ?? 0
        resignedAt = nil
        if parkedVideoTrack == nil, inactiveFor > 1.5, !finished, player.currentVideoTrackIndex >= 0 {
            restartVideoOutput()
            picturesAt = Date()
            return
        }
        if let track = parkedVideoTrack {
            parkedVideoTrack = nil
            player.drawable = view
            let box = UncheckedBox(player)
            let paused = state == .paused
            commands.async {
                box.value.currentVideoTrackIndex = track
                // Paused: step one frame so the picture shows instead of black
                if paused {
                    Thread.sleep(forTimeInterval: 0.3)
                    if !box.value.isPlaying { box.value.gotoNextFrame() }
                }
            }
            picturesAt = Date()
        }
        view.scheduleRelayout()
    }

    /// يربط المنظر من جديد ويعيد تشغيل مسار الصورة (ينولد مخرج صورة جديد)، بدون ما يوقف التشغيل
    private func restartVideoOutput() {
        player.drawable = view
        let box = UncheckedBox(player)
        let parked = parkedVideoTrack
        parkedVideoTrack = nil
        commands.async {
            let p = box.value
            var track = parked ?? p.currentVideoTrackIndex
            if track < 0 {
                track = (p.videoTrackIndexes as? [NSNumber])?.map(\.int32Value).first { $0 >= 0 } ?? -1
            }
            guard track >= 0 else { return }
            p.currentVideoTrackIndex = -1
            p.currentVideoTrackIndex = track
            // واقف: نقدّم إطار واحد عشان تطلع صورة بدل شاشة سودا
            if !p.isPlaying {
                Thread.sleep(forTimeInterval: 0.3)
                if !p.isPlaying { p.gotoNextFrame() }
            }
        }
        view.scheduleRelayout()
    }

    /// الصورة واقفة والوقت يمشي: نبني مخرج الصورة من جديد على نفس الاتصال ونفس الثانية.
    /// هذا أخف حل وأول شي نجربه: ما يقطع الاتصال، ولا يعيد بناء الترجمة، ولا يحرّك مكان التشغيل.
    /// بعدها نقدّم لآخر إطار انعرض عشان المفكّك يفرّغ الإطارات المتأخرة ويتزامن مع الصوت.
    func recoverPicture(at seconds: Double) {
        guard !shutDown, !finished else { return }
        restartVideoOutput()
        if player.isSeekable, seconds > 1 { seek(to: seconds) }
        picturesAt = Date()
    }

    /// يشغّل الصوت من جديد (مخرج صوت جديد) بعد ما ننشّط جلسة الصوت
    private func restartAudioOutput() {
        AudioSessionKeeper.shared.activate()
        let box = UncheckedBox(player)
        commands.async {
            let p = box.value
            let track = p.currentAudioTrackIndex
            guard track >= 0 else { return }
            p.currentAudioTrackIndex = -1
            p.currentAudioTrackIndex = track
        }
    }

    /// آخر حل: نفتح نفس المصدر من جديد من نفس الثانية، بدون رسالة
    private func reopen(at position: Double? = nil) {
        guard let url = sourceURL, !reopening, !shutDown, !finished else { return }
        reopening = true
        let at = position ?? elapsed
        let media = makeMedia(url: url, headers: sourceHeaders, startAt: at)
        let box = UncheckedBox(player)
        commands.async {
            box.value.stop()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.shutDown else { return }
                self.resumeAt = at
                self.resumeChecked = false
                if at > 1 { self.seekGuard.begin(at, now: Self.clock) }
                self.hasPlayed = false
                self.opened = false
                self.everPictures = false
                self.everAudio = false
                self.lastPictures = 0
                self.lastAudioBuffers = 0
                self.loadStarted = Date()
                self.lastMove = Date()
                self.clockAt = .distantPast
                self.trackSignature = ""
                self.player.drawable = self.view
                self.player.media = media
                self.reopening = false
                AudioSessionKeeper.shared.activate()
                self.player.play()
                if self.wantedRate != 1 { self.player.rate = self.wantedRate }
                if self.wantedVolume < 1 { self.player.audio?.volume = Int32((self.wantedVolume * 100).rounded()) }
                self.applyCrop()
            }
        }
    }

    /// الوقت يمشي بس الصورة واقفة أو الصوت مقطوع قرابة ثانيتين: نصلح لحالنا بدون رسالة.
    /// أول مرة نشغّل المخرج من جديد، ولو ما نفع نفتح المصدر من نفس المكان.
    private func watchdog() {
        let now = Date()
        guard hasPlayed, player.isPlaying, state == .playing, now > pendingSeekUntil, let media = player.media else {
            picturesAt = now
            audioAt = now
            return
        }
        let pictures = media.numberOfDisplayedPictures
        let buffers = media.numberOfPlayedAudioBuffers
        if pictures != lastPictures {
            if pictures > 0 { everPictures = true }
            lastPictures = pictures
            picturesAt = now
            frameTime = elapsed
            // الصورة رجعت تمشي من دقيقة: نرجّع عدّاد الاستعادات (قبل كان 3 مرات بس لكل فتحة، وبعدها تبقى الصورة واقفة للأبد)
            if now.timeIntervalSince(lastRecoveryAt) > 60 {
                recoveries = 0
                recoveryStage = 0
            }
        }
        if buffers != lastAudioBuffers {
            if buffers > 0 { everAudio = true }
            lastAudioBuffers = buffers
            audioAt = now
        }
        // العدّاد ما يشتغل أبد (ما تغيّر ولا مرة) = ما نحكم عليه
        // VLC refreshes these counters about once a second, so the bar is well above that (no false alarms
        // that would restart a healthy picture and cause stutter). At most 3 recoveries per load.
        //
        // everPictures ينصفّر مع كل فتحة جديدة (reopen)، وكان هذا يخلّي الحارس أعمى للأبد لو الفتحة
        // الجديدة ما عرضت ولا إطار (تعليق شبكة): الصورة تبقى واقفة والصوت يمشي وما فيه شي يكشفها.
        // نعتبر إن المصدر فيه فيديو لو عرفنا مقاس الصورة، حتى لو ما وصل ولا إطار بهالفتحة.
        let hasVideo = everPictures || player.videoSize.width > 0
        let videoDead = hasVideo && parkedVideoTrack == nil && now.timeIntervalSince(picturesAt) > 3.5
        let audioDead = everAudio && player.currentAudioTrackIndex >= 0 && now.timeIntervalSince(audioAt) > 3.5
        guard videoDead || audioDead else { return }
        // المحاولات تتباعد كل مرة (5، 10، 15… لين 30 ثانية) وما نتوقف للأبد: بعد ما نخلص نسلّم
        // للموديل عشان يعيد المصدر بالكامل أو يورّي رسالة، بدل صورة واقفة بلا نهاية
        guard recoveries < 6, now.timeIntervalSince(lastRecoveryAt) > min(5 + Double(recoveries) * 5, 30) else {
            if recoveries >= 6, now.timeIntervalSince(lastRecoveryAt) > 30, state != .stalled {
                lastRecoveryAt = now
                state = .stalled
            }
            return
        }
        lastRecoveryAt = now
        recoveries += 1
        recoveryStage += 1
        // الصورة توقف والصوت يكمّل بعد التعليق: مفكّك الصورة يرمي كل إطار لأنه "متأخر" عن ساعة الصوت.
        // نرجع لآخر إطار انعرض: هذا يفرّغ المفكّك ويزامن الصورة والصوت والترجمة من نفس المكان
        let lastFrame = max(0, min(elapsed, frameTime))
        // أول محاولتين: مخرج الصورة بس (نفس الاتصال ونفس الثانية). بعدها نفتح المصدر من جديد.
        // قبل كان يبدّل بينهم محاولة بمحاولة، فكان يفتح المصدر كامل كل ثاني تعليق بلا داعي.
        if recoveryStage <= 2 {
            if videoDead {
                restartVideoOutput()
                if player.isSeekable, lastFrame > 1 { seek(to: lastFrame) }
            }
            if audioDead { restartAudioOutput() }
            picturesAt = now
            audioAt = now
        } else {
            recoveryStage = 0
            reopen(at: videoDead ? lastFrame : nil)
        }
    }

    /// البيانات اللي وصلت من الشبكة: للتعليق، ننتظر طول ما فيه بيانات توصل
    var bytesReceived: Int64? {
        guard let media = player.media else { return nil }
        return Int64(media.numberOfReadBytesOnInput)
    }

    /// عدد الإطارات اللي عرضها VLC فعلًا. النموذج (FrameWatch) يستخدمه عشان يكتشف
    /// "الوقت يمشي والصورة واقفة" لما الحارس الداخلي يستسلم — وإلا كان يبقى أعمى على VLC.
    var framesShown: Int? {
        guard let media = player.media else { return nil }
        return media.numberOfDisplayedPictures
    }

    /// الصورة واقفة والوقت يمشي
    private var pictureFrozen: Bool {
        everPictures && parkedVideoTrack == nil && Date().timeIntervalSince(picturesAt) > 1.5
    }

    /// ملء الشاشة: VLC يقص الصورة على نسبة الشاشة نفسها، فتملّيها بدون ما تتمطّط
    func setVideoFill(_ fill: Bool, viewport: CGSize) {
        var ratio: String?
        if fill, viewport.width >= 1, viewport.height >= 1 {
            ratio = "\(Int(viewport.width.rounded())):\(Int(viewport.height.rounded()))"
        }
        guard ratio != cropRatio else { return }
        cropRatio = ratio
        applyCrop()
    }

    /// يعيد ترتيب الصورة: الحجم الأصلي = نسبة الفيديو نفسها وتتلاءم مع الشاشة،
    /// التكبير = قص على نسبة الشاشة. ما نغيّر نسبة العرض أبد، فما تتمطّط الصورة.
    /// تعيينها من جديد يخلّي VLC يحسب مكان الصورة على المقاس الحالي.
    private func applyCrop() {
        guard started, !shutDown else { return }
        let box = UncheckedBox(player)
        let ratio = cropRatio
        commands.async {
            box.value.videoAspectRatio = nil
            if let ratio {
                // libVLC ياخذ نسخة من النص، فيكفي يعيش وقت الاستدعاء
                ratio.withCString { box.value.videoCropGeometry = UnsafeMutablePointer(mutating: $0) }
            } else {
                box.value.videoCropGeometry = nil
            }
            // 0 = يتلاءم مع النافذة بمقاسها الحالي
            box.value.scaleFactor = 0
        }
    }

    func refreshLayout() { view.scheduleRelayout() }  // touches the views; the aspect is re-sent only if needed

    /// للترجمة: وقت VLC المبلّغ + اللي مر من بعده وهو شغّال (VLC يبلّغ الوقت بخطوات)
    var liveTime: Double {
        // الصورة واقفة: الترجمة توقف عند آخر صورة انعرضت
        if state == .playing, pictureFrozen { return min(elapsed, frameTime) }
        guard state == .playing, Date() > pendingSeekUntil, !seekGuard.isPending, clockAt != .distantPast else { return elapsed }
        let ahead = min(Date().timeIntervalSince(clockAt), 1.0) * Double(wantedRate)
        return max(elapsed, clockTime + max(0, ahead))
    }

    private func poll() {
        guard !finished, !reopening else { return }
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
        if t.isFinite, t >= 0 {
            // وقت التقديم: VLC يكمّل يبلّغ الوقت القديم لين يوصل للمكان الجديد. نعرض الهدف بس لين يوصله
            // (أو يتعداه)، فالشريط والوقت والترجمة ما يرجعون لورا ولا لحظة
            let shown = seekGuard.resolve(reported: t, now: Self.clock)
            elapsed = shown
            if !seekGuard.isPending, t != clockTime || !player.isPlaying {
                clockTime = t
                clockAt = Date()
            }
        }
        if t > 0.05, abs(t - lastTime) > 0.05 {
            lastTime = t
            lastMove = Date()
            hasPlayed = true
        }
        if hasPlayed, !resumeChecked, resumeAt > 1 {
            resumeChecked = true
            if t < resumeAt - 5 { seek(to: resumeAt) }
        }
        maxSeen = max(maxSeen, elapsed)
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length.isFinite, length > 1 {
            duration = length
        } else if let remaining = player.remainingTime?.intValue, remaining < 0, t > 0 {
            duration = t + Double(-remaining) / 1000
        }
        let vs = player.videoSize
        if vs.width > 0, vs.height > 0, vs != videoSize {
            let first = videoSize == .zero
            videoSize = vs
            // مخرج الصورة انولد الحين: نعيد القص عليه لو التكبير شغّال من قبل
            if first, cropRatio != nil { applyCrop() }
        }
        // مباشر: اشتغل فعلًا، ما له مدة، وما يقبل التقديم
        isLive = hasPlayed && duration == nil && !player.isSeekable && elapsed > 3
        // بث ما يقبل التقديم: ما فيه هدف ننتظره
        if seekGuard.isPending, hasPlayed, !player.isSeekable { seekGuard.cancel() }

        if player.isPlaying {
            let moving = Date().timeIntervalSince(lastMove) < 1.5
            isBuffering = !moving && hasPlayed == false
            state = (hasPlayed && !moving) ? .stalled : (hasPlayed ? .playing : .loading)
            if !hasPlayed { isBuffering = true }
        } else if s == .paused {
            isBuffering = false
            state = .paused
        }

        watchdog()

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
        AudioSessionKeeper.shared.activate()
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
        let volume = wantedVolume
        commands.async {
            box.value.play()
            if rate != 1 { box.value.rate = rate }
            if volume < 1 { box.value.audio?.volume = Int32((volume * 100).rounded()) }
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
        // تقديم جديد يلغي المعلّق، والضغطات المتتالية تنحسب من الهدف (PlayerModel.skip)
        seekGuard.begin(target, now: Self.clock)
        elapsed = target
        clockTime = target
        clockAt = .distantPast
        frameTime = target
        pendingSeekUntil = Date().addingTimeInterval(1.2)
        lastMove = Date()
        let box = UncheckedBox(player)
        let ms = Int32(clamping: Int(target * 1000))
        commands.async {
            guard box.value.isSeekable else { return }
            box.value.time = VLCTime(int: ms)
        }
    }

    func setVolume(_ volume: Float) {
        wantedVolume = volume
        guard started, !shutDown else { return }
        let box = UncheckedBox(player)
        let v = Int32((min(max(volume, 0), 1) * 100).rounded())
        commands.async { box.value.audio?.volume = v }
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
    func stopPiP() {}
    func setAutoPiP(_ on: Bool) {}

    /// يوقف VLC من نفس طابور الأوامر (بعد أي أمر باقي)، ويفك المنظر على الخيط الرئيسي.
    /// المنظر ينحفظ لين يخلص الإيقاف عشان VLC ما يرسم في منظر انحذف.
    func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        finished = true
        tick?.cancel()
        tick = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        state = .idle
        guard started else { return }
        let box = UncheckedBox(player)
        let surface = UncheckedBox(view)
        Self.stopping += 1
        commands.async {
            box.value.stop()
            DispatchQueue.main.async {
                box.value.drawable = nil
                surface.value.removeFromSuperview()
                VLCEngine.stopping = max(0, VLCEngine.stopping - 1)
            }
        }
    }

    /// كم نسخة VLC قاعدة تسكّر اتصالها الحين (الإيقاف على النت ممكن يطوّل)
    nonisolated(unsafe) static var stopping = 0

    /// ينتظر (لين 4 ثواني) إن النسخة القديمة تسكّر، عشان ما نفتح نفس الرابط مرتين بنفس الوقت
    static func waitForPreviousStop() async {
        let until = Date().addingTimeInterval(4)
        while stopping > 0, Date() < until {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
