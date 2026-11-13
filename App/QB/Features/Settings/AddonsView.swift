import SwiftUI
import QBCore

/// إدارة الإضافات: تثبيت بالرابط، تشغيل/إيقاف، ترتيب، حذف
struct AddonsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var url = ""
    @State private var installing = false
    @State private var error: String?
    @State private var filter: Filter = .all
    @State private var pendingRemove: Manifest?
    @FocusState private var fieldFocused: Bool

    enum Filter: Hashable { case all, sources, catalogs, subtitles }

    private var shown: [Manifest] {
        app.addons.filter { m in
            switch filter {
            case .all: true
            case .sources: m.resources.contains("stream")
            case .catalogs: !m.catalogs.isEmpty
            case .subtitles: m.resources.contains("subtitles")
            }
        }
    }

    var body: some View {
        List {
            Section {
                installBox
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                Text(L("تثبيت إضافة"))
            }

            Section {
                Picker(L("الفلتر"), selection: $filter) {
                    Text(L("الكل")).tag(Filter.all)
                    Text(L("مصادر")).tag(Filter.sources)
                    Text(L("كتالوجات")).tag(Filter.catalogs)
                    Text(L("ترجمات")).tag(Filter.subtitles)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            installedSection
        }
        .qbScreenBackground()
        .scrollContentBackground(.hidden)
        .navigationTitle(L("الإضافات"))
        // عنوان صغير بالنص فوق، والمحتوى يبدأ على طول تحته (بدون مساحة العنوان الكبير الفاضية)
        .navigationBarTitleDisplayMode(.inline)
            .qbNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if filter == .all, app.addons.count > 1 { EditButton() }
            }
        }
        .overlay {
            if shown.isEmpty {
                EmptyStateView(title: L("ما فيه إضافات هنا"), systemImage: "puzzlepiece.extension")
                    .padding(.top, 220)
            }
        }
        .confirmationDialog(L("حذف %@؟", pendingRemove?.name ?? ""), isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button(L("حذف"), role: .destructive) {
                if let m = pendingRemove { remove(m) }
                pendingRemove = nil
            }
        }
        .task {
            if let pending = app.pendingAddonURL {
                url = pending
                app.pendingAddonURL = nil
            }
        }
        .onChange(of: app.pendingAddonURL) { _, new in
            if let new {
                url = new
                app.pendingAddonURL = nil
            }
        }
    }

    /// صندوق التثبيت: حقل كامل العرض، زر تثبيت كامل العرض، وسطر الخطأ مع أيقونته
    private var installBox: some View {
        let canInstall = !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !installing
        return VStack(alignment: .leading, spacing: 12) {
            // الحقل كامل العرض: أيقونة الرابط، الحقل، وزر لصق/مسح
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(L("الصق رابط الإضافة (manifest.json)"), text: $url)
                    .font(Typo.row)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit { Task { await install() } }
                    .onChange(of: url) { _, _ in if error != nil { withAnimation(.easeOut(duration: 0.2)) { error = nil } } }
                Button {
                    if url.isEmpty {
                        if let s = UIPasteboard.general.string { url = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } else {
                        url = ""
                    }
                } label: {
                    Image(systemName: url.isEmpty ? "doc.on.clipboard" : "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(url.isEmpty ? Palette.accent : .secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(url.isEmpty ? L("لصق") : L("مسح"))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(error != nil ? Palette.dead.opacity(0.7) : (fieldFocused ? Palette.accent.opacity(0.6) : Palette.hairline), lineWidth: 1)
            )

            // زر التثبيت كامل العرض
            Button {
                Task { await install() }
            } label: {
                HStack(spacing: 8) {
                    if installing {
                        ProgressView().tint(Palette.onAccent)
                    } else {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16, weight: .semibold))
                    }
                    Text(installing ? L("جاري التثبيت…") : L("تثبيت")).font(Typo.headline)
                }
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(canInstall || installing ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canInstall)

            // الخطأ: أيقونة وسطر (أو أكثر) مرتب، ما ينقص
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(error)
                        .font(Typo.infoMedium)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Palette.dead)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Palette.dead.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }

        }
        .padding(.vertical, 4)
    }

    /// الرابط شكله رابط إضافة؟ (ينتهي بـ manifest.json أو يبدأ بـ stremio://)
    static func looksLikeAddonLink(_ raw: String) -> Bool {
        let s = raw.lowercased()
        if s.hasPrefix("stremio://") { return true }
        let path = s.split(separator: "?", maxSplits: 1).first.map(String.init) ?? s
        return path.hasSuffix("manifest.json") || path.hasSuffix("manifest.json/")
    }

    @ViewBuilder private var installedSection: some View {
    Section {
        ForEach(shown, id: \.transportUrl) { m in
            AddonRow(manifest: m) { enabled in
                toggle(m, enabled)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { pendingRemove = m } label: { Label(L("حذف"), systemImage: "trash") }
            }
            .contextMenu {
                if m.configurable, let cfg = configureURL(m) {
                    Button { openURL(cfg) } label: { Label(L("إعدادات الإضافة"), systemImage: "slider.horizontal.3") }
                }
                Button {
                    UIPasteboard.general.string = m.transportUrl
                    app.showToast(L("اننسخ الرابط"))
                } label: { Label(L("نسخ الرابط"), systemImage: "doc.on.doc") }
                Button(role: .destructive) { pendingRemove = m } label: { Label(L("حذف"), systemImage: "trash") }
            }
        }
        .onMove(perform: filter == .all ? { from, to in move(from: from, to: to) } : nil)
    } header: {
        Text(L("الإضافات المثبتة"))
    } footer: {
        if filter == .all, app.addons.count > 1 {
            Text(L("اضغط تعديل واسحب لترتيب الإضافات. الترتيب يحدد ترتيب الرفوف والمصادر"))
        }
    }
    }

    private func install() async {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let core = app.core, !installing else { return }
        installing = true
        error = nil
        fieldFocused = false
        do {
            let m = try await core.installAddon(url: raw)
            url = ""
            await app.addonsChanged()
            Haptics.notifySuccess()
            app.showToast(L("انثبتت %@", m.name))
        } catch {
            let message: String
            if Self.looksLikeAddonLink(raw) {
                message = CoreClient.message(for: error)
            } else if let e = error as? CoreError, case .Network = e {
                message = L("ما قدرنا نوصل للرابط. تأكد إنه رابط إضافة Stremio ينتهي بـ %@ أو يبدأ بـ %@ وإن النت شغّال", "\u{2066}manifest.json\u{2069}", "\u{2066}stremio://\u{2069}")
            } else if let e = error as? CoreError, case .Cancelled = e {
                message = CoreClient.message(for: error)
            } else {
                // مثل رابط تيك توك أو يوتيوب: الرابط فتح بس اللي رجع مو إضافة
                message = L("هذا مو رابط إضافة Stremio. لازم يكون رابط إضافة ينتهي بـ %@ أو يبدأ بـ %@", "\u{2066}manifest.json\u{2069}", "\u{2066}stremio://\u{2069}")
            }
            withAnimation(.easeOut(duration: 0.2)) { self.error = message }
            Haptics.notifyError()
        }
        installing = false
    }

    private func toggle(_ m: Manifest, _ enabled: Bool) {
        do {
            try app.core?.setAddonEnabled(transportUrl: m.transportUrl, enabled: enabled)
            Task { await app.addonsChanged() }
        } catch {
            app.showToast(CoreClient.message(for: error))
        }
    }

    private func remove(_ m: Manifest) {
        do {
            try app.core?.removeAddon(transportUrl: m.transportUrl)
            Task { await app.addonsChanged() }
            app.showToast(L("انحذفت %@", m.name))
        } catch {
            app.showToast(CoreClient.message(for: error))
        }
    }

    private func move(from: IndexSet, to: Int) {
        var list = app.addons
        list.move(fromOffsets: from, toOffset: to)
        app.addons = list
        do {
            try app.core?.reorderAddons(orderedUrls: list.map(\.transportUrl))
            Task { await app.addonsChanged() }
        } catch {
            app.showToast(CoreClient.message(for: error))
        }
    }

    /// صفحة الإعدادات عند الإضافات اللي تدعمها: نفس الرابط بدل manifest.json تصير configure
    private func configureURL(_ m: Manifest) -> URL? {
        var s = m.transportUrl
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        guard s.hasSuffix("manifest.json") else { return nil }
        return URL(string: String(s.dropLast("manifest.json".count)) + "configure")
    }
}

struct AddonRow: View {
    let manifest: Manifest
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // شعار الإضافة من الـ manifest، وتحته أول حرف من اسمها بالذهبي لو ما فيه شعار أو ما انفتح
            ZStack {
                LinearGradient(colors: [Palette.surfaceRaised, Palette.surface], startPoint: .top, endPoint: .bottom)
                if let logo = Self.logoURL(manifest.logo) {
                    RemoteImage(url: logo, maxPixel: 120, contentMode: .fit, placeholderSymbol: nil,
                                placeholderText: String(manifest.name.prefix(1)).uppercased())
                        .padding(4)
                } else {
                    Text(String(manifest.name.prefix(1)).uppercased())
                        .font(Typo.font(.bold, 20, .title3))
                        .foregroundStyle(Palette.accent)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(manifest.name).font(Typo.bodyMedium).lineLimit(1)
                    Text(manifest.version).font(Typo.badge).foregroundStyle(.tertiary)
                }
                if let d = manifest.description, !d.isEmpty {
                    Text(d).font(Typo.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 5) {
                    if manifest.resources.contains("stream") { TagBadge(text: L("مصادر")) }
                    if !manifest.catalogs.isEmpty { TagBadge(text: L("كتالوجات")) }
                    if manifest.resources.contains("meta") { TagBadge(text: L("تفاصيل")) }
                    if manifest.resources.contains("subtitles") { TagBadge(text: L("ترجمات")) }
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { manifest.enabled }, set: onToggle))
                .labelsHidden()
                .accessibilityLabel(manifest.name)
        }
        .padding(.vertical, 4)
        .opacity(manifest.enabled ? 1 : 0.55)
    }
}


extension AddonRow {
    /// SVG ما ينفتح كصورة، وروابط http نخليها https
    static func logoURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.lowercased().hasSuffix(".svg") { return nil }
        return raw
    }
}
