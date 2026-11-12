//! كاش بالذاكرة (moka) + على القرص، مع مدة صلاحية لكل مورد.
use moka::future::Cache as Moka;
use serde_json::Value;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Manifest,
    Catalog,
    Meta,
    Stream,
    Subtitles,
}

impl Kind {
    /// مدة الصلاحية لكل نوع
    pub fn ttl(&self) -> Duration {
        match self {
            Kind::Manifest => Duration::from_secs(6 * 3600),
            Kind::Catalog => Duration::from_secs(30 * 60),
            Kind::Meta => Duration::from_secs(24 * 3600),
            Kind::Stream => Duration::from_secs(5 * 60),
            Kind::Subtitles => Duration::from_secs(6 * 3600),
        }
    }
    fn tag(&self) -> &'static str {
        match self {
            Kind::Manifest => "manifest",
            Kind::Catalog => "catalog",
            Kind::Meta => "meta",
            Kind::Stream => "stream",
            Kind::Subtitles => "subtitles",
        }
    }
}

#[derive(Clone)]
struct Entry {
    value: Value,
    expires_at: u64,
}

pub struct Cache {
    mem: Moka<String, Entry>,
    dir: Option<PathBuf>,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn hash(s: &str) -> String {
    // FNV-1a 64: اسم ملف ثابت لكل رابط بدون مكتبة إضافية
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

impl Cache {
    /// dir = None: ذاكرة بس (للاختبارات)
    pub fn new(dir: Option<PathBuf>) -> Self {
        if let Some(d) = &dir {
            let _ = std::fs::create_dir_all(d);
        }
        Cache { mem: Moka::builder().max_capacity(2_000).time_to_live(Duration::from_secs(24 * 3600)).build(), dir }
    }

    fn file(&self, kind: Kind, key: &str) -> Option<PathBuf> {
        self.dir.as_ref().map(|d| d.join(format!("{}-{}.json", kind.tag(), hash(key))))
    }

    pub async fn get(&self, kind: Kind, key: &str) -> Option<Value> {
        let k = format!("{}:{key}", kind.tag());
        if let Some(e) = self.mem.get(&k).await {
            if e.expires_at > now() {
                return Some(e.value);
            }
            self.mem.invalidate(&k).await;
        }
        // القرص (بس للأشياء اللي تستاهل)
        if kind == Kind::Stream {
            return None;
        }
        let path = self.file(kind, key)?;
        let raw = std::fs::read(&path).ok()?;
        let v: Value = serde_json::from_slice(&raw).ok()?;
        let expires_at = v.get("expires_at")?.as_u64()?;
        if expires_at <= now() {
            let _ = std::fs::remove_file(&path);
            return None;
        }
        let value = v.get("value")?.clone();
        self.mem.insert(k, Entry { value: value.clone(), expires_at }).await;
        Some(value)
    }

    pub async fn put(&self, kind: Kind, key: &str, value: Value) {
        let expires_at = now() + kind.ttl().as_secs();
        self.mem.insert(format!("{}:{key}", kind.tag()), Entry { value: value.clone(), expires_at }).await;
        if kind == Kind::Stream {
            return;
        }
        if let Some(path) = self.file(kind, key) {
            let body = serde_json::json!({ "expires_at": expires_at, "value": value });
            let tmp = path.with_extension("tmp");
            if std::fs::write(&tmp, body.to_string()).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }

    /// مسح الكاش كله (من الإعدادات)
    pub async fn clear(&self) {
        self.mem.invalidate_all();
        if let Some(d) = &self.dir
            && let Ok(rd) = std::fs::read_dir(d) {
                for e in rd.flatten() {
                    let _ = std::fs::remove_file(e.path());
                }
            }
    }

    /// حجم الكاش على القرص بالبايت
    pub fn disk_size(&self) -> u64 {
        let Some(d) = &self.dir else { return 0 };
        std::fs::read_dir(d).map(|rd| rd.flatten().filter_map(|e| e.metadata().ok()).map(|m| m.len()).sum()).unwrap_or(0)
    }
}

/// نتيجة فحص الصحة تنحفظ 10 دقايق (ذاكرة بس)
pub struct HealthCache {
    mem: Moka<String, (qb_model::Health, qb_model::Engine)>,
}

impl Default for HealthCache {
    fn default() -> Self {
        Self::new()
    }
}

impl HealthCache {
    pub const TTL: Duration = Duration::from_secs(10 * 60);
    pub fn new() -> Self {
        HealthCache { mem: Moka::builder().max_capacity(5_000).time_to_live(Self::TTL).build() }
    }
    pub async fn get(&self, source_id: &str) -> Option<(qb_model::Health, qb_model::Engine)> {
        self.mem.get(source_id).await
    }
    pub async fn put(&self, source_id: &str, health: qb_model::Health, engine: qb_model::Engine) {
        self.mem.insert(source_id.to_string(), (health, engine)).await;
    }
    pub fn clear(&self) {
        self.mem.invalidate_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn memory_roundtrip() {
        let c = Cache::new(None);
        assert!(c.get(Kind::Meta, "a").await.is_none());
        c.put(Kind::Meta, "a", json!({"x": 1})).await;
        assert_eq!(c.get(Kind::Meta, "a").await, Some(json!({"x": 1})));
        assert!(c.get(Kind::Catalog, "a").await.is_none());
    }

    #[tokio::test]
    async fn disk_survives_new_instance() {
        let dir = std::env::temp_dir().join(format!("qb-cache-test-{}", std::process::id()));
        {
            let c = Cache::new(Some(dir.clone()));
            c.put(Kind::Catalog, "k", json!([1, 2])).await;
            c.put(Kind::Stream, "s", json!(1)).await;
            assert!(c.disk_size() > 0);
        }
        let c = Cache::new(Some(dir.clone()));
        assert_eq!(c.get(Kind::Catalog, "k").await, Some(json!([1, 2])));
        assert!(c.get(Kind::Stream, "s").await.is_none(), "streams never hit disk");
        c.clear().await;
        assert!(c.get(Kind::Catalog, "k").await.is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn health_cache_roundtrip() {
        let h = HealthCache::new();
        assert!(h.get("u").await.is_none());
        h.put("u", qb_model::Health::Unreachable, qb_model::Engine::Vlc).await;
        assert_eq!(h.get("u").await, Some((qb_model::Health::Unreachable, qb_model::Engine::Vlc)));
        assert_eq!(HealthCache::TTL.as_secs(), 600);
    }

    #[test]
    fn ttls_are_sane() {
        assert!(Kind::Stream.ttl() < Kind::Catalog.ttl());
        assert!(Kind::Catalog.ttl() < Kind::Meta.ttl());
        assert_eq!(hash("a"), hash("a"));
        assert_ne!(hash("a"), hash("b"));
    }
}
