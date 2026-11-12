//! المنسّق: يجمع الإضافات بالتوازي، يرتب المصادر، ويدير التخزين والكاش والإلغاء.
use qb_cache::{Cache, HealthCache, Kind as CacheKind};
use qb_model::*;
use qb_net::Client;
use qb_protocol::{manifest_supports, AddonClient};
use qb_store::Store;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{watch, Semaphore};
use tokio::task::JoinSet;

pub use qb_protocol::normalize_manifest_url;

/// الإضافات اللي تتثبت أول مرة (من جولة الإضافات في الخطة)
pub const DEFAULT_ADDONS: &[&str] = &[
    "https://v3-cinemeta.strem.io/manifest.json",
    "https://opensubtitles-v3.strem.io/manifest.json",
];

const MAX_HOME_ROWS: usize = 14;

#[derive(Debug, Clone, PartialEq)]
pub struct DiscoverCatalog {
    pub addon_url: String,
    pub addon_name: String,
    pub catalog: CatalogDef,
}

#[derive(Clone)]
pub struct Core {
    inner: Arc<Inner>,
}

struct Inner {
    client: AddonClient,
    store: Arc<Store>,
    cache: Cache,
    health: HealthCache,
    /// فحص الصحة: 4 بالمرة بس
    probes: Arc<Semaphore>,
    cancel_tx: watch::Sender<u64>,
}

/// اللي يستقبل تحديثات المصادر (Swift ينفّذه عن طريق UniFFI)
pub trait SourceEvents: Send + Sync {
    fn on_sources(&self, sources: Vec<RankedSource>);
    fn on_health(&self, source_id: String, health: Health);
    fn on_finished(&self);
}

impl Core {
    pub fn new(data_dir: &str) -> Result<Core, CoreError> {
        let dir = PathBuf::from(data_dir);
        std::fs::create_dir_all(&dir).map_err(CoreError::storage)?;
        let store = Store::open(dir.join("qb.sqlite").to_str().unwrap_or("qb.sqlite"))?;
        Self::with_parts(store, Cache::new(Some(dir.join("cache"))))
    }

    /// للاختبارات: كل شي بالذاكرة
    pub fn in_memory() -> Result<Core, CoreError> {
        Self::with_parts(Store::open_in_memory()?, Cache::new(None))
    }

    fn with_parts(store: Store, cache: Cache) -> Result<Core, CoreError> {
        let (cancel_tx, _) = watch::channel(0u64);
        Ok(Core {
            inner: Arc::new(Inner {
                client: AddonClient::new(Client::new()?),
                store: Arc::new(store),
                cache,
                health: HealthCache::new(),
                probes: Arc::new(Semaphore::new(4)),
                cancel_tx,
            }),
        })
    }

    pub fn store(&self) -> &Store {
        &self.inner.store
    }

    // ---------- الإلغاء ----------

    /// يلغي كل الطلبات الشغّالة الحين (مثلاً لما يطلع المستخدم من الشاشة)
    pub fn cancel_all(&self) {
        self.inner.cancel_tx.send_modify(|g| *g = g.wrapping_add(1));
    }

    async fn cancellable<T>(&self, fut: impl std::future::Future<Output = Result<T, CoreError>>) -> Result<T, CoreError> {
        let mut rx = self.inner.cancel_tx.subscribe();
        rx.borrow_and_update();
        tokio::select! {
            r = fut => r,
            _ = rx.changed() => Err(CoreError::Cancelled),
        }
    }

    // ---------- كاش + شبكة ----------

    async fn cached_json(&self, kind: CacheKind, url: &str) -> Result<serde_json::Value, CoreError> {
        if let Some(v) = self.inner.cache.get(kind, url).await {
            return Ok(v);
        }
        let v = self.inner.client.net.get_json(url).await?;
        self.inner.cache.put(kind, url, v.clone()).await;
        Ok(v)
    }

    pub async fn clear_cache(&self) {
        self.inner.cache.clear().await;
        self.inner.health.clear();
    }

    /// الكتابة في SQLite من الكود الـ async تروح لـ spawn_blocking (والقفل يخليها كاتب واحد بالمرة)
    pub async fn write<T: Send + 'static>(&self, f: impl FnOnce(&Store) -> Result<T, CoreError> + Send + 'static) -> Result<T, CoreError> {
        let store = self.inner.store.clone();
        tokio::task::spawn_blocking(move || f(&store)).await.map_err(|e| CoreError::storage(e))?
    }

    pub fn cache_size_bytes(&self) -> u64 {
        self.inner.cache.disk_size()
    }

    // ---------- الإضافات ----------

    pub fn addons(&self) -> Result<Vec<Manifest>, CoreError> {
        self.inner.store.addons()
    }

    /// نسخة async للواجهة (القراءة بعيد عن الـ main thread)
    pub async fn addons_async(&self) -> Vec<Manifest> {
        let store = self.inner.store.clone();
        tokio::task::spawn_blocking(move || store.addons().unwrap_or_default()).await.unwrap_or_default()
    }

    fn enabled_addons(&self) -> Vec<Manifest> {
        self.addons().unwrap_or_default().into_iter().filter(|a| a.enabled).collect()
    }

    /// يثبّت أي إضافة Stremio من رابطها (بدون أي قيود)، أو يحدّثها لا كانت مثبتة
    pub async fn install_addon(&self, url: &str) -> Result<Manifest, CoreError> {
        let normalized = normalize_manifest_url(url)?;
        let m = self.cancellable(self.inner.client.fetch_manifest(&normalized)).await?;
        let saved = m.clone();
        self.write(move |s| s.save_addon(&saved)).await?;
        Ok(self.addons()?.into_iter().find(|a| a.transport_url == m.transport_url).unwrap_or(m))
    }

    pub fn remove_addon(&self, transport_url: &str) -> Result<(), CoreError> {
        self.inner.store.remove_addon(transport_url)
    }

    pub fn set_addon_enabled(&self, transport_url: &str, enabled: bool) -> Result<(), CoreError> {
        self.inner.store.set_addon_enabled(transport_url, enabled)
    }

    pub fn reorder_addons(&self, ordered: &[String]) -> Result<(), CoreError> {
        self.inner.store.reorder_addons(ordered)
    }

    /// أول تشغيل: يثبّت الإضافات الافتراضية مرة وحدة. اللي يشيلها المستخدم ما ترجع.
    pub async fn seed_default_addons(&self) -> u32 {
        let mut installed = 0;
        for url in DEFAULT_ADDONS {
            let key = format!("seeded:{url}");
            if self.inner.store.setting(&key).ok().flatten().is_some() {
                continue;
            }
            if self.install_addon(url).await.is_ok() {
                let _ = self.write(move |s| s.set_setting(&key, "1")).await;
                installed += 1;
            }
        }
        installed
    }

    // ---------- الرئيسية واكتشف ----------

    async fn fetch_catalog(&self, m: &Manifest, kind: &str, catalog_id: &str, extra: &[(String, String)]) -> Result<Vec<MetaPreview>, CoreError> {
        let url = qb_protocol::resource_url(&m.transport_url, "catalog", kind, catalog_id, extra);
        let v = self.cached_json(CacheKind::Catalog, &url).await?;
        Ok(qb_protocol::parse_metas(&v, &m.name, MediaKind::parse(kind).unwrap_or(MediaKind::Movie)))
    }

    /// رفوف الرئيسية: كل كتالوج ما يحتاج extra إجباري، بالتوازي، بترتيب الإضافات
    pub async fn home_rows(&self) -> Result<Vec<CatalogRow>, CoreError> {
        let mut jobs: Vec<(Manifest, CatalogDef)> = Vec::new();
        for m in self.enabled_addons() {
            for c in m.catalogs.iter().filter(|c| !c.requires_extra && MediaKind::parse(&c.kind).is_some()) {
                if jobs.len() < MAX_HOME_ROWS {
                    jobs.push((m.clone(), c.clone()));
                }
            }
        }
        let fut = async {
            let mut set = JoinSet::new();
            for (i, (m, c)) in jobs.into_iter().enumerate() {
                let me = self.clone();
                set.spawn(async move {
                    let items = me.fetch_catalog(&m, &c.kind, &c.id, &[]).await;
                    (i, m, c, items)
                });
            }
            let mut rows: Vec<(usize, CatalogRow)> = Vec::new();
            while let Some(res) = set.join_next().await {
                let Ok((i, m, c, Ok(items))) = res else { continue };
                if items.is_empty() {
                    continue;
                }
                rows.push((i, CatalogRow {
                    addon_id: m.id.clone(),
                    addon_name: m.name.clone(),
                    catalog_id: c.id.clone(),
                    kind: MediaKind::parse(&c.kind).unwrap_or(MediaKind::Movie),
                    title: row_title(&c),
                    items,
                }));
            }
            rows.sort_by_key(|(i, _)| *i);
            Ok(rows.into_iter().map(|(_, r)| r).collect())
        };
        self.cancellable(fut).await
    }

    pub fn discover_catalogs(&self) -> Vec<DiscoverCatalog> {
        let mut out = Vec::new();
        for m in self.enabled_addons() {
            for c in m.catalogs.iter().filter(|c| MediaKind::parse(&c.kind).is_some()) {
                // اللي يحتاج search إجباري مكانه البحث مو اكتشف
                if c.requires_extra && c.supports_search && !c.supports_genre {
                    continue;
                }
                out.push(DiscoverCatalog { addon_url: m.transport_url.clone(), addon_name: m.name.clone(), catalog: c.clone() });
            }
        }
        out
    }

    pub async fn catalog_page(&self, addon_url: &str, kind: &str, catalog_id: &str, genre: Option<String>, skip: u32) -> Result<Vec<MetaPreview>, CoreError> {
        let m = self.addons()?.into_iter().find(|a| a.transport_url == addon_url).ok_or_else(|| CoreError::addon("addon not installed"))?;
        let mut extra = Vec::new();
        if let Some(g) = genre.filter(|g| !g.is_empty()) {
            extra.push(("genre".to_string(), g));
        }
        if skip > 0 {
            extra.push(("skip".to_string(), skip.to_string()));
        }
        self.cancellable(self.fetch_catalog(&m, kind, catalog_id, &extra)).await
    }

    /// بحث في كل كتالوج يدعم search، ويبلّغ بكل رف أول ما يوصل
    pub async fn search(&self, query: &str, on_row: impl Fn(CatalogRow) + Send + Sync + 'static) -> Result<Vec<CatalogRow>, CoreError> {
        let q = query.trim().to_string();
        if q.is_empty() {
            return Ok(vec![]);
        }
        let on_row = Arc::new(on_row);
        let fut = async {
            let mut set = JoinSet::new();
            let mut idx = 0usize;
            for m in self.enabled_addons() {
                for c in m.catalogs.iter().filter(|c| c.supports_search && MediaKind::parse(&c.kind).is_some()) {
                    let (me, m, c, q, cb, i) = (self.clone(), m.clone(), c.clone(), q.clone(), on_row.clone(), idx);
                    idx += 1;
                    set.spawn(async move {
                        let items = me.fetch_catalog(&m, &c.kind, &c.id, &[("search".to_string(), q)]).await.ok()?;
                        if items.is_empty() {
                            return None;
                        }
                        let row = CatalogRow {
                            addon_id: m.id.clone(),
                            addon_name: m.name.clone(),
                            catalog_id: c.id.clone(),
                            kind: MediaKind::parse(&c.kind).unwrap_or(MediaKind::Movie),
                            title: row_title(&c),
                            items,
                        };
                        cb(row.clone());
                        Some((i, row))
                    });
                }
            }
            let mut rows = Vec::new();
            while let Some(r) = set.join_next().await {
                if let Ok(Some(x)) = r {
                    rows.push(x);
                }
            }
            rows.sort_by_key(|(i, _)| *i);
            Ok(rows.into_iter().map(|(_, r)| r).collect())
        };
        self.cancellable(fut).await
    }

    /// البحث حسب الخطة: كل النتايج في قائمة وحدة بدون تكرار
    pub async fn search_flat(&self, query: &str) -> Result<Vec<MetaPreview>, CoreError> {
        let rows = self.search(query, |_| {}).await?;
        Ok(flatten_unique(rows.into_iter().flat_map(|r| r.items), None, usize::MAX))
    }

    /// المشابه: كتالوج يدعم التصنيف بنفس نوع العمل وأول تصنيف فيه، وإلا أول كتالوج من نفس النوع
    pub async fn similar(&self, kind: MediaKind, id: &str) -> Result<Vec<MetaPreview>, CoreError> {
        let genres = self.meta(kind, id).await.map(|m| m.genres).unwrap_or_default();
        let addons = self.enabled_addons();
        let fut = async {
            for g in genres.iter().take(2) {
                for m in &addons {
                    for c in m.catalogs.iter().filter(|c| c.kind == kind.as_str() && c.supports_genre && (c.genres.is_empty() || c.genres.iter().any(|x| x.eq_ignore_ascii_case(g)))) {
                        let genre = c.genres.iter().find(|x| x.eq_ignore_ascii_case(g)).cloned().unwrap_or_else(|| g.clone());
                        if let Ok(items) = self.fetch_catalog(m, &c.kind, &c.id, &[("genre".to_string(), genre)]).await {
                            let list = flatten_unique(items, Some(id), 20);
                            if !list.is_empty() {
                                return Ok(list);
                            }
                        }
                    }
                }
            }
            for m in &addons {
                for c in m.catalogs.iter().filter(|c| c.kind == kind.as_str() && !c.requires_extra) {
                    if let Ok(items) = self.fetch_catalog(m, &c.kind, &c.id, &[]).await {
                        let list = flatten_unique(items, Some(id), 20);
                        if !list.is_empty() {
                            return Ok(list);
                        }
                    }
                }
            }
            Ok(vec![])
        };
        self.cancellable(fut).await
    }

    // ---------- التفاصيل ----------

    pub async fn meta(&self, kind: MediaKind, id: &str) -> Result<MetaDetail, CoreError> {
        let fut = async {
            let mut last_err = CoreError::addon("no addon provides meta for this title");
            for m in self.enabled_addons().iter().filter(|m| manifest_supports(m, "meta", kind.as_str(), id)) {
                let url = qb_protocol::resource_url(&m.transport_url, "meta", kind.as_str(), id, &[]);
                match self.cached_json(CacheKind::Meta, &url).await {
                    Ok(v) => {
                        if let Some(d) = qb_protocol::parse_meta_detail(&v, &m.name, kind) {
                            return Ok(d);
                        }
                    }
                    Err(e) => last_err = e,
                }
            }
            Err(last_err)
        };
        self.cancellable(fut).await
    }

    /// الحلقة اللي بعد الحالية (للتشغيل التلقائي)
    pub fn next_episode(meta: &MetaDetail, current_id: &str) -> Option<Video> {
        let i = meta.videos.iter().position(|v| v.id == current_id)?;
        meta.videos.get(i + 1).cloned()
    }

    // ---------- المصادر ----------

    /// يجمع المصادر من كل إضافة بالتوازي، وأول ما توصل إضافة تنرسل القائمة المرتبة (on_sources).
    /// بعدين فحص الصحة 4 بالمرة: كل نتيجة تنرسل (on_health) ومعها القائمة بترتيبها الجديد،
    /// وفي الآخر on_finished. النتيجة النهائية ترجع بعد.
    pub async fn load_sources_with(&self, kind: MediaKind, id: &str, probe: bool, events: Arc<dyn SourceEvents>) -> Result<Vec<RankedSource>, CoreError> {
        let addons: Vec<(usize, Manifest)> =
            self.enabled_addons().into_iter().filter(|m| manifest_supports(m, "stream", kind.as_str(), id)).enumerate().collect();
        let id = id.to_string();
        let ev = events.clone();
        let prefs = self.prefs();
        let fut = async move {
            let mut list: Vec<RankedSource> = Vec::new();
            let mut set: JoinSet<Phase> = JoinSet::new();
            for (rank, m) in addons {
                let (me, id) = (self.clone(), id.clone());
                set.spawn(async move {
                    let url = qb_protocol::resource_url(&m.transport_url, "stream", kind.as_str(), &id, &[]);
                    let raws = match me.cached_json(CacheKind::Stream, &url).await {
                        Ok(v) => qb_protocol::parse_streams(&v, &m.name),
                        Err(_) => vec![],
                    };
                    let mut ranked = Vec::with_capacity(raws.len());
                    for r in &raws {
                        let mem = me.inner.store.source_memory(&qb_sources::source_id(&r.target)).ok().flatten();
                        let mut s = qb_sources::rank_raw(r, mem.as_ref(), rank);
                        // نتيجة فحص من آخر 10 دقايق؟ نستخدمها بدل ما نفحص من جديد
                        if let Some((h, e)) = me.inner.health.get(&s.id).await {
                            s.health = h;
                            s.engine = e;
                            s.score = qb_sources::score(s.quality, s.engine, &s.health, mem.as_ref(), rank);
                        }
                        qb_sources::apply_prefs(&mut s, prefs);
                        ranked.push(s);
                    }
                    Phase::Fetched(rank, ranked)
                });
            }
            while let Some(res) = set.join_next().await {
                match res {
                    Ok(Phase::Fetched(rank, ranked)) => {
                        for s in &ranked {
                            if probe && matches!(s.health, Health::Checking) {
                                let (me, s) = (self.clone(), s.clone());
                                set.spawn(async move {
                                    let _permit = me.inner.probes.clone().acquire_owned().await;
                                    let mem = me.inner.store.source_memory(&s.id).ok().flatten();
                                    let mut p = qb_sources::probe(&me.inner.client.net, &s, mem.as_ref(), rank).await;
                                    me.inner.health.put(&p.id, p.health.clone(), p.engine).await;
                                    qb_sources::apply_prefs(&mut p, prefs);
                                    Phase::Probed(p)
                                });
                            }
                        }
                        list.extend(ranked);
                    }
                    Ok(Phase::Probed(p)) => {
                        ev.on_health(p.id.clone(), p.health.clone());
                        if let Some(slot) = list.iter_mut().find(|s| s.id == p.id) {
                            *slot = p;
                        }
                    }
                    Err(_) => continue,
                }
                qb_sources::sort_and_dedupe(&mut list);
                ev.on_sources(list.clone());
            }
            Ok(list)
        };
        let r = self.cancellable(fut).await;
        events.on_finished();
        r
    }

    /// الجودة المفضلة والمشغّل المفضل من الإعدادات
    pub fn prefs(&self) -> qb_sources::Prefs {
        let get = |k: &str| self.inner.store.setting(k).ok().flatten().unwrap_or_default();
        qb_sources::Prefs { quality: get("preferred_quality").parse().unwrap_or(0), force_vlc: get("preferred_engine") == "vlc" }
    }

    /// نفس اللي فوق بس بدالة وحدة (للاختبارات والأدوات)
    pub async fn load_sources(
        &self,
        kind: MediaKind,
        id: &str,
        probe: bool,
        on_update: impl Fn(Vec<RankedSource>) + Send + Sync + 'static,
    ) -> Result<Vec<RankedSource>, CoreError> {
        struct F<T>(T);
        impl<T: Fn(Vec<RankedSource>) + Send + Sync> SourceEvents for F<T> {
            fn on_sources(&self, s: Vec<RankedSource>) {
                (self.0)(s)
            }
            fn on_health(&self, _: String, _: Health) {}
            fn on_finished(&self) {}
        }
        self.load_sources_with(kind, id, probe, Arc::new(F(on_update))).await
    }

    /// جولة الإضافات: تقرير لكل إضافة كم مصدر شغال وبأي مشغّل
    pub async fn addon_report(&self, kind: MediaKind, id: &str) -> Result<Vec<AddonReport>, CoreError> {
        let list = self.load_sources(kind, id, true, |_| {}).await?;
        Ok(qb_sources::report(&list))
    }

    // ---------- الترجمات ----------

    pub async fn subtitles(&self, kind: MediaKind, id: &str) -> Result<Vec<SubtitleTrack>, CoreError> {
        let preferred = self.inner.store.setting("subtitle_lang").ok().flatten().unwrap_or_else(|| "ara".into());
        let addons: Vec<Manifest> = self.enabled_addons().into_iter().filter(|m| manifest_supports(m, "subtitles", kind.as_str(), id)).collect();
        let id = id.to_string();
        let fut = async move {
            let mut set = JoinSet::new();
            for m in addons {
                let (me, id) = (self.clone(), id.clone());
                set.spawn(async move {
                    let url = qb_protocol::resource_url(&m.transport_url, "subtitles", kind.as_str(), &id, &[]);
                    me.cached_json(CacheKind::Subtitles, &url).await.map(|v| qb_protocol::parse_subtitles(&v, &m.name)).unwrap_or_default()
                });
            }
            let mut all = Vec::new();
            while let Some(r) = set.join_next().await {
                all.extend(r.unwrap_or_default());
            }
            sort_subtitles(&mut all, &preferred);
            Ok(all)
        };
        self.cancellable(fut).await
    }

    /// ينزّل ملف ترجمة ويحلله (SRT / VTT / ASS، أي ترميز)
    pub async fn load_subtitle(&self, url: &str) -> Result<Vec<Cue>, CoreError> {
        let fut = async {
            let bytes = self.inner.client.net.get_bytes(url).await?;
            Ok(qb_subs::parse_bytes(&bytes, Some(url)))
        };
        self.cancellable(fut).await
    }

    // ---------- تصدير / استيراد المكتبة ----------

    pub fn export_library(&self) -> Result<String, CoreError> {
        self.inner.store.export_json()
    }

    /// يستورد الملف ويثبّت الإضافات اللي فيه (اللي تفشل تنتجاهل). يرجّع عدد العناصر.
    pub async fn import_library(&self, json: String) -> Result<u32, CoreError> {
        let (count, addons) = self.write(move |s| s.import_json(&json)).await?;
        let mut n = count;
        for url in addons {
            if self.install_addon(&url).await.is_ok() {
                n += 1;
            }
        }
        Ok(n)
    }

    // ---------- مهلة عامة ----------

    pub async fn with_timeout<T>(fut: impl std::future::Future<Output = Result<T, CoreError>>, secs: u64) -> Result<T, CoreError> {
        tokio::time::timeout(Duration::from_secs(secs), fut).await.map_err(|_| CoreError::network("timeout"))?
    }
}

enum Phase {
    Fetched(usize, Vec<RankedSource>),
    Probed(RankedSource),
}

/// يدمج قوائم بدون تكرار، ويستبعد عنوان معيّن، وبحد أقصى
pub fn flatten_unique(items: impl IntoIterator<Item = MetaPreview>, exclude: Option<&str>, limit: usize) -> Vec<MetaPreview> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for it in items {
        if Some(it.id.as_str()) == exclude || !seen.insert(it.id.clone()) {
            continue;
        }
        out.push(it);
        if out.len() >= limit {
            break;
        }
    }
    out
}

fn row_title(c: &CatalogDef) -> String {
    let kind = match c.kind.as_str() {
        "movie" => "أفلام",
        "series" => "مسلسلات",
        _ => "",
    };
    let name = match c.name.to_ascii_lowercase().as_str() {
        "popular" => "الأكثر شهرة".to_string(),
        "new" => "الجديد".to_string(),
        "featured" => "مختارات".to_string(),
        "top" => "الأعلى تقييمًا".to_string(),
        "imdb rating" => "الأعلى على IMDb".to_string(),
        _ => c.name.clone(),
    };
    if kind.is_empty() { name } else { format!("{name} · {kind}") }
}

/// اللغة المفضلة أول، بعدين الإنجليزية، بعدين الباقي
pub fn sort_subtitles(list: &mut Vec<SubtitleTrack>, preferred: &str) {
    let pref = lang_family(preferred);
    let mut seen = std::collections::HashSet::new();
    list.retain(|s| seen.insert(s.url.clone()));
    list.sort_by_key(|s| {
        let f = lang_family(&s.lang);
        if f == pref {
            0
        } else if f == "en" {
            1
        } else {
            2
        }
    });
}

pub fn lang_family(code: &str) -> &'static str {
    match code.to_ascii_lowercase().as_str() {
        "ar" | "ara" | "arabic" | "عربي" => "ar",
        "en" | "eng" | "english" => "en",
        "fr" | "fre" | "fra" | "french" => "fr",
        "es" | "spa" | "spanish" => "es",
        "tr" | "tur" | "turkish" => "tr",
        _ => "other",
    }
}

#[cfg(test)]
mod tests;
