//! طبقة UniFFI الرفيعة: كائن QBCore واحد تستخدمه Swift.
//! كل دالة async تشتغل على tokio، وإلغاء Task في Swift يلغي الـ future في Rust.
uniffi::setup_scaffolding!();

use qb_model::*;
use std::sync::Arc;

/// يستقبل تحديثات المصادر أول بأول (ينفّذه Swift)
#[uniffi::export(with_foreign)]
pub trait SourceListener: Send + Sync {
    fn on_sources(&self, sources: Vec<RankedSource>);
    fn on_health(&self, source_id: String, health: Health);
    fn on_finished(&self);
}

struct Bridge(Arc<dyn SourceListener>);
impl qb_core::SourceEvents for Bridge {
    fn on_sources(&self, sources: Vec<RankedSource>) {
        self.0.on_sources(sources)
    }
    fn on_health(&self, source_id: String, health: Health) {
        self.0.on_health(source_id, health)
    }
    fn on_finished(&self) {
        self.0.on_finished()
    }
}

/// يستقبل نتائج البحث رف رف
#[uniffi::export(with_foreign)]
pub trait SearchListener: Send + Sync {
    fn on_row(&self, row: CatalogRow);
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DiscoverCatalog {
    pub addon_url: String,
    pub addon_name: String,
    pub catalog: CatalogDef,
}

#[derive(uniffi::Object)]
pub struct QBCore {
    core: qb_core::Core,
}

#[uniffi::export(async_runtime = "tokio")]
impl QBCore {
    #[uniffi::constructor]
    pub fn new(data_dir: String) -> Result<Arc<Self>, CoreError> {
        Ok(Arc::new(QBCore { core: qb_core::Core::new(&data_dir)? }))
    }

    /// نواة بدون تخزين على الجهاز: آخر حل لو فتح القاعدة فشل في كل المجلدات
    #[uniffi::constructor]
    pub fn in_memory() -> Result<Arc<Self>, CoreError> {
        Ok(Arc::new(QBCore { core: qb_core::Core::in_memory()? }))
    }

    pub fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    pub fn cancel_all(&self) {
        self.core.cancel_all();
    }

    // ----- الإضافات -----
    pub async fn seed_default_addons(&self) -> u32 {
        self.core.seed_default_addons().await
    }
    pub async fn addons(&self) -> Vec<Manifest> {
        self.core.addons_async().await
    }
    pub async fn install_addon(&self, url: String) -> Result<Manifest, CoreError> {
        self.core.install_addon(&url).await
    }
    pub fn remove_addon(&self, transport_url: String) -> Result<(), CoreError> {
        self.core.remove_addon(&transport_url)
    }
    pub fn set_addon_enabled(&self, transport_url: String, enabled: bool) -> Result<(), CoreError> {
        self.core.set_addon_enabled(&transport_url, enabled)
    }
    pub fn reorder_addons(&self, ordered_urls: Vec<String>) -> Result<(), CoreError> {
        self.core.reorder_addons(&ordered_urls)
    }

    // ----- الرئيسية / اكتشف / البحث -----
    pub async fn home_rows(&self) -> Result<Vec<CatalogRow>, CoreError> {
        self.core.home_rows().await
    }
    pub fn discover_catalogs(&self) -> Vec<DiscoverCatalog> {
        self.core
            .discover_catalogs()
            .into_iter()
            .map(|d| DiscoverCatalog { addon_url: d.addon_url, addon_name: d.addon_name, catalog: d.catalog })
            .collect()
    }
    pub async fn catalog_page(&self, addon_url: String, kind: String, catalog_id: String, genre: Option<String>, skip: u32) -> Result<Vec<MetaPreview>, CoreError> {
        self.core.catalog_page(&addon_url, &kind, &catalog_id, genre, skip).await
    }
    pub async fn search(&self, query: String) -> Result<Vec<MetaPreview>, CoreError> {
        self.core.search_flat(&query).await
    }
    /// البحث رف رف وهو يوصل من كل إضافة (لشاشة البحث)
    pub async fn search_rows(&self, query: String, listener: Arc<dyn SearchListener>) -> Result<Vec<CatalogRow>, CoreError> {
        self.core.search(&query, move |row| listener.on_row(row)).await
    }
    pub async fn similar(&self, kind: MediaKind, id: String) -> Result<Vec<MetaPreview>, CoreError> {
        self.core.similar(kind, &id).await
    }

    // ----- التفاصيل والمصادر -----
    pub async fn meta(&self, kind: MediaKind, id: String) -> Result<MetaDetail, CoreError> {
        self.core.meta(kind, &id).await
    }
    pub fn next_episode(&self, meta: MetaDetail, current_id: String) -> Option<Video> {
        qb_core::Core::next_episode(&meta, &current_id)
    }
    pub async fn load_sources(&self, kind: MediaKind, id: String, listener: Arc<dyn SourceListener>) -> Result<(), CoreError> {
        self.core.load_sources_with(kind, &id, true, Arc::new(Bridge(listener))).await.map(|_| ())
    }
    pub async fn addon_report(&self, kind: MediaKind, id: String) -> Result<Vec<AddonReport>, CoreError> {
        self.core.addon_report(kind, &id).await
    }

    // ----- الترجمات -----
    pub async fn subtitles(&self, kind: MediaKind, id: String) -> Vec<SubtitleTrack> {
        self.core.subtitles(kind, &id).await.unwrap_or_default()
    }
    pub async fn parse_subtitle(&self, url: String) -> Result<Vec<Cue>, CoreError> {
        self.core.load_subtitle(&url).await
    }
    pub fn parse_subtitle_text(&self, text: String, name_hint: Option<String>) -> Vec<Cue> {
        qb_subs::parse(&text, name_hint.as_deref())
    }
    pub fn shift_cues(&self, cues: Vec<Cue>, offset_ms: i64) -> Vec<Cue> {
        qb_subs::shift(&cues, offset_ms)
    }

    // ----- التقدّم والمكتبة والسجل -----
    pub fn save_progress(&self, progress: Progress) -> Result<(), CoreError> {
        self.core.store().save_progress(&progress)
    }
    pub fn progress(&self, media_id: String) -> Result<Option<Progress>, CoreError> {
        self.core.store().progress(&media_id)
    }
    pub fn continue_watching(&self) -> Vec<Progress> {
        self.core.store().continue_watching(30).unwrap_or_default()
    }
    pub fn remove_progress(&self, media_id: String) -> Result<(), CoreError> {
        self.core.store().remove_progress(&media_id)
    }
    pub fn add_to_library(&self, item: LibraryItem) -> Result<(), CoreError> {
        self.core.store().add_to_library(&item)
    }
    pub fn remove_from_library(&self, media_id: String) -> Result<(), CoreError> {
        self.core.store().remove_from_library(&media_id)
    }
    pub fn in_library(&self, media_id: String) -> Result<bool, CoreError> {
        self.core.store().in_library(&media_id)
    }
    pub fn library(&self) -> Result<Vec<LibraryItem>, CoreError> {
        self.core.store().library()
    }
    pub fn add_history(&self, entry: HistoryEntry) -> Result<(), CoreError> {
        self.core.store().add_history(&entry)
    }
    pub fn history(&self, limit: u32) -> Result<Vec<HistoryEntry>, CoreError> {
        self.core.store().history(limit)
    }
    pub fn clear_history(&self) -> Result<(), CoreError> {
        self.core.store().clear_history()
    }

    // ----- الإعدادات وذاكرة المصادر -----
    pub fn setting(&self, key: String) -> Result<Option<String>, CoreError> {
        self.core.store().setting(&key)
    }
    pub fn set_setting(&self, key: String, value: String) -> Result<(), CoreError> {
        self.core.store().set_setting(&key, &value)
    }
    pub fn mark_source_ok(&self, source_id: String, engine: Engine) -> Result<(), CoreError> {
        self.core.store().mark_source_ok(&source_id, engine)
    }
    pub fn mark_source_failed(&self, source_id: String, native_failed: bool) -> Result<(), CoreError> {
        self.core.store().mark_source_failed(&source_id, native_failed)
    }
    pub fn export_library(&self) -> Result<String, CoreError> {
        self.core.export_library()
    }
    pub async fn import_library(&self, json: String) -> Result<u32, CoreError> {
        self.core.import_library(json).await
    }
    pub async fn clear_cache(&self) {
        self.core.clear_cache().await
    }
    pub fn cache_size_bytes(&self) -> u64 {
        self.core.cache_size_bytes()
    }
}

/// ينظّف رابط إضافة (stremio:// وmanifest.json) قبل ما ينعرض
#[uniffi::export]
pub fn normalize_addon_url(url: String) -> Result<String, CoreError> {
    qb_protocol::normalize_manifest_url(&url)
}
