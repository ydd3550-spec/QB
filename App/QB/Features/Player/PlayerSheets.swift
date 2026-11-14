import SwiftUI
import QBCore

/// اختيار الصوت والترجمة (اللي داخل الملف + اللي من الإضافات) ومزامنة الترجمة
struct TracksSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    private var player: PlayerModel { app.player }

    /// الترجمات الخارجية مجمّعة باللغة، اللغة المفضلة أول
    private var groups: [(lang: String, tracks: [SubtitleTrack])] {
        let grouped = Dictionary(grouping: player.externalSubtitles) { LanguageNames.normalize($0.lang) }
        let preferred = LanguageNames.normalize(app.subtitleLang)
        return grouped.keys.sorted { a, b in
            if a == preferred { return true }
            if b == preferred { return false }
            return LanguageNames.displayName(a, locale: locale) < LanguageNames.displayName(b, locale: locale)
        }.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !player.audioTracks.isEmpty {
                    Section(L("الصوت")) {
                        ForEach(player.audioTracks) { t in
                            row(t.name, detail: t.detail, selected: player.selectedAudio == t.id) { player.selectAudio(t.id) }
                        }
                    }
                }

                Section(L("الترجمة")) {
                    row(L("بدون ترجمة"), selected: player.selectedExternal == nil && player.selectedEmbedded == nil) {
                        player.subtitlesOff()
                    }
                    ForEach(player.embeddedSubtitles) { t in
                        row(t.name, detail: t.detail ?? L("داخل الملف"), selected: player.selectedEmbedded == t.id) { player.selectEmbedded(t.id) }
                    }
                }

                if player.selectedExternal != nil {
                    Section(L("مزامنة الترجمة")) {
                        HStack {
                            Button { player.shiftSubtitles(by: -0.25) } label: { Image(systemName: "minus").frame(width: 44, height: 36) }
                                .buttonStyle(.bordered)
                            Spacer()
                            VStack(spacing: 2) {
                                Text(String(format: "%+.2f", player.subtitleOffset) + " " + L("ثانية"))
                                    .font(Typo.time)
                                    .environment(\.layoutDirection, .leftToRight)
                                Text(player.subtitleOffset > 0 ? L("متأخرة") : player.subtitleOffset < 0 ? L("متقدّمة") : L("بدون تعديل"))
                                    .font(Typo.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { player.shiftSubtitles(by: 0.25) } label: { Image(systemName: "plus").frame(width: 44, height: 36) }
                                .buttonStyle(.bordered)
                        }
                        if player.subtitleOffset != 0 {
                            Button(L("رجّع المزامنة")) { player.resetSubtitleOffset() }
                        }
                    }
                }

                ForEach(groups, id: \.lang) { group in
                    Section(LanguageNames.displayName(group.lang, locale: locale)) {
                        ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, t in
                            row("\(LanguageNames.displayName(t.lang, locale: locale)) \(index + 1)", detail: t.addon,
                                selected: player.selectedExternal == t.id, loading: player.loadingSubtitle && player.selectedExternal == t.id) {
                                player.selectExternal(t)
                            }
                        }
                    }
                }

                if player.externalSubtitles.isEmpty && player.embeddedSubtitles.isEmpty {
                    Section {
                        Text(L("ما لقينا ترجمات لهذا العمل. ثبّت إضافة ترجمات من الإعدادات"))
                            .font(Typo.info).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(L("الترجمة والصوت"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ title: String, detail: String? = nil, selected: Bool, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.bodyMedium).foregroundStyle(.primary)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if loading {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(Haptics.select, trigger: selected)
    }
}

/// المصادر من داخل المشغّل
struct PlayerSourcesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    private var player: PlayerModel { app.player }

    var body: some View {
        NavigationStack {
            List {
                if player.engineName == "AVPlayer" {
                    Section {
                        Button {
                            player.reopenInVLC()
                            dismiss()
                        } label: {
                            Label(L("افتح بمشغّل VLC"), systemImage: "play.rectangle.on.rectangle")
                        }
                    } footer: {
                        Text(L("لو الصورة أو الصوت مو طبيعي، VLC يشغّل كل الصيغ تقريبًا"))
                    }
                }
                Section(L("المصادر")) {
                    ForEach(player.context?.sources ?? []) { s in
                        Button {
                            player.switchSource(s)
                            dismiss()
                        } label: {
                            SourceRow(source: s, current: s.id == player.source?.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(L("المصادر"))
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if (player.context?.sources ?? []).isEmpty {
                    EmptyStateView(title: L("ما فيه مصادر"), systemImage: "rectangle.stack")
                }
            }
        }
    }
}

/// سرعة التشغيل
struct SpeedSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        NavigationStack {
            List(rates, id: \.self) { r in
                Button {
                    app.player.setRate(r)
                    app.preferredSpeed = r
                    app.save("preferred_speed", String(format: "%.2f", r))
                    Haptics.tap()
                    dismiss()
                } label: {
                    HStack {
                        Text(r == 1 ? L("عادي") : String(format: "%.2gx", r)).font(Typo.bodyMedium)
                        Spacer()
                        if app.player.rate == r {
                            Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(L("السرعة"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

/// شريط المشابه بدون ما يوقف التشغيل
struct SimilarSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                    ForEach(app.player.similar) { item in
                        Button {
                            dismiss()
                            app.player.openSimilar(item)
                        } label: {
                            PosterCard(item, width: nil)
                        }
                        .buttonStyle(.bouncyCard)
                    }
                }
                .padding(16)
            }
            .navigationTitle(L("مشابه"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// صف مصدر: الاسم، الجودة، المشغّل، الإضافة، ونقطة الحالة
struct SourceRow: View {
    let source: RankedSource
    var current = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HealthDot(health: source.health)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(source.title)
                    .font(Typo.bodyMedium)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if let d = source.description, !d.isEmpty {
                    Text(d).font(Typo.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let q = QualityLabel.text(source.quality) {
                        TagBadge(text: q, filled: source.quality >= 2000)
                    }
                    TagBadge(text: engineText, color: source.engine == .native ? Palette.accent : .secondary)
                    Text(source.addon).font(Typo.badge).foregroundStyle(.secondary).lineLimit(1)
                    if let ms = source.latencyMs {
                        Text("\(ms)ms").font(Typo.badge).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.accent).padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var engineText: String {
        switch source.engine {
        case .native: L("أصلي")
        case .vlc: "VLC"
        case .youTube: "YouTube"
        case .external: L("خارجي")
        }
    }
}

struct HealthDot: View {
    let health: Health
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(isChecking ? (pulse ? 0.35 : 1) : 1)
            .onAppear {
                guard isChecking else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityLabel(label)
    }

    private var isChecking: Bool {
        if case .checking = health { return true }
        return false
    }

    private var color: Color {
        switch health {
        case .alive: Palette.live
        case .checking: Palette.checking
        case .unreachable: Palette.dead
        }
    }

    private var label: String {
        switch health {
        case .alive: L("شغّال")
        case .checking: L("جاري الفحص")
        case .unreachable: L("ما يرد")
        }
    }
}

/// شكل الترجمة من داخل المشغّل: الحجم والوزن والخلفية والمكان، وكل تغيير ينحفظ فورًا
/// ويبان على الفيديو اللي ورا الشيت (المعاينة حية، مو صورة ثابتة)
struct SubtitleStyleSheet: View {
    @Environment(AppModel.self) private var app

    private let sizes: (min: Double, max: Double) = (0.7, 1.8)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sample
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(Color.clear)
                }

                Section(L("الحجم")) {
                    HStack(spacing: 12) {
                        Text(verbatim: "A").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { app.subtitleSize }, set: { v in
                            app.subtitleSize = (v * 10).rounded() / 10
                        }), in: sizes.min...sizes.max, step: 0.1) { editing in
                            if !editing { app.save("subtitle_size", String(format: "%.1f", app.subtitleSize)) }
                        } label: {
                            EmptyView()
                        }
                        Text(verbatim: "\(Int((app.subtitleSize * 100).rounded()))%")
                            .font(Typo.caption).monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                Section(L("الوزن")) {
                    Picker(L("الوزن"), selection: Binding(get: { app.subtitleWeight }, set: { v in
                        app.subtitleWeight = v
                        app.save("subtitle_weight", String(v))
                        Haptics.tap()
                    })) {
                        Text(L("عادي")).tag(0)
                        Text(L("سميك")).tag(1)
                        Text(L("عريض")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section(L("الخلفية")) {
                    Picker(L("الخلفية"), selection: Binding(get: { app.subtitleStyle }, set: { v in
                        app.subtitleStyle = v
                        app.subtitleBackground = (v == 1)
                        app.save("subtitle_style", String(v))
                        app.save("subtitle_background", v == 1 ? "1" : "0")
                        Haptics.tap()
                    })) {
                        Text(L("ظل")).tag(0)
                        Text(L("صندوق")).tag(1)
                        Text(L("بدون")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    Picker(L("المكان"), selection: Binding(get: { Self.positionStep(app.subtitlePosition) }, set: { v in
                        app.subtitlePosition = Self.positionValue(v)
                        app.save("subtitle_position", String(format: "%.2f", app.subtitlePosition))
                        Haptics.tap()
                    })) {
                        Text(L("منخفض")).tag(0)
                        Text(L("وسط")).tag(1)
                        Text(L("مرتفع")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text(L("المكان"))
                } footer: {
                    Text(L("المعاينة فوق حية: الترجمة على الفيديو تتغيّر وأنت تعدّل."))
                }

                Section {
                    Button(L("رجّع الشكل الافتراضي")) {
                        app.subtitleSize = 1.0
                        app.subtitleWeight = 1
                        app.subtitleStyle = 0
                        app.subtitleBackground = false
                        app.subtitlePosition = 1.0
                        app.save("subtitle_size", "1.0")
                        app.save("subtitle_weight", "1")
                        app.save("subtitle_style", "0")
                        app.save("subtitle_background", "0")
                        app.save("subtitle_position", "1.00")
                        Haptics.notifySuccess()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(L("شكل الترجمة"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    /// 0 منخفض، 1 وسط، 2 مرتفع
    private static func positionStep(_ value: Double) -> Int {
        if value < 0.9 { return 0 }
        if value > 1.15 { return 2 }
        return 1
    }

    private static func positionValue(_ step: Int) -> Double {
        switch step {
        case 0: 0.8
        case 2: 1.4
        default: 1.0
        }
    }

    private var sample: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.15, green: 0.20, blue: 0.27),
                                    Color(red: 0.36, green: 0.29, blue: 0.21)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            SubtitleOverlay(text: L("ما عاد فيه وقت نضيّعه."),
                            scale: app.subtitleSize * 0.8,
                            weight: app.subtitleWeight,
                            style: app.subtitleStyle)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        }
        .animation(Motion.standard, value: app.subtitleStyle)
        .animation(Motion.standard, value: app.subtitleWeight)
    }
}
