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
                HStack(spacing: 10) {
                    TextField(L("الصق رابط الإضافة (manifest.json)"), text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($fieldFocused)
                        .onSubmit { Task { await install() } }
                        .environment(\.layoutDirection, .leftToRight)
                    if url.isEmpty {
                        Button {
                            if let s = UIPasteboard.general.string { url = s }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("لصق"))
                    }
                }
                Button {
                    Task { await install() }
                } label: {
                    HStack {
                        if installing { ProgressView().padding(.trailing, 4) }
                        Text(installing ? L("جاري التثبيت…") : L("تثبيت")).font(Typo.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || installing)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.dead)
                }
            } header: {
                Text(L("تثبيت إضافة"))
            } footer: {
                Text(L("تشتغل كل إضافات Stremio. الروابط اللي تبدأ بـ stremio:// تشتغل بعد"))
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
            self.error = CoreClient.message(for: error)
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
            RemoteImage(url: manifest.logo, maxPixel: 120, contentMode: .fit, placeholderSymbol: "puzzlepiece.extension.fill")
                .frame(width: 44, height: 44)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
