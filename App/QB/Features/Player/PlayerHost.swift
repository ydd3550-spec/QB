import SwiftUI
import AVKit
import QBCore

/// المشغّل بملء الشاشة: الفيديو، الترجمة، الإيماءات، وأدوات التحكم الزجاجية
struct PlayerHost: View {
    @Environment(AppModel.self) private var app
    private var player: PlayerModel { app.player }

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dragOffset: CGFloat = 0
    /// السحب لتحت خلص وقاعد نطلع: نوقف أي إيماءة ثانية لين تختفي الشاشة
    @State private var leaving = false
    @State private var seekPreview: Double?
    @State private var seekStart: Double = 0
    @State private var dragAxis: Axis?
    @State private var ripple: RippleSide?
    /// كم ثانية تجمّعت بالضغطات المتتالية على نفس الطرف (10، 20، 30…)
    @State private var rippleSeconds = 10
    @State private var rippleTick = 0
    @State private var rippleTask: Task<Void, Never>?
    @State private var sheet: PlayerSheet?

    enum RippleSide { case back, forward }

    enum PlayerSheet: String, Identifiable {
        case tracks, sources, similar, speed
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                EngineSurface(surface: player.surface)
                    .ignoresSafeArea()
                    .opacity(player.surface == nil ? 0 : 1)

                gestureLayer(size: geo.size)

                SubtitleOverlay(text: player.cueText, scale: app.subtitleSize, background: app.subtitleBackground)
                    .padding(.bottom, controlsVisible ? 128 : 34)
                    .animation(Motion.standard, value: controlsVisible)
                    .allowsHitTesting(false)

                if let ripple {
                    SeekRipple(side: ripple, seconds: rippleSeconds, tick: rippleTick)
                        .allowsHitTesting(false)
                }

                if let seekPreview {
                    Text("\(TimeFormat.clock(seekPreview)) / \(TimeFormat.clock(player.duration ?? 0))")
                        .font(Typo.time)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .allowsHitTesting(false)
                }

                loadingOrError

                if controlsVisible {
                    controls
                        .transition(.opacity)
                }

                nextUpCard
            }
            .offset(y: dragOffset)
            .scaleEffect(1 - min(dragOffset / 1600, 0.12))
            .allowsHitTesting(!leaving)
        }
        // خلفية الشاشة شفافة: لما تسحب لتحت تشوف الصفحة اللي تحت مثل ما هي، وما تنعاد ولا تنبني من جديد
        .presentationBackground(.clear)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            scheduleHide()
            player.coverAppeared()
        }
        .onChange(of: player.state) { _, s in
            if s == .paused || s == .ended { showControls(autoHide: false) }
            if s == .playing { scheduleHide() }
        }
        .onChange(of: player.videoSize) { _, _ in player.autoRotateIfNeeded() }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .tracks: TracksSheet()
                case .sources: PlayerSourcesSheet()
                case .similar: SimilarSheet()
                case .speed: SpeedSheet()
                }
            }
            .environment(app)
            .environment(\.layoutDirection, app.language.direction)
            .environment(\.locale, app.language.locale)
            .presentationDetents([.medium, .large])
            .presentationBackground(.thinMaterial)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - الإيماءات

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                // الطرف اليسار رجوع واليمين تقديم (اتجاه الزمن ما ينعكس)
                let forward = point.x > size.width / 2
                player.skip(forward ? 10 : -10)
                flash(forward ? .forward : .back)
            }
            .onTapGesture {
                if controlsVisible { hideControls() } else { showControls(autoHide: true) }
            }
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { v in
                        if dragAxis == nil {
                            dragAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                            seekStart = player.elapsed
                        }
                        switch dragAxis {
                        case .horizontal:
                            guard player.duration != nil else { return }
                            seekPreview = SeekMath.target(start: seekStart, dx: v.translation.width, width: size.width, duration: player.duration)
                        case .vertical:
                            dragOffset = max(0, v.translation.height)
                        case nil:
                            break
                        }
                    }
                    .onEnded { v in
                        defer { dragAxis = nil }
                        if dragAxis == .horizontal, let target = seekPreview {
                            player.seek(to: target)
                            seekPreview = nil
                            Haptics.tap()
                            return
                        }
                        if dragAxis == .vertical {
                            if PlayerLogic.swipeDismisses(translation: v.translation.height, predicted: v.predictedEndTranslation.height) {
                                // نكمّل الحركة لتحت لين تطلع من الشاشة، وبعدين نشيلها بدون حركة ثانية.
                                // قبل كانت ترجع لفوق وتنزل مرة ثانية مع حركة الإغلاق، فيبان كل شي يتكرر.
                                leaving = true
                                withAnimation(.easeOut(duration: 0.22)) { dragOffset = size.height + 120 }
                                Task {
                                    try? await Task.sleep(for: .milliseconds(240))
                                    player.minimize(animated: false)
                                }
                            } else {
                                withAnimation(Motion.snappy) { dragOffset = 0 }
                            }
                        }
                    }
            )
    }

    private func flash(_ side: RippleSide) {
        rippleTask?.cancel()
        rippleSeconds = PlayerLogic.nextSeekBurst(previous: ripple == side ? rippleSeconds : nil)
        rippleTick += 1
        withAnimation(.easeOut(duration: 0.12)) { ripple = side }
        rippleTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { ripple = nil }
        }
    }

    private func showControls(autoHide: Bool) {
        withAnimation(Motion.standard) { controlsVisible = true }
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hideControls() {
        hideTask?.cancel()
        withAnimation(Motion.standard) { controlsVisible = false }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, player.isPlaying, sheet == nil else { return }
            withAnimation(Motion.standard) { controlsVisible = false }
        }
    }

    /// أي ضغطة على زر تمدد بقاء الأدوات
    private func touch(_ action: () -> Void) {
        action()
        scheduleHide()
    }

    // MARK: - الأدوات

    private var controls: some View {
        ZStack {
            // تظليل أعلى وأسفل عشان الأزرار تبان فوق أي فيديو
            VStack {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // أزرار الوسط بنص الفيديو بالضبط (الفيديو نفسه يغطي الشاشة كلها)، مو بين الشريطين
            transport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassCircleButton(systemImage: "chevron.down", size: 42, label: L("تصغير")) { player.minimize() }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.context?.title ?? "").font(Typo.headline).lineLimit(1)
                if let sub = player.context?.subtitle {
                    Text(sub).font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 8)
            if player.supportsAirPlay {
                AirPlayButton()
                    .frame(width: 42, height: 42)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel(L("AirPlay"))
            }
            if player.supportsPiP {
                GlassCircleButton(systemImage: "pip.enter", size: 42, label: L("صورة داخل صورة")) { touch { player.startPiP() } }
            }
            GlassCircleButton(systemImage: "rotate.right", size: 42, label: L("تدوير الشاشة")) { touch { player.toggleOrientation() } }
            GlassCircleButton(systemImage: "xmark", size: 42, label: L("إغلاق")) { player.close() }
        }
    }

    /// بالنص زر التشغيل/الإيقاف بس. التقديم والرجوع بضغطتين على طرف الشاشة مثل يوتيوب
    private var transport: some View {
        Button {
            touch { player.togglePlay() }
        } label: {
            ZStack {
                // مؤشر التحميل الوحيد بالشاشة يكون هنا داخل الزر
                if showsSpinner {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: PlayerLogic.Transport.play * 0.4, weight: .bold))
                        // المثلث وزنه على اليسار، نزحزحه شوي عشان يبان بالنص
                        .offset(x: player.isPlaying ? 0 : PlayerLogic.Transport.play * 0.04)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .foregroundStyle(.white)
            .frame(width: PlayerLogic.Transport.play, height: PlayerLogic.Transport.play)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(player.isPlaying ? L("إيقاف مؤقت") : L("تشغيل"))
        .accessibilityAction(named: L("رجوع 10 ثواني")) { player.skip(-10) }
        .accessibilityAction(named: L("تقديم 10 ثواني")) { player.skip(10) }
        .environment(\.layoutDirection, .leftToRight)
        .opacity(player.errorMessage == nil ? 0.92 : 0)
    }

    private var showsSpinner: Bool {
        player.state == .loading || (player.isBuffering && player.state != .paused)
    }

    private var showSkipIntro: Bool {
        player.context?.video != nil && player.elapsed > 3 && player.elapsed < Double(max(app.skipIntroSeconds, 30)) + 60 && player.isPlaying
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack {
                if showSkipIntro {
                    GlassButton(title: L("تخطّي المقدمة"), systemImage: "forward.fill") {
                        touch { player.skip(Double(app.skipIntroSeconds)) }
                    }
                    .transition(.opacity)
                }
                Spacer()
                if player.context?.video != nil, player.nextUp != nil || player.context?.meta != nil {
                    GlassButton(title: L("الحلقة الجاية"), systemImage: "forward.end.fill") {
                        touch { player.playNext() }
                    }
                }
            }
            Scrubber(elapsed: player.elapsed, duration: player.duration, live: player.isLive) { t in
                player.seek(to: t)
                scheduleHide()
            } onScrubbing: { scrubbing in
                if scrubbing { hideTask?.cancel() } else { scheduleHide() }
            }
            HStack(spacing: 10) {
                pill(L("الترجمة والصوت"), "captions.bubble.fill") { sheet = .tracks }
                pill(L("المصادر"), "rectangle.stack.fill") { sheet = .sources }
                pill(rateLabel, "gauge.with.dots.needle.67percent") { sheet = .speed }
                if !player.similar.isEmpty {
                    pill(L("مشابه"), "square.grid.2x2.fill") { sheet = .similar }
                }
                Spacer(minLength: 0)
                Text(player.engineName)
                    .font(Typo.badge)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
    }

    private var rateLabel: String {
        player.rate == 1 ? L("السرعة") : String(format: "%.2gx", player.rate)
    }

    private func pill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            hideTask?.cancel()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(Typo.caption).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: - التحميل والخطأ

    @ViewBuilder
    private var loadingOrError: some View {
        if let message = player.errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(Palette.accent)
                Text(message).font(Typo.title).multilineTextAlignment(.center)
                Text(L("جرّب مرة ثانية أو اختر مصدر ثاني")).font(Typo.info).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    GlassButton(title: L("إعادة المحاولة"), systemImage: "arrow.clockwise", width: ButtonMetrics.pairWidth) { player.retry() }
                    if player.canTryAnother {
                        PrimaryButton(title: L("جرّب مصدر ثاني"), systemImage: "arrow.triangle.2.circlepath", width: ButtonMetrics.pairWidth) { player.tryAnotherSource() }
                    }
                }
                GlassButton(title: L("المصادر"), systemImage: "rectangle.stack.fill", width: ButtonMetrics.pairWidth) { sheet = .sources }
            }
            .foregroundStyle(.white)
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .padding(24)
        } else if player.state == .loading || (player.isBuffering && player.elapsed < 1) {
            // مؤشر واحد بس: داخل زر التشغيل لما الأدوات ظاهرة، وبنفس مكانه لما تختفي
            ZStack {
                if !controlsVisible {
                    ProgressView().controlSize(.small).tint(.white)
                        .frame(width: PlayerLogic.Transport.play, height: PlayerLogic.Transport.play)
                        .glassEffect(.clear, in: .circle)
                        .transition(.opacity)
                }
                if player.showTryAnother, player.canTryAnother {
                    GlassButton(title: L("جرّب مصدر ثاني"), systemImage: "arrow.triangle.2.circlepath") { player.tryAnotherSource() }
                        .foregroundStyle(.white)
                        .padding(.top, 150)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(Motion.standard, value: player.showTryAnother)
            .animation(Motion.standard, value: controlsVisible)
            .allowsHitTesting(player.showTryAnother)
        }
    }

    // MARK: - الحلقة الجاية

    @ViewBuilder
    private var nextUpCard: some View {
        if let next = player.nextUp, player.state == .ended {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("الحلقة الجاية")).font(Typo.caption).foregroundStyle(.secondary)
                        Text(next.title.isEmpty ? L("الحلقة %@", "\(next.episode ?? 0)") : next.title)
                            .font(Typo.headline).lineLimit(2)
                        HStack(spacing: 10) {
                            PrimaryButton(title: player.nextCountdown.map { L("تشغيل خلال %@", "\($0)") } ?? L("تشغيل")) {
                                player.playNext()
                            }
                            if player.nextCountdown != nil {
                                GlassButton(title: L("إلغاء")) { player.cancelNext() }
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                    .frame(maxWidth: 340, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
                }
            }
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// شريط التقديم (يبقى من اليسار لليمين حتى بالعربي، لأنه اتجاه الزمن)
struct Scrubber: View {
    let elapsed: Double
    let duration: Double?
    /// بث مباشر فعلًا. لو المدة بس ما وصلت للحين (التحميل) نعرض --:--
    var live = false
    let onSeek: (Double) -> Void
    var onScrubbing: (Bool) -> Void = { _ in }

    @State private var dragValue: Double?

    var body: some View {
        let total = duration ?? 0
        let shown = dragValue ?? elapsed
        VStack(spacing: 6) {
            GeometryReader { geo in
                let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(Palette.accent).frame(width: geo.size.width * fraction)
                    Circle()
                        .fill(.white)
                        .frame(width: dragValue == nil ? 13 : 20, height: dragValue == nil ? 13 : 20)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: geo.size.width * fraction - (dragValue == nil ? 6.5 : 10))
                        .opacity(total > 0 ? 1 : 0)
                }
                .frame(height: dragValue == nil ? 5 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard total > 0 else { return }
                            if dragValue == nil { onScrubbing(true) }
                            dragValue = min(max(Double(v.location.x / geo.size.width), 0), 1) * total
                        }
                        .onEnded { _ in
                            if let d = dragValue { onSeek(d) }
                            dragValue = nil
                            onScrubbing(false)
                        }
                )
                .animation(Motion.snappy, value: dragValue == nil)
            }
            .frame(height: 24)
            HStack {
                Text(TimeFormat.clock(shown))
                Spacer()
                Text(Self.trailingLabel(elapsed: shown, duration: duration, live: live))
            }
            .font(Typo.time)
            .foregroundStyle(.white.opacity(0.8))
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(L("التقدّم"))
        .accessibilityValue("\(TimeFormat.clock(shown)) / \(TimeFormat.clock(total))")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onSeek(elapsed + 10)
            case .decrement: onSeek(max(0, elapsed - 10))
            @unknown default: break
            }
        }
    }
}

extension Scrubber {
    /// النص اللي يمين الشريط: الباقي لو المدة معروفة، «مباشر» للبث المباشر بس، وغير كذا --:--
    static func trailingLabel(elapsed: Double, duration: Double?, live: Bool) -> String {
        switch PlayerLogic.trailingTime(elapsed: elapsed, duration: duration, live: live) {
        case .remaining(let r): return "-" + TimeFormat.clock(r)
        case .live: return L("مباشر")
        case .unknown: return "--:--"
        }
    }
}

/// الترجمة فوق الفيديو
struct SubtitleOverlay: View {
    let text: String?
    let scale: Double
    let background: Bool

    var body: some View {
        VStack {
            Spacer()
            if let text {
                Text(text)
                    .font(Typo.font(.semibold, 19 * scale, .title3))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, background ? 12 : 0)
                    .padding(.vertical, background ? 6 : 0)
                    .background {
                        if background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.55)) }
                    }
                    .padding(.horizontal, 28)
            }
        }
    }
}

/// أثر الضغط مرتين على الطرف
/// تقديم/رجوع مثل يوتيوب: قوس شفاف على طرف الشاشة وأسهم صغيرة وعدد الثواني، بدون زر
struct SeekRipple: View {
    let side: PlayerHost.RippleSide
    let seconds: Int
    let tick: Int

    var body: some View {
        GeometryReader { geo in
            let forward = side == .forward
            let w = geo.size.width * PlayerLogic.rippleWidthFraction
            ZStack {
                // القوس: دائرة كبيرة طالعة برا الطرف، يبان منها نص قوس
                Ellipse()
                    .fill(.white.opacity(0.10))
                    .frame(width: w * 2, height: geo.size.height * 1.3)
                    .position(x: forward ? geo.size.width : 0, y: geo.size.height / 2)

                VStack(spacing: 6) {
                    Chevrons(forward: forward, tick: tick)
                    Text(L("%@ ثانية", "\(seconds)"))
                        .font(Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
                .frame(width: w)
                .position(x: forward ? geo.size.width - w * 0.5 : w * 0.5, y: geo.size.height / 2)
            }
            .clipped()
        }
        .ignoresSafeArea()
        .environment(\.layoutDirection, .leftToRight)
        .transition(.opacity)
    }
}

/// ثلاث أسهم صغيرة تنوّر وحدة ورا الثانية مع كل ضغطة
private struct Chevrons: View {
    let forward: Bool
    let tick: Int
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                let idx = forward ? i : 2 - i
                Image(systemName: "play.fill")
                    .scaleEffect(x: forward ? 1 : -1)
                    .font(.system(size: 11, weight: .bold))
                    .opacity(phase == idx ? 1 : 0.35)
            }
        }
        .foregroundStyle(.white)
        .task(id: tick) {
            for step in 0..<3 {
                withAnimation(.easeOut(duration: 0.12)) { phase = step }
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }
}

/// زر AirPlay
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Palette.accent)
        v.prioritizesVideoDevices = true
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
