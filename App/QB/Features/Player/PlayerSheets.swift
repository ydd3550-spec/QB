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
                            row(t.name, selected: player.selectedAudio == t.id) { player.selectAudio(t.id) }
                        }
                    }
                }

                Section(L("الترجمة")) {
                    row(L("بدون ترجمة"), selected: player.selectedExternal == nil && player.selectedEmbedded == nil) {
                        player.subtitlesOff()
                    }
                    ForEach(player.embeddedSubtitles) { t in
                        row(t.name, detail: L("داخل الملف"), selected: player.selectedEmbedded == t.id) { player.selectEmbedded(t.id) }
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
                        .buttonStyle(.plain)
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
