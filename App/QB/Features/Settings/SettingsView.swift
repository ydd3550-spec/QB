import SwiftUI
import QBCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @State private var cacheBytes: Int64 = 0
    @State private var exportDoc: JSONDocument?
    @State private var importing = false
    @State private var confirmClear = false

    private let subtitleLanguages = ["ara", "eng", "fre", "spa", "tur", "ger", "ita", "por", "rus", "per", "urd", "hin", "ind", "may", "jpn", "kor", "chi"]

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: app.binding(for: .settings)) {
            Form {
                Section {
                    NavigationLink(value: SettingsRoute.addons) {
                        row(L("الإضافات"), "puzzlepiece.extension.fill", detail: "\(app.addons.count)")
                    }
                    NavigationLink(value: SettingsRoute.history) {
                        row(L("سجل المشاهدة"), "clock.fill")
                    }
                }

                Section(L("العرض")) {
                    Picker(selection: Binding(get: { app.language }, set: { app.setLanguage($0) })) {
                        Text("العربية").tag(AppLanguage.arabic)
                        Text("English").tag(AppLanguage.english)
                    } label: {
                        row(L("اللغة"), "globe")
                    }
                    Picker(selection: Binding(get: { app.appearance }, set: { app.appearance = $0; app.save("appearance", $0) })) {
                        Text(L("حسب الجهاز")).tag("system")
                        Text(L("فاتح")).tag("light")
                        Text(L("داكن")).tag("dark")
                    } label: {
                        row(L("المظهر"), "circle.lefthalf.filled")
                    }
                }

                Section {
                    Picker(selection: Binding(get: { app.preferredQuality }, set: { app.preferredQuality = $0; app.save("preferred_quality", "\($0)") })) {
                        Text(L("الأعلى المتاح")).tag(0)
                        Text("4K").tag(2160)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    } label: {
                        row(L("الجودة المفضلة"), "sparkles.tv")
                    }
                    Picker(selection: Binding(get: { app.preferredEngine }, set: { app.preferredEngine = $0; app.save("preferred_engine", $0) })) {
                        Text(L("تلقائي")).tag("auto")
                        Text("VLC").tag("vlc")
                    } label: {
                        row(L("المشغّل"), "play.rectangle.fill")
                    }
                    Toggle(isOn: Binding(get: { app.autoNext }, set: { app.autoNext = $0; app.save("auto_next", $0 ? "1" : "0") })) {
                        row(L("الحلقة الجاية تلقائيًا"), "forward.end.fill")
                    }
                    Toggle(isOn: Binding(get: { app.autoPiP }, set: { app.autoPiP = $0; app.save("auto_pip", $0 ? "1" : "0") })) {
                        row(L("صورة داخل صورة تلقائيًا"), "pip.fill")
                    }
                    Stepper(value: Binding(get: { app.skipIntroSeconds }, set: { app.skipIntroSeconds = $0; app.save("skip_intro_seconds", "\($0)") }), in: 30...180, step: 5) {
                        row(L("تخطّي المقدمة"), "forward.fill", detail: L("%@ ثانية", "\(app.skipIntroSeconds)"))
                    }
                } header: {
                    Text(L("التشغيل"))
                } footer: {
                    Text(L("التلقائي يبدأ بالمشغّل الأصلي ويحوّل لـ VLC لو الملف ما اشتغل"))
                }

                Section(L("الترجمة")) {
                    Picker(selection: Binding(get: { app.subtitleLang }, set: { app.subtitleLang = $0; app.save("subtitle_lang", $0) })) {
                        Text(L("بدون ترجمة")).tag("off")
                        ForEach(subtitleLanguages, id: \.self) { code in
                            Text(LanguageNames.displayName(code, locale: locale)).tag(code)
                        }
                    } label: {
                        row(L("لغة الترجمة"), "captions.bubble.fill")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        row(L("حجم الترجمة"), "textformat.size", detail: "\(Int(app.subtitleSize * 100))%")
                        Slider(value: Binding(get: { app.subtitleSize }, set: { app.subtitleSize = $0 }), in: 0.7...1.8, step: 0.1) { editing in
                            if !editing { app.save("subtitle_size", String(format: "%.1f", app.subtitleSize)) }
                        }
                        Text(L("هذا شكل الترجمة"))
                            .font(Typo.font(.semibold, 19 * app.subtitleSize, .title3))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(app.subtitleBackground ? 0.6 : 0.0), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.gray.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Toggle(isOn: Binding(get: { app.subtitleBackground }, set: { app.subtitleBackground = $0; app.save("subtitle_background", $0 ? "1" : "0") })) {
                        row(L("خلفية للترجمة"), "rectangle.fill")
                    }
                }

                Section {
                    Button {
                        do {
                            let json = try app.core?.exportLibrary() ?? "{}"
                            exportDoc = JSONDocument(text: json)
                        } catch {
                            app.showToast(CoreClient.message(for: error))
                        }
                    } label: {
                        row(L("تصدير المكتبة"), "square.and.arrow.up")
                    }
                    Button {
                        importing = true
                    } label: {
                        row(L("استيراد مكتبة"), "square.and.arrow.down")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        row(L("مسح الذاكرة المؤقتة"), "trash", detail: ByteText.text(cacheBytes), destructive: true)
                    }
                } header: {
                    Text(L("البيانات"))
                } footer: {
                    Text(L("التصدير يشمل المكتبة والتقدّم والسجل والإضافات. المسح ما يلمس مكتبتك"))
                }

                Section {
                    FeedbackRow()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                Section {
                    HStack {
                        QBLogo(size: 30)
                        Spacer()
                        Text(appVersion).font(Typo.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .qbScreenBackground()
            .navigationTitle(L("الإعدادات"))
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .addons: AddonsView()
                case .history: HistoryView()
                }
            }
            .mediaDestinations(historyZoom)
            .task { refreshCache() }
            .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc,
                          contentType: .json, defaultFilename: "QB-library") { result in
                if case .success = result { app.showToast(L("انحفظت المكتبة")) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case let .success(url) = result else { return }
                Task { await importLibrary(url) }
            }
            .confirmationDialog(L("مسح الذاكرة المؤقتة؟"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(L("مسح"), role: .destructive) {
                    Task {
                        await app.core?.clearCache()
                        URLCache.shared.removeAllCachedResponses()
                        ImagePipeline.shared.clearMemory(); ImagePipeline.shared.clearDisk()
                        refreshCache()
                        app.showToast(L("انمسحت الذاكرة المؤقتة"))
                    }
                }
            }
        }
    }

    @Namespace private var historyZoom

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func refreshCache() {
        cacheBytes = Int64(app.core?.cacheSizeBytes() ?? 0) + Int64(ImagePipeline.shared.diskUsage)
    }

    private func importLibrary(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            app.showToast(L("تعذّر قراءة الملف"))
            return
        }
        do {
            let n = try await app.core?.importLibrary(json: text) ?? 0
            app.libraryVersion += 1
            await app.addonsChanged()
            app.refreshContinueWatching()
            app.showToast(L("انضاف %@ عنصر", "\(n)"))
        } catch {
            app.showToast(CoreClient.message(for: error))
        }
    }

    private func row(_ title: String, _ icon: String, detail: String? = nil, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(destructive ? .white : Palette.onAccent)
                .frame(width: 30, height: 30)
                .background((destructive ? Palette.dead : Palette.accent).gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(Typo.bodyMedium).foregroundStyle(destructive ? Palette.dead : .primary)
            if let detail {
                Spacer()
                Text(detail).font(Typo.info).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// ملف JSON للتصدير
/// صف «أرسل ملاحظاتك»: كبسولة داكنة وأيقونة طيارة ورق ذهبية، يفتح محادثة التلقرام الخاصة على طول
struct FeedbackRow: View {
    static let telegramUser = "l_jii"

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 34, height: 34)
                    .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.accent.opacity(0.25), lineWidth: 0.5))
                Text(L("أرسل ملاحظاتك"))
                    .font(Typo.bodyMedium)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 18)
            .padding(.vertical, 9)
            .background(Palette.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("أرسل ملاحظاتك"))
    }

    /// تطبيق التلقرام أول (يفتح الخاص مباشرة)، ولو مو مثبّت نفتح t.me
    private func open() {
        Haptics.tap()
        let app = URL(string: "tg://resolve?domain=\(Self.telegramUser)")!
        let web = URL(string: "https://t.me/\(Self.telegramUser)")!
        UIApplication.shared.open(app, options: [:]) { ok in
            if !ok { UIApplication.shared.open(web) }
        }
    }
}

struct JSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// سجل المشاهدة كامل
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @State private var entries: [HistoryEntry] = []
    @State private var confirm = false

    var body: some View {
        List {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, h in
                NavigationLink(value: MediaRef(id: h.mediaId, kind: h.kind, name: h.title, poster: h.poster)) {
                    HStack(spacing: 12) {
                        RemoteImage(url: h.poster, maxPixel: 160)
                            .frame(width: 44, height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(h.title).font(Typo.bodyMedium).lineLimit(1)
                            Text(Date(timeIntervalSince1970: TimeInterval(h.watchedAt)).formatted(.relative(presentation: .named).locale(locale)))
                                .font(Typo.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        TagBadge(text: h.engine == .vlc ? "VLC" : L("أصلي"))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .qbScreenBackground()
        .navigationTitle(L("سجل المشاهدة"))
        .overlay {
            if entries.isEmpty {
                EmptyStateView(title: L("السجل فاضي"), systemImage: "clock")
            }
        }
        .toolbar {
            if !entries.isEmpty {
                Button(L("مسح"), role: .destructive) { confirm = true }
            }
        }
        .confirmationDialog(L("مسح سجل المشاهدة؟"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L("مسح"), role: .destructive) {
                try? app.core?.clearHistory()
                entries = []
                app.libraryVersion += 1
            }
        }
        .task(id: app.libraryVersion) { entries = (try? app.core?.history(limit: 300)) ?? [] }
    }
}
