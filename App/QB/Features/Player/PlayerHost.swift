import SwiftUI
import AVKit
import UIKit
import QBCore

/// المشغّل بملء الشاشة: الفيديو، الترجمة، الإيماءات، وأدوات التحكم الزجاجية
struct PlayerHost: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    private var player: PlayerModel { app.player }

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dragOffset: CGFloat = 0
    /// البطاقة تلحق إصبعك يمين ويسار بعد (مثل صفحة التفاصيل)
    @State private var dragX: CGFloat = 0
    /// عرض الشريط فوق (عشان نعرف هل العنوان يلحق مكان جنب الأزرار)
    @State private var topBarWidth: CGFloat = 0
    /// السحب لتحت خلص وقاعد نطلع: نوقف أي إيماءة ثانية لين تختفي الشاشة
    @State private var leaving = false
    /// البطاقة تختفي وهي نازلة (قبل لفّة الشاشة للطول)
    @State private var dismissFade = false
    /// طبقة الفيديو نفسها مخفية (بعد ما تختفي البطاقة وقبل ما تلف الشاشة للطول)
    @State private var surfaceHidden = false
    @State private var seekPreview: Double?
    @State private var seekStart: Double = 0
    @State private var dragAxis: Axis?
    /// رجوع البطاقة بعد سحب ما كمّل: حركة وحدة ناعمة تنحسب كل إطار من نفس الإزاحة
    /// (الزوايا والقص والتصغير والظل وتعتيم الصفحة اللي ورا كلها تمشي معها بنفس اللحظة)
    @State private var cardReturn = CardReturnDriver()
    /// لو مسكت البطاقة وهي راجعة: تكمّل من مكانها بدل ما تنط
    @State private var grabY: CGFloat = 0
    @State private var grabX: CGFloat = 0
    /// كم سحب الإصبع قبل ما يبدأ السحب فعلًا (حد البداية)، عشان البطاقة ما تنط هالمسافة أول ما تتحرك
    @State private var dragSlop: CGSize = .zero
    /// يرجع false لحاله لو انلغى السحب (النظام أو زر ثاني أخذ اللمسة)، فما يعلق شي على الشاشة
    @GestureState private var dragging = false
    /// السحب العمودي الحالي: صوت، إضاءة، أو خروج
    @State private var verticalKind: PlayerLogic.VerticalDrag = .dismiss
    @State private var levels = SideLevels()
    /// شكل الزر يتغيّر أول ما تضغط، قبل ما يرد المشغّل
    @State private var optimisticPlaying: Bool?
    @State private var playTaps = 0
    @State private var ripple: RippleSide?
    /// كم ثانية تجمّعت بالضغطات المتتالية على نفس الطرف (10، 20، 30…)
    @State private var rippleSeconds = 10
    @State private var rippleTick = 0
    @State private var rippleTask: Task<Void, Never>?
    /// مؤشر التقديم بالضغطتين (+10 / -10 ويتجمّع): يطلع على الشريط عند رأس التشغيل، ويختفي بعد ثانية من آخر ضغطة
    @State private var seekPeek: Int?
    @State private var seekPeekTask: Task<Void, Never>?
    @State private var sheet: PlayerSheet?
    /// القرص بالإصبعين: مقداره الحي، ويرجع 1 بسبرنق لما تشيل أصابعك أو ينلغي
    @GestureState(resetTransaction: Transaction(animation: PlayerZoom.spring))
    private var pinchMagnification: CGFloat = 1
    @GestureState private var pinching = false
    /// القرص بدأ وسط سحب: السحب ينلغي (لا تقديم ولا صوت ولا خروج)
    @State private var dragVoided = false
    /// الشارة الصغيرة "تكبير لملء الشاشة" / "الحجم الأصلي"
    @State private var zoomPill: Bool?
    @State private var zoomPillTick = 0

    enum RippleSide { case back, forward }

    enum PlayerSheet: String, Identifiable {
        case tracks, sources, similar, speed
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geo in
            let screen = fullScreenSize(geo)
            // يمين ويسار ما يتحرك إلا والبطاقة نازلة فعلًا بسحب لتحت. غير كذا مقفول على الصفر،
            // فما يقدر أي سحب ينلغي (مثل التنقّل بين التطبيقات من شريط الشاشة) يخلّي المشغّل مزحوح
            let dismiss = DismissCard(offset: dragOffset, x: dragOffset > 0 ? dragX : 0, screen: screen)
            let cardAnchor = DismissCard.anchor(size: geo.size, insets: geo.safeAreaInsets, screen: screen)
            ZStack {
                Color.black.ignoresSafeArea()

                // التكبير مثل يوتيوب: الصورة تكبر مع أصابعك 1:1، ولما تشيلها تستقر بسبرنق على "الحجم الأصلي"
                // أو "ملء الشاشة". تحويل رسم بس داخل منظر الفيديو (نفس النسبة بالطول والعرض، من النص، ومقصوص
                // على الشاشة وعلى زوايا البطاقة)، فمقاس المشغّل ما يتغيّر وما ينعاد بناء الصورة بأي مشغّل
                let fillScale = PlayerZoom.fillScale(screen: screen, video: player.videoSize)
                let zoom = PlayerZoom.live(base: player.videoFill ? fillScale : 1, magnification: pinchMagnification, fill: fillScale)
                EngineSurface(surface: player.surface, zoom: zoom, cornerRadius: dismiss.cornerRadius, hidden: surfaceHidden)
                    .ignoresSafeArea()
                    .opacity(player.surface == nil ? 0 : 1)

                // نقطة وحدة مقصوصة وما ترسم شي، بالزاوية فوق (مو بنص الشاشة حيث زر التشغيل)
                HiddenVolumeView(levels: levels)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                gestureLayer(size: geo.size, screen: screen)

                // الترجمة تلحق الصورة نفسها: بالطول تحت الفيديو اللي بالنص، وبالعرض أو بعد التكبير فوق حافة الشاشة
                let subs = PlayerLogic.subtitlePlacement(
                    screen: screen, video: player.videoSize, fill: player.videoFill,
                    safeBottom: stableSafeBottom(geo, screen: screen), controlsVisible: controlsVisible)
                SubtitleOverlay(text: player.cueText, scale: app.subtitleSize * Double(subs.scale), background: app.subtitleBackground)
                    .padding(.horizontal, max(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing))
                    .padding(.bottom, subs.bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .animation(Motion.standard, value: subs)
                    .allowsHitTesting(false)

                if let ripple {
                    SeekRipple(side: ripple, seconds: rippleSeconds, tick: rippleTick)
                        .allowsHitTesting(false)
                }

                // الضغطتين والأدوات مخفية: شريط التقدّم يطلع لحاله تحت مع "+10" عند رأس التشغيل
                if let seekPeek, !controlsVisible {
                    SeekPeekBar(elapsed: player.elapsed, duration: player.duration, label: SeekBadge.label(seekPeek))
                        .frame(height: 44)
                        .padding(.horizontal, 16 + max(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing))
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea()
                        .opacity(dismiss.controlsOpacity)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // وقت السحب للتقديم بس: فوق بعيد عن أزرار التشغيل، ويختفي أول ما تشيل إصبعك
                if let seekPreview, dragging {
                    Text("\(TimeFormat.clock(seekPreview)) / \(TimeFormat.clock(player.duration ?? 0))")
                        .font(Typo.time)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(Glass.player, in: .capsule)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 70 + topBarExtra)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // كل قطعة كبيرة تنبني لحالها (StackSplit): لو تنبني الشاشة كلها بنفس الخطوة تخلص ذاكرة
                // الخيط الرئيسي (1 ميغا) والتطبيق يطلع أول ما ينفتح المشغّل. هذا سبب الطلعة في نسخة 12
                StackSplit { resumeHint }
                    .animation(Motion.pop, value: player.resumedFrom != nil && player.elapsed > 0)

                StackSplit { zoomHint }

                StackSplit { loadingOrError }

                SideLevelPill(levels: levels)
                    .ignoresSafeArea()

                if controlsVisible {
                    StackSplit { controls }
                        // الأزرار تختفي بنعومة مع السحب لتحت بدل ما تبقى فوق الصورة
                        .opacity(dismiss.controlsOpacity)
                        .transition(.opacity)
                }

                StackSplit { nextUpCard }
                    .opacity(dismiss.controlsOpacity)
            }
            .environment(\.layoutDirection, layoutDirection)
            // السحب لتحت مثل بطاقات iOS: الزوايا تتدوّر لين توصل لزوايا الجهاز، والبطاقة تصغر شوي وتلحق الإصبع.
            // كله تحويل رسم بس (بدون تغيير مقاس أو مكان أي view)، فالفيديو يكمّل بنفس مقاسه وما ينعاد بناؤه
            .mask {
                RoundedRectangle(cornerRadius: dismiss.cornerRadius, style: .continuous)
                    .ignoresSafeArea()
            }
            // ظل ناعم تحت البطاقة وقت السحب بس (شكل ثابت، ما يكلّف شي على الفيديو)
            .background {
                if dragOffset > 0 || leaving {
                    RoundedRectangle(cornerRadius: dismiss.cornerRadius, style: .continuous)
                        .fill(.black)
                        .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                        // يطلع ويختفي بالتدريج مع الإزاحة نفسها (ما ينشال فجأة وقت الرجوع)
                        .opacity(dismiss.controlsOpacityInverse)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.identity)
                }
            }
            .visualEffect { content, _ in
                content
                    // من نص الشاشة الحقيقي (مو نص المنطقة الآمنة): بالعرض الحواف الآمنة مو متساوية فوق وتحت،
                    // ومن نصها كانت البطاقة تصغر مزحوحة عن مكانها
                    .scaleEffect(dismiss.scale, anchor: cardAnchor)
                    .offset(x: dismiss.x, y: dismiss.offset)
            }
            // الإزاحة يمين ويسار بإحداثيات الشاشة نفسها (نفس اتجاه إصبعك بالعربي والإنجليزي)
            .environment(\.layoutDirection, .leftToRight)
            .opacity(leaving && dismissFade ? 0 : 1)
            .allowsHitTesting(!leaving)
            .onAppear { player.setZoomViewport(screen) }
            .onChange(of: screen) { _, size in player.setZoomViewport(size) }
            .onChange(of: dragOffset) { _, d in player.dismissProgress = DismissCard(offset: d, x: 0, screen: screen).progress }
        }
        // خلفية الشاشة شفافة: لما تسحب لتحت تشوف الصفحة اللي تحت مثل ما هي، وما تنعاد ولا تنبني من جديد
        .presentationBackground(.clear)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            scheduleHide()
            player.coverAppeared()
            let model = player
            levels.onSoftwareVolume = { [weak model] v in model?.setSoftwareVolume(v) }
            levels.startObserving()
        }
        .onDisappear {
            cardReturn.stop()
            levels.playerClosed()
            player.dismissProgress = 0
        }
        .onChange(of: scenePhase) { _, phase in
            resetInteractiveState()
            switch phase {
            case .active:
                levels.reapplyBrightness()
                levels.startObserving()
            case .background:
                levels.restoreBrightness()
                levels.stopObserving()
            default:
                break
            }
        }
        .onChange(of: pinching) { _, active in
            if active {
                voidDrag()
            } else if !dragging {
                dragVoided = false
            }
        }
        .onChange(of: dragging) { _, active in
            // السحب انتهى أو انلغى بدون onEnded: ننظّف كل شي
            guard !active else { return }
            Task {
                // نعطي onEnded فرصة يخلّص (يقدّم أو يسكّر) قبل ما ننظّف
                try? await Task.sleep(for: .milliseconds(150))
                guard !dragging else { return }
                if !pinching { dragVoided = false }
                if seekPreview != nil { seekPreview = nil }
                if verticalKind != .dismiss { levels.end(); verticalKind = .dismiss }
                // انلغى بدون onEnded والبطاقة نازلة: ترجع بنفس الحركة الناعمة. لو هي أصلًا راجعة نخليها تكمّل
                // (والدوران يرجع مسموح بس بعد ما توصل مكانها)
                if !leaving, !cardReturn.isRunning {
                    if dragOffset != 0 || dragX != 0 { returnCard(velocity: 0) } else { OrientationLock.releaseHold() }
                }
                dragAxis = nil
            }
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

    private func gestureLayer(size: CGSize, screen: CGSize) -> some View {
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
                // إيماءة السحب تقيس على الشاشة نفسها، مو على البطاقة اللي هي تحرّكها. قبل كانت تقيس على البطاقة،
                // فالإزاحة تتأرجح كل إطار بين مكان إصبعك والصفر، وتطلع صورتين فوق بعض وكل شي يتشوّه
                DragGesture(minimumDistance: 14, coordinateSpace: .global)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { v in
                        // إصبعين يقرصون: هذا تكبير مو سحب
                        guard !pinching, !dragVoided else { return }
                        // يبدأ من شريط الشاشة تحت: هذا سحب النظام (الرئيسية والتنقّل بين التطبيقات)، مو لنا
                        if dragAxis == nil, v.startLocation.y > screen.height - Self.homeIndicatorZone {
                            dragVoided = true
                            return
                        }
                        if dragAxis == nil {
                            dragAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                            seekStart = player.elapsed
                            dragSlop = v.translation
                            grabY = 0
                            grabX = 0
                            if dragAxis == .vertical {
                                verticalKind = PlayerLogic.verticalDrag(startX: v.startLocation.x, startY: v.startLocation.y, size: size)
                                switch verticalKind {
                                case .volume: levels.begin(.volume)
                                case .brightness: levels.begin(.brightness)
                                case .dismiss:
                                    // مسكتها وهي راجعة: نوقف الرجوع وتكمّل من نفس مكانها تحت إصبعك
                                    if cardReturn.isRunning {
                                        cardReturn.stop()
                                        grabY = dragOffset
                                        grabX = dragX
                                    }
                                    // وقت السحب لتحت الشاشة ما تلف (لو مال الجوال)، عشان البطاقة ما تطلع بالعرض فوق صفحة بالطول
                                    OrientationLock.holdCurrent()
                                }
                            }
                        }
                        switch dragAxis {
                        case .horizontal:
                            guard player.duration != nil else { return }
                            seekPreview = SeekMath.target(start: seekStart, dx: v.translation.width, width: size.width, duration: player.duration)
                        case .vertical:
                            if verticalKind == .dismiss {
                                // من لحظة ما يبدأ السحب (مو من أول لمسة)، فالبطاقة تبدأ من مكانها بدون نطّة
                                let down = max(0, grabY + v.translation.height - max(0, dragSlop.height))
                                dragOffset = down
                                // يمين ويسار: يلحق الإصبع، أخف شوي من فوق وتحت. ما يبدأ إلا مع النزول لتحت
                                // (يدخل بالتدريج أول 24 نقطة عشان ما ينط)، وسحب لفوق أو على الجنب بس يبقى صفر
                                let side = (v.translation.width - dragSlop.width) * 0.85 * min(down / 24, 1)
                                dragX = down > 0 ? grabX * min(down / max(grabY, 1), 1) + side : 0
                            } else {
                                levels.change(dy: v.translation.height, height: size.height)
                            }
                        case nil:
                            break
                        }
                    }
                    .onEnded { v in
                        defer { dragAxis = nil }
                        if dragVoided || pinching {
                            dragVoided = pinching
                            return
                        }
                        if dragAxis == .horizontal, let target = seekPreview {
                            player.seek(to: target)
                            seekPreview = nil
                            Haptics.tap()
                            return
                        }
                        if dragAxis == .vertical, verticalKind != .dismiss {
                            levels.end()
                            verticalKind = .dismiss
                            return
                        }
                        if dragAxis == .vertical {
                            if PlayerLogic.swipeDismisses(translation: v.translation.height, predicted: v.predictedEndTranslation.height) {
                                // نكمّل الحركة لتحت بنفس سرعة إصبعك لين تطلع من الشاشة، وبعدين نشيلها بدون حركة ثانية
                                cardReturn.stop()
                                leaving = true
                                let velocity = max(0, (v.predictedEndTranslation.height - v.translation.height) * 4)
                                // بالعرض الشاشة لازم تلف للطول قبل ما تنقفل: نخفي البطاقة كلها أول عشان اللفّة ما تبان عليها
                                let landscape = size.width > size.height
                                // نفس محرّك الإطارات اللي يرجّع البطاقة: كل إطار قيمة وحدة بدون حركة SwiftUI،
                                // فالصورة وطبقتها والقص يتحدّثون مع بعض بنفس الإطار (ما فيه حركة UIKit تتسابق معها)
                                cardReturn.start(offset: dragOffset, x: dragX, velocity: velocity,
                                                 target: DismissCard.offscreen(size)) { y, x in
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    withTransaction(t) { dragOffset = y; dragX = x }
                                } done: {}
                                withAnimation(.easeIn(duration: landscape ? 0.2 : 0.28)) { dismissFade = true }
                                Task {
                                    try? await Task.sleep(for: .milliseconds(landscape ? 220 : 300))
                                    // قبل لفّة الشاشة للطول: نخفي طبقة الفيديو نفسها، فما تطلع بطاقة بالعرض فوق صفحة بالطول
                                    surfaceHidden = true
                                    player.minimize(animated: false)
                                }
                            } else {
                                // يرجع بحركة وحدة ناعمة بنفس سرعة إصبعك، بدون نطّة ولا تعدّي لفوق
                                returnCard(velocity: v.velocity.height)
                            }
                        }
                    }
            )
            // التكبير بالإصبع مثل يوتيوب: تفتح أصابعك يملّي الشاشة، تضمّها يرجع للحجم الأصلي
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.02)
                    .updating($pinchMagnification) { v, state, _ in state = v.magnification }
                    .updating($pinching) { _, state, _ in state = true }
                    .onEnded { v in
                        guard !leaving, player.errorMessage == nil else { return }
                        let fillScale = PlayerZoom.fillScale(screen: screen, video: player.videoSize)
                        // الفيديو أصلًا بنفس نسبة الشاشة: ما فيه شي يتكبّر
                        guard PlayerZoom.canZoom(fillScale) else { return }
                        let target = PlayerZoom.decide(magnification: v.magnification, filled: player.videoFill, fill: fillScale)
                        setZoom(target)
                    }
            )
    }

    /// منطقة شريط الرئيسية تحت: أي سحب يبدأ فيها نخليه للنظام
    static let homeIndicatorZone: CGFloat = 30

    /// الحافة الآمنة تحت للترجمة: حافة النافذة نفسها، مو حافة المنظر اللي تتغيّر وقت الدوران والرجوع من الخلفية
    /// والسحب لتحت (كانت تصير صفر لحظات فتنزل الترجمة لتحت)
    private func stableSafeBottom(_ geo: GeometryProxy, screen: CGSize) -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let fromWindow = window.map { w in
            // النافذة بنفس اتجاه الشاشة الحالي بس
            (w.bounds.width > w.bounds.height) == (screen.width > screen.height) ? w.safeAreaInsets.bottom : 0
        } ?? 0
        return max(geo.safeAreaInsets.bottom, fromWindow)
    }

    /// مقاس الشاشة كامل مع الحواف الآمنة (الفيديو يغطيها كلها)
    private func fullScreenSize(_ geo: GeometryProxy) -> CGSize {
        let i = geo.safeAreaInsets
        return CGSize(width: geo.size.width + i.leading + i.trailing, height: geo.size.height + i.top + i.bottom)
    }

    /// القرص بدأ والسحب شغّال: نرجّع كل شي غيّره السحب بدون ما ننفّذه
    private func voidDrag() {
        dragVoided = true
        if seekPreview != nil { seekPreview = nil }
        if verticalKind != .dismiss { levels.end(); verticalKind = .dismiss }
        if dragOffset != 0 || dragX != 0, !leaving, !cardReturn.isRunning { returnCard(velocity: 0) }
        dragAxis = nil
    }

    /// البطاقة ترجع مكانها بعد سحب ما كمّل. نحسب الإزاحة بأنفسنا كل إطار (120Hz) بسبرنق مخمّد بالضبط:
    /// بدون نطّة وبدون ما تعدّي فوق مكانها، ويبدأ بنفس سرعة إصبعك. كل شي مربوط بالإزاحة (القص على الزوايا
    /// بطبقة الفيديو، الزوايا، التصغير، الظل، الأزرار، الصفحة اللي ورا) يتحدّث بنفس الإطار مثل وقت السحب بالضبط،
    /// فما فيه حركة SwiftUI وحركة UIKit تتسابق. والدوران ما يرجع مسموح إلا بعد ما توصل مكانها
    private func returnCard(velocity: CGFloat) {
        guard !leaving else { return }
        cardReturn.start(offset: dragOffset, x: dragX, velocity: velocity) { y, x in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                dragOffset = y
                dragX = x
            }
        } done: {
            OrientationLock.releaseHold()
        }
    }

    /// التطبيق راح للخلفية أو رجع أو انفتح مركز التحكم: أي سحب كان شغّال انلغى من النظام،
    /// فنرجّع البطاقة لمكانها كامل فورًا (بدون حركة) ونمسح كل شي بدأه السحب
    private func resetInteractiveState() {
        guard !leaving else { return }
        cardReturn.stop()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            dragOffset = 0
            dragX = 0
        }
        if seekPreview != nil { seekPreview = nil }
        if verticalKind != .dismiss { levels.end(); verticalKind = .dismiss }
        dragAxis = nil
        dragVoided = pinching
        OrientationLock.releaseHold()
    }

    private func setZoom(_ fill: Bool) {
        let changed = fill != player.videoFill
        // نفس السبرنق اللي يرجّع القرص، فالصورة تكمّل من مكان أصابعك لمكانها الأخير بدون نطّة
        withAnimation(PlayerZoom.spring) { player.setVideoFill(fill) }
        guard changed else { return }
        Haptics.tap()
        zoomPillTick += 1
        let token = zoomPillTick
        withAnimation(Motion.pop) { zoomPill = fill }
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            guard zoomPillTick == token else { return }
            withAnimation(.easeOut(duration: 0.35)) { zoomPill = nil }
        }
    }

    private func flash(_ side: RippleSide) {
        rippleTask?.cancel()
        rippleSeconds = PlayerLogic.nextSeekBurst(previous: ripple == side ? rippleSeconds : nil)
        rippleTick += 1
        // نفس المجموع اللي بالقوس: +10 +20 +30 ... أو -10 -20 ...
        seekPeekTask?.cancel()
        let signed = side == .forward ? rippleSeconds : -rippleSeconds
        if seekPeek == nil {
            withAnimation(.easeOut(duration: 0.18)) { seekPeek = signed }
        } else {
            seekPeek = signed
        }
        seekPeekTask = Task {
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { seekPeek = nil }
        }
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
                StackSplit { topBar }
                Spacer()
                StackSplit { bottomBar }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // أزرار الوسط بنص الفيديو بالضبط (الفيديو نفسه يغطي الشاشة كلها)، مو بين الشريطين
            StackSplit { transport }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
    }

    /// الشريط فوق: 6 أزرار. لو ما بقى للعنوان مكان يكفي (بالطول غالبًا) ينزل تحت الأزرار بدل ما ينقص لحرفين،
    /// والأزرار نفسها تبقى بنفس مكانها وترتيبها
    private var titleFitsInRow: Bool {
        guard topBarWidth > 0 else { return true }
        let buttons: CGFloat = 6
        return topBarWidth - buttons * 42 - buttons * 12 - 8 >= 110
    }

    /// العنوان نزل تحت الأزرار: اللي تحت الشريط ينزل معه عشان ما يغطيه
    private var topBarExtra: CGFloat { titleFitsInRow ? 0 : 44 }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.context?.title ?? "").font(Typo.headline).lineLimit(1)
            if let sub = player.context?.subtitle {
                Text(sub).font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                GlassCircleButton(systemImage: "chevron.down", size: 42, label: L("تصغير"), clear: true) { player.minimize() }
                if titleFitsInRow { titleBlock }
                Spacer(minLength: 8)
                reloadButton
                // AirPlay يشتغل مع المشغّلين: مع المشغّل الأصلي يروح الفيديو والصوت للتلفزيون،
                // ومع VLC يروح الصوت للجهاز اللي تختاره (سماعة أو تلفزيون) والصورة تبقى بالجوال
                AirPlayButton()
                    .frame(width: 42, height: 42)
                    .glassEffect(Glass.player.interactive(), in: .circle)
                    .accessibilityLabel(L("AirPlay"))
                GlassCircleButton(systemImage: "pip.enter", size: 42, label: L("صورة داخل صورة"), clear: true) {
                    touch { if player.supportsPiP { player.startPiP() } }
                }
                .disabled(!player.settledSupportsPiP)
                .opacity(player.settledSupportsPiP ? 1 : 0.35)
                GlassCircleButton(systemImage: "rotate.right", size: 42, label: L("تدوير الشاشة"), clear: true) { touch { player.toggleOrientation() } }
                GlassCircleButton(systemImage: "xmark", size: 42, label: L("إغلاق"), clear: true) { player.close() }
            }
            if !titleFitsInRow {
                titleBlock.padding(.horizontal, 4)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { topBarWidth = $0 }
    }

    /// يعيد تحميل نفس المصدر من نفس الثانية بدون ما يسكّر المشغّل (نفس الصوت والترجمة والسرعة)
    private var reloadButton: some View {
        Button {
            Haptics.tap()
            touch { player.reloadInPlace() }
        } label: {
            ZStack {
                if player.isReloading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 42 * 0.4, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.player.interactive(), in: .circle)
        .disabled(player.isReloading || player.source == nil)
        .accessibilityLabel(L("إعادة تحميل"))
    }

    /// بالنص زر التشغيل/الإيقاف بس. التقديم والرجوع بضغطتين على طرف الشاشة مثل يوتيوب
    private var transport: some View {
        Button {
            // الشكل يتغيّر فورًا والأمر يروح للمشغّل على طول
            let next = !(optimisticPlaying ?? player.isPlaying)
            withAnimation(.snappy(duration: 0.18)) { optimisticPlaying = next }
            playTaps += 1
            Haptics.tap()
            touch { player.togglePlay() }
            let token = playTaps
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if playTaps == token { optimisticPlaying = nil }
            }
        } label: {
            ZStack {
                // مؤشر التحميل الوحيد بالشاشة يكون هنا داخل الزر
                if showsSpinner && optimisticPlaying == nil {
                    ProgressView().controlSize(.regular).tint(.white)
                } else {
                    Image(systemName: shownPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: PlayerLogic.Transport.play * 0.4, weight: .bold))
                        // المثلث وزنه على اليسار، نزحزحه شوي عشان يبان بالنص
                        .offset(x: shownPlaying ? 0 : PlayerLogic.Transport.play * 0.04)
                        .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                        .symbolEffect(.bounce.down, options: .speed(1.6), value: playTaps)
                }
            }
            .foregroundStyle(.white)
            .frame(width: PlayerLogic.Transport.play, height: PlayerLogic.Transport.play)
            .contentShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .glassEffect(Glass.player.interactive(), in: .circle)
        .accessibilityLabel(shownPlaying ? L("إيقاف مؤقت") : L("تشغيل"))
        .accessibilityAction(named: L("رجوع 10 ثواني")) { player.skip(-10) }
        .accessibilityAction(named: L("تقديم 10 ثواني")) { player.skip(10) }
        .accessibilityAction(named: player.videoFill ? L("الحجم الأصلي") : L("تكبير لملء الشاشة")) { setZoom(!player.videoFill) }
        .environment(\.layoutDirection, .leftToRight)
        .opacity(player.errorMessage == nil ? 0.92 : 0)
    }

    private var shownPlaying: Bool { optimisticPlaying ?? player.isPlaying }

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
                    GlassButton(title: L("تخطّي المقدمة"), systemImage: "forward.fill", clear: true) {
                        touch { player.skip(Double(app.skipIntroSeconds)) }
                    }
                    .transition(.opacity)
                }
                Spacer()
                if player.context?.video != nil, player.nextUp != nil || player.context?.meta != nil {
                    GlassButton(title: L("الحلقة الجاية"), systemImage: "forward.end.fill", clear: true) {
                        touch { player.playNext() }
                    }
                }
            }
            Scrubber(elapsed: player.elapsed, duration: player.duration, live: player.isLive,
                     badge: seekPeek.map(SeekBadge.label)) { t in
                player.seek(to: t)
                scheduleHide()
            } onScrubbing: { scrubbing in
                if scrubbing { hideTask?.cancel() } else { scheduleHide() }
            }
            // الأزرار تحت كلها تبان كاملة دايم: صف واحد عادي، ولو ما وسع صف أصغر شوي، ولو ما وسع صفّين.
            // ما فيه تمرير ولا زر مقصوص على الطرف
            ViewThatFits(in: .horizontal) {
                StackSplit { HStack(spacing: 10) { chipSet(compact: false) } }
                StackSplit { HStack(spacing: 6) { chipSet(compact: true) } }
                StackSplit { VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        tracksChip(compact: false)
                        sourcesChip(compact: false)
                        speedChip(compact: false)
                    }
                    HStack(spacing: 8) {
                        similarChip(compact: false)
                        engineMenu(compact: false)
                    }
                } }
                StackSplit { VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        tracksChip(compact: true)
                        sourcesChip(compact: true)
                        speedChip(compact: true)
                    }
                    HStack(spacing: 6) {
                        similarChip(compact: true)
                        engineMenu(compact: true)
                    }
                } }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func chipSet(compact: Bool) -> some View {
        tracksChip(compact: compact)
        sourcesChip(compact: compact)
        speedChip(compact: compact)
        similarChip(compact: compact)
        engineMenu(compact: compact)
    }

    private func tracksChip(compact: Bool) -> some View {
        pill(L("الترجمة والصوت"), "captions.bubble.fill", compact: compact) { sheet = .tracks }
    }

    private func sourcesChip(compact: Bool) -> some View {
        pill(L("المصادر"), "rectangle.stack.fill", compact: compact) { sheet = .sources }
    }

    private func speedChip(compact: Bool) -> some View {
        pill(rateLabel, "gauge.with.dots.needle.67percent", reserve: [L("السرعة"), "1.75x", "0.25x"], compact: compact) { sheet = .speed }
    }

    /// دايم موجود؛ باهت لين توصل العناوين المشابهة (ما يطلع شي فجأة ولا يتحرك شي)
    private func similarChip(compact: Bool) -> some View {
        pill(L("مشابه"), "square.grid.2x2.fill", compact: compact) { sheet = .similar }
            .disabled(player.similar.isEmpty)
            .opacity(player.similar.isEmpty ? 0.35 : 1)
    }

    private var rateLabel: String {
        player.rate == 1 ? L("السرعة") : String(format: "%.2gx", player.rate)
    }

    /// Engine picker (native / VLC): always in the same place with the same width; the name only changes
    /// once an engine actually plays, so it doesn't flicker while loading
    private func engineMenu(compact: Bool) -> some View {
        let current = player.settledEngineName.isEmpty ? player.engineName : player.settledEngineName
        let isVLC = current == "VLC"
        return Menu {
            Button {
                player.chooseEngine(native: true)
            } label: {
                Label(L("الأصلي"), systemImage: !isVLC ? "checkmark" : "apple.logo")
            }
            Button {
                player.chooseEngine(native: false)
            } label: {
                Label("VLC", systemImage: isVLC ? "checkmark" : "play.rectangle")
            }
        } label: {
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: "cpu").font(.system(size: compact ? 11 : 13, weight: .semibold))
                ZStack {
                    Text(L("الأصلي")).hidden()
                    Text(verbatim: "VLC").hidden()
                    Text(isVLC ? "VLC" : L("الأصلي"))
                }
                .font(compact ? Typo.font(.medium, 11, .caption2) : Typo.caption).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 34 : 36)
            .glassEffect(Glass.player.interactive(), in: .capsule)
        }
        .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
        .accessibilityLabel(L("المشغّل"))
    }

    /// reserve: the label's width is the widest of these, so changing it (speed) never moves the chips after it
    private func pill(_ title: String, _ icon: String, reserve: [String] = [], compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            hideTask?.cancel()
            action()
        } label: {
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: icon).font(.system(size: compact ? 11 : 13, weight: .semibold))
                ZStack {
                    ForEach(reserve, id: \.self) { Text(verbatim: $0).hidden() }
                    Text(title)
                }
                .font(compact ? Typo.font(.medium, 11, .caption2) : Typo.caption).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 34 : 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.player.interactive(), in: .capsule)
    }

    // MARK: - التحميل والخطأ

    /// "كمّلنا من 1:24" مع زر "من البداية" تحت الشريط العلوي، يختفي بعد 6 ثواني
    @ViewBuilder
    private var resumeHint: some View {
        if let from = player.resumedFrom, player.errorMessage == nil, player.elapsed > 0 {
            HStack(spacing: 10) {
                Text(L("كمّلنا من %@", TimeFormat.clock(from))).font(Typo.caption).monospacedDigit()
                Button {
                    player.startOver()
                    Haptics.tap()
                } label: {
                    Text(L("من البداية")).font(Typo.font(.semibold, 13, .footnote)).foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 36)
            .glassEffect(Glass.player.interactive(), in: .capsule)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, controlsVisible ? 70 + topBarExtra : 24)
            .transition(.asymmetric(insertion: .scale(scale: 0.86).combined(with: .opacity), removal: .opacity))
            .task(id: from) {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(Motion.standard) { player.dismissResumeHint() }
            }
        }
    }

    /// شارة زجاجية صغيرة فوق بالنص (تحت الشريط العلوي لو ظاهر)، ما تغطي زر التشغيل ولا أي زر، وتختفي لحالها
    @ViewBuilder
    private var zoomHint: some View {
        if let fill = zoomPill {
            let resumeShown = player.resumedFrom != nil && player.errorMessage == nil && player.elapsed > 0
            HStack(spacing: 7) {
                Image(systemName: fill ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(fill ? L("مكبّر لملء الشاشة") : L("الحجم الأصلي"))
                    .font(Typo.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 34)
            .background(.black.opacity(0.25), in: .capsule)
            .glassEffect(Glass.player, in: .capsule)
            // فوق بالنص تحت منطقة العنوان (مكان "كمّلنا من" وتحتها لو هي ظاهرة)، بعيد عن زر التشغيل
            // وكل الأزرار بالطول والعرض. تنزل وتطلع مع ظهور الأزرار بنفس حركتها
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, (controlsVisible ? 70 + topBarExtra : 24) + (resumeShown ? 44 : 0))
            .allowsHitTesting(false)
            .transition(.asymmetric(insertion: .scale(scale: 0.86).combined(with: .opacity), removal: .opacity))
            .id(fill)
        }
    }

    @ViewBuilder
    private var loadingOrError: some View {
        if let message = player.errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(Palette.accent)
                Text(message).font(Typo.title).multilineTextAlignment(.center)
                Text(L("جرّب مرة ثانية أو اختر مصدر ثاني")).font(Typo.info).foregroundStyle(.secondary)
                if let detail = player.failureDetail {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                        Button {
                            UIPasteboard.general.string = player.failureReport
                            Haptics.tap()
                            app.showToast(L("انتسخت التفاصيل"))
                        } label: {
                            Label(L("نسخ التفاصيل"), systemImage: "doc.on.doc").font(Typo.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                    }
                    .padding(12)
                    .frame(maxWidth: 320)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                HStack(spacing: 12) {
                    GlassButton(title: L("إعادة المحاولة"), systemImage: "arrow.clockwise", width: ButtonMetrics.pairWidth, clear: true) { player.retry() }
                    // دايمًا شغّال: لو ما بقى مصدر ما جرّبناه، يفتح قائمة المصادر
                    PrimaryButton(title: L("جرّب مصدر ثاني"), systemImage: "arrow.triangle.2.circlepath", width: ButtonMetrics.pairWidth, clear: true) {
                        if player.canTryAnother { player.tryAnotherSource() } else { sheet = .sources }
                    }
                }
                GlassButton(title: L("المصادر"), systemImage: "rectangle.stack.fill", width: ButtonMetrics.pairWidth, clear: true) { sheet = .sources }
            }
            .foregroundStyle(.white)
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .padding(24)
        } else if (player.state == .loading || (player.isBuffering && player.elapsed < 1)) && !controlsVisible {
            // مؤشر واحد بس: داخل زر التشغيل لما الأدوات ظاهرة، وبنفس مكانه لما تختفي. ولا شي ثاني فوق الصورة
            // على صورة سودا الزجاج الشفاف ما يبان، فتحته دائرة غامقة وفوقها المؤشر بحجمه العادي
            ProgressView().controlSize(.regular).tint(.white)
                .frame(width: PlayerLogic.Transport.play, height: PlayerLogic.Transport.play)
                .background(.black.opacity(0.35), in: .circle)
                .glassEffect(Glass.player, in: .circle)
                .transition(.opacity)
                .allowsHitTesting(false)
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
                            PrimaryButton(title: player.nextCountdown.map { L("تشغيل خلال %@", "\($0)") } ?? L("تشغيل"), clear: true) {
                                player.playNext()
                            }
                            if player.nextCountdown != nil {
                                GlassButton(title: L("إلغاء"), clear: true) { player.cancelNext() }
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
    /// "+10" / "-10" فوق رأس التشغيل بعد الضغطتين
    var badge: String? = nil
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
                .overlay {
                    if let badge, dragValue == nil, total > 0 {
                        SeekBadge(text: badge)
                            .position(x: SeekBadge.centerX(geo.size.width * fraction, width: geo.size.width), y: -12)
                            .animation(.linear(duration: 0.2), value: fraction)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
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
/// ضغطة ناعمة: الزر يصغر شوي ويرجع بسبرنق سريع
struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(configuration.isPressed ? Motion.pressDown : Motion.pressRelease, value: configuration.isPressed)
    }
}

/// تقديم/رجوع مثل يوتيوب: قوس شفاف على طرف الشاشة وأسهم صغيرة وعدد الثواني، بدون زر
/// الحبة الذهبية "+10" / "-10" فوق رأس التشغيل
struct SeekBadge: View {
    let text: String
    static let minWidth: CGFloat = 46

    static func label(_ seconds: Int) -> String { seconds > 0 ? "+\(seconds)" : "\(seconds)" }

    /// نصها على رأس التشغيل، وما تطلع برا طرفي الشريط
    static func centerX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let half = minWidth / 2
        guard width > minWidth else { return width / 2 }
        return min(max(x, half), width - half)
    }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minWidth: Self.minWidth)
            .background(Palette.accent, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .environment(\.layoutDirection, .leftToRight)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.2), value: text)
            .accessibilityHidden(true)
    }
}

/// شريط تقدّم صغير يطلع لحاله وقت الضغطتين والأدوات مخفية: الجزء اللي انعرض بلون التطبيق،
/// والحبة على رأس التشغيل تمشي معه (الوقت ثابت على الهدف وقت التقديم، فما ترجع لورا)
struct SeekPeekBar: View {
    let elapsed: Double
    let duration: Double?
    let label: String

    var body: some View {
        GeometryReader { geo in
            let total = duration ?? 0
            let fraction = total > 0 ? min(max(elapsed / total, 0), 1) : 0
            let x = geo.size.width * fraction
            let barY = geo.size.height - 5
            ZStack(alignment: .topLeading) {
                Capsule().fill(.white.opacity(0.28))
                    .frame(width: geo.size.width, height: 4)
                    .position(x: geo.size.width / 2, y: barY)
                Capsule().fill(Palette.accent)
                    .frame(width: max(x, 0.01), height: 4)
                    .position(x: x / 2, y: barY)
                Circle().fill(Palette.accent)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(x: x, y: barY)
                    .opacity(total > 0 ? 1 : 0)
                SeekBadge(text: label)
                    .position(x: SeekBadge.centerX(x, width: geo.size.width), y: barY - 22)
                    .opacity(total > 0 ? 1 : 0)
            }
            .animation(.linear(duration: 0.2), value: fraction)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

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

/// يبني محتواه كعقدة SwiftUI مستقلة بخطوة لحالها، بدل ما ينبني داخل نفس استدعاء body الكبير.
/// أنواع SwiftUI مقاسها ما ينعرف إلا وقت التشغيل، فكل طبقة من الشاشة تنحجز على مكدّس الخيط الرئيسي (1 ميغا)
/// داخل استدعاء واحد. شاشة المشغّل كبرت لين خلّصت المكدّس وطلع التطبيق (EXC_BAD_ACCESS بمنطقة حماية المكدّس).
/// هنا كل قطعة تنحسب لما يطلبها SwiftUI بعد ما يرجع body الأب، فالمكدّس ما يتراكم.
struct StackSplit<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
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

/// التكبير بالقرص مثل يوتيوب: حالتين بس (الحجم الأصلي وملء الشاشة) وبينهم يلحق أصابعك
enum PlayerZoom {
    /// نفس السبرنق للاستقرار ولرجوع القرص، فما فيه نطّة بين الاثنين
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// كم لازم نكبّر الفيديو (وهو بالحجم الأصلي داخل الشاشة) عشان يملّي الشاشة كلها بدون أطراف سودا
    static func fillScale(screen: CGSize, video: CGSize) -> CGFloat {
        guard screen.width > 1, screen.height > 1, video.width > 1, video.height > 1 else { return 1 }
        let fit = min(screen.width / video.width, screen.height / video.height)
        let shown = CGSize(width: video.width * fit, height: video.height * fit)
        return max(1, max(screen.width / shown.width, screen.height / shown.height))
    }

    /// نسبة الفيديو قريبة من نسبة الشاشة (فرق أقل من 2%): ما فيه شي يتكبّر
    static func canZoom(_ fill: CGFloat) -> Bool { fill > 1.02 }

    /// المقدار وقت القرص: 1:1 مع الأصابع بين الحالتين، وبعدها مطاطي خفيف (ربع الزيادة) بدل ما يوقف فجأة
    static func live(base: CGFloat, magnification: CGFloat, fill: CGFloat) -> CGFloat {
        guard canZoom(fill) || magnification != 1 else { return 1 }
        let raw = base * magnification
        let hi = max(fill, 1)
        if raw > hi { return hi + (raw - hi) * 0.25 }
        if raw < 1 { return 1 - (1 - raw) * 0.25 }
        return raw
    }

    /// لما تشيل أصابعك: اتجاه القرص واضح؟ نروح له. غير كذا الأقرب للمقدار اللي وصلت له
    static func decide(magnification: CGFloat, filled: Bool, fill: CGFloat) -> Bool {
        if magnification > 1.04 { return true }
        if magnification < 0.96 { return false }
        let now = (filled ? fill : 1) * magnification
        return abs(now - fill) < abs(now - 1)
    }
}

/// شكل بطاقة المشغّل وقت السحب لتحت (مثل تطبيق Apple TV والصور):
/// تلحق الإصبع 1:1، تصغر شوي، وزواياها تتدوّر لين توصل لزوايا الشاشة
struct DismissCard {
    let offset: CGFloat
    var x: CGFloat = 0
    let screen: CGSize

    /// 0 مكانها، 1 نزلت كثير
    var progress: Double {
        guard screen.height > 0 else { return 0 }
        return Double(min(max(offset / (screen.height * 0.6), 0), 1))
    }

    /// تصغر مع النزول مثل صفحة التفاصيل (لين 62% تقريبًا)، بنفس النسبة بالطول والعرض فالجوانب تبقى كاملة ومتساوية
    var scale: CGFloat { 1 - 0.38 * CGFloat(progress) }

    /// الزوايا توصل لزوايا الجهاز بسرعة أول ما تبدأ تسحب
    var cornerRadius: CGFloat {
        guard offset > 0 else { return 0 }
        return Self.deviceCornerRadius * min(offset / 36, 1)
    }

    /// الأزرار تختفي خلال أول 70 نقطة
    var controlsOpacity: Double { Double(1 - min(max(offset, 0) / 70, 1)) }

    /// الظل يطلع بنفس سرعة اختفاء الأزرار
    var controlsOpacityInverse: Double { 1 - controlsOpacity }

    /// مسافة كافية تطلّع البطاقة من الشاشة حتى لو لفّت الشاشة بعدها
    static func offscreen(_ size: CGSize) -> CGFloat { max(size.width, size.height) + 160 }

    /// نص الشاشة كاملة بإحداثيات المحتوى (اللي يبدأ من الحافة الآمنة)
    static func anchor(size: CGSize, insets: EdgeInsets, screen: CGSize) -> UnitPoint {
        guard size.width > 1, size.height > 1 else { return .center }
        return UnitPoint(x: (screen.width / 2 - insets.leading) / size.width,
                         y: (screen.height / 2 - insets.top) / size.height)
    }

    /// رجوع بنطّة خفيفة (نفس إحساس الأزرار في التطبيق)
    static let springBack = Animation.spring(response: 0.36, dampingFraction: 0.74)

    /// نصف قطر زوايا شاشة الجهاز (ولو ما انعرف: قيمة قريبة من أجهزة آيفون الحديثة)
    static let deviceCornerRadius: CGFloat = {
        let key = ["Radius", "Corner", "display", "_"].reversed().joined()
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        if let screen, screen.responds(to: NSSelectorFromString(key)),
           let r = screen.value(forKey: key) as? CGFloat, r > 0 {
            return r
        }
        return 50
    }()
}

/// رجوع بطاقة المشغّل لمكانها: سبرنق مخمّد بالضبط (critically damped) ينحسب كل إطار من الشاشة نفسها.
/// الإزاحة: x(t) = (x0 + (v0 + ωx0)t)e^(−ωt). لو السرعة لفوق أكبر من ωx0 كانت بتعدّي مكانها، فنقصّها
/// عند هالحد: كذا ما تطلع فوق الصفر أبد وما فيه أي نطّة. اليمين واليسار يمشون بنفس النسبة، فالبطاقة ترجع بخط واحد
@MainActor
final class CardReturnDriver: NSObject {
    /// سرعة الرجوع (قريبة من ردّة الحركة القديمة 0.36 ثانية، بس بدون أي ارتداد)
    static let omega: CGFloat = 2 * .pi / 0.4

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var y0: CGFloat = 0
    private var x0: CGFloat = 0
    private var v0: CGFloat = 0
    /// وين توقف (0 = مكانها، أو تحت برا الشاشة وقت الخروج)
    private var target: CGFloat = 0
    private var onFrame: ((CGFloat, CGFloat) -> Void)?
    private var onDone: (() -> Void)?

    var isRunning: Bool { link != nil }

    /// velocity بالنقاط بالثانية (موجب = لتحت، بعيد عن المكان)
    func start(offset: CGFloat, x: CGFloat, velocity: CGFloat, target: CGFloat = 0,
               frame: @escaping (CGFloat, CGFloat) -> Void, done: @escaping () -> Void) {
        stop()
        let y = max(0, offset)
        self.target = target
        guard abs(y - target) > 0.5 else {
            frame(target, target == 0 ? 0 : x)
            done()
            return
        }
        // نحسب على المسافة الباقية للهدف
        y0 = y - target
        x0 = x
        let w = Self.omega
        let v = velocity.isFinite ? velocity : 0
        if target == 0 {
            // لفوق (سالب) بحد أقصى ωy0 عشان ما تعدّي الصفر، ولتحت بحد معقول عشان ما تنزل كثير قبل ما ترجع
            v0 = min(max(v, -w * y), 1600)
        } else {
            // الخروج لتحت: بسرعة إصبعك، بدون ما تعدّي الهدف
            v0 = min(max(v, 0), -w * y0)
        }
        onFrame = frame
        onDone = done
        startTime = nil
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
        onDone = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        if startTime == nil { startTime = l.timestamp }
        // الوقت اللي بينعرض فيه هالإطار فعلًا، فالحركة ماشية مع الشاشة بالضبط
        let t = CGFloat(max(0, l.targetTimestamp - (startTime ?? l.timestamp)))
        let w = Self.omega
        let b = v0 + w * y0
        let e = CGFloat(exp(Double(-w * t)))
        let d = (y0 + b * t) * e
        let vy = (v0 - w * b * t) * e
        if target != 0 {
            // الخروج: اليمين واليسار يبقون مثل ما هم
            if t > 0.05, abs(d) < 0.35, abs(vy) < 12 {
                let finish = onDone
                onFrame?(target, x0)
                stop()
                finish?()
                return
            }
            onFrame?(min(target, target + d), x0)
            return
        }
        let y = max(0, d)
        if t > 0.05, y < 0.35, abs(vy) < 12 {
            let finish = onDone
            onFrame?(0, 0)
            stop()
            finish?()
            return
        }
        let ratio = min(max(y / y0, 0), 1.6)
        onFrame?(y, x0 * ratio)
    }
}
