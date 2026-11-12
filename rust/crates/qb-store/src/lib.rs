//! التخزين: SQLite (WAL) مع migrations مرقّمة.
//! تقدّم المشاهدة، السجل، مكتبتي، الإضافات، الإعدادات، وذاكرة المصادر.
use qb_model::*;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::Mutex;

const MIGRATIONS: &[&str] = &[
    // 1
    "CREATE TABLE IF NOT EXISTS progress (
        media_id TEXT PRIMARY KEY,
        episode_id TEXT,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        poster TEXT,
        position_s REAL NOT NULL,
        duration_s REAL,
        updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS library (
        media_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        poster TEXT,
        added_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        media_id TEXT NOT NULL,
        title TEXT NOT NULL,
        poster TEXT,
        kind TEXT NOT NULL,
        source_id TEXT NOT NULL,
        engine TEXT NOT NULL,
        watched_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS history_time ON history(watched_at DESC);
    CREATE TABLE IF NOT EXISTS addons (
        transport_url TEXT PRIMARY KEY,
        manifest_json TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS source_memory (
        url_hash TEXT PRIMARY KEY,
        needs_vlc INTEGER NOT NULL DEFAULT 0,
        fail_count INTEGER NOT NULL DEFAULT 0,
        last_ok INTEGER
    );",
    // 2: مؤشر لأحدث تقدّم
    "CREATE INDEX IF NOT EXISTS progress_time ON progress(updated_at DESC);",
];

pub struct Store {
    conn: Mutex<Connection>,
}

fn st(e: rusqlite::Error) -> CoreError {
    CoreError::storage(e)
}

fn kind_str(k: MediaKind) -> &'static str {
    k.as_str()
}
fn kind_of(s: &str) -> MediaKind {
    MediaKind::parse(s).unwrap_or(MediaKind::Movie)
}
fn engine_str(e: Engine) -> &'static str {
    match e {
        Engine::Native => "native",
        Engine::Vlc => "vlc",
        Engine::YouTube => "youtube",
        Engine::External => "external",
    }
}
fn engine_of(s: &str) -> Engine {
    match s {
        "vlc" => Engine::Vlc,
        "youtube" => Engine::YouTube,
        "external" => Engine::External,
        _ => Engine::Native,
    }
}

/// ذاكرة المصدر تنحفظ بهاش الرابط مو الرابط نفسه (FNV-1a 64)
pub fn url_hash(url: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in url.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

impl Store {
    pub fn open(path: &str) -> Result<Store, CoreError> {
        let conn = Connection::open(path).map_err(st)?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Store, CoreError> {
        Self::init(Connection::open_in_memory().map_err(st)?)
    }

    fn init(conn: Connection) -> Result<Store, CoreError> {
        // WAL ما ينطبق على الذاكرة، وهذا عادي
        let _ = conn.pragma_update(None, "journal_mode", "WAL");
        conn.pragma_update(None, "synchronous", "NORMAL").map_err(st)?;
        conn.busy_timeout(std::time::Duration::from_secs(3)).map_err(st)?;
        let s = Store { conn: Mutex::new(conn) };
        s.migrate()?;
        Ok(s)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        // لو خيط طاح وهو ماسك القفل، نكمل بدل ما نطيح كلنا
        self.conn.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn migrate(&self) -> Result<(), CoreError> {
        let c = self.lock();
        let version: i64 = c.pragma_query_value(None, "user_version", |r| r.get(0)).map_err(st)?;
        for (i, sql) in MIGRATIONS.iter().enumerate() {
            let v = (i + 1) as i64;
            if v > version {
                c.execute_batch(&format!("BEGIN; {sql} PRAGMA user_version = {v}; COMMIT;")).map_err(st)?;
            }
        }
        Ok(())
    }

    pub fn schema_version(&self) -> i64 {
        self.lock().pragma_query_value(None, "user_version", |r| r.get(0)).unwrap_or(0)
    }

    // ---------- progress ----------

    pub fn save_progress(&self, p: &Progress) -> Result<(), CoreError> {
        self.lock()
            .execute(
                "INSERT INTO progress (media_id, episode_id, kind, title, poster, position_s, duration_s, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(media_id) DO UPDATE SET episode_id=?2, kind=?3, title=?4, poster=?5, position_s=?6, duration_s=?7, updated_at=?8",
                params![p.media_id, p.episode_id, kind_str(p.kind), p.title, p.poster, p.position_s, p.duration_s, p.updated_at],
            )
            .map_err(st)?;
        Ok(())
    }

    pub fn progress(&self, media_id: &str) -> Result<Option<Progress>, CoreError> {
        self.lock()
            .query_row(
                "SELECT media_id, episode_id, kind, title, poster, position_s, duration_s, updated_at FROM progress WHERE media_id = ?1",
                params![media_id],
                row_progress,
            )
            .optional()
            .map_err(st)
    }

    /// كمّل المشاهدة: اللي ما خلصت (أقل من 95%) أو مدتها مجهولة
    pub fn continue_watching(&self, limit: u32) -> Result<Vec<Progress>, CoreError> {
        let c = self.lock();
        let mut stmt = c
            .prepare(
                "SELECT media_id, episode_id, kind, title, poster, position_s, duration_s, updated_at FROM progress
                 WHERE position_s > 5 AND (duration_s IS NULL OR duration_s <= 0 OR position_s < duration_s * 0.95)
                 ORDER BY updated_at DESC LIMIT ?1",
            )
            .map_err(st)?;
        let rows = stmt.query_map(params![limit], row_progress).map_err(st)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(st)
    }

    pub fn remove_progress(&self, media_id: &str) -> Result<(), CoreError> {
        self.lock().execute("DELETE FROM progress WHERE media_id = ?1", params![media_id]).map_err(st)?;
        Ok(())
    }

    // ---------- library ----------

    pub fn add_to_library(&self, item: &LibraryItem) -> Result<(), CoreError> {
        self.lock()
            .execute(
                "INSERT OR REPLACE INTO library (media_id, kind, title, poster, added_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![item.media_id, kind_str(item.kind), item.title, item.poster, item.added_at],
            )
            .map_err(st)?;
        Ok(())
    }

    pub fn remove_from_library(&self, media_id: &str) -> Result<(), CoreError> {
        self.lock().execute("DELETE FROM library WHERE media_id = ?1", params![media_id]).map_err(st)?;
        Ok(())
    }

    pub fn in_library(&self, media_id: &str) -> Result<bool, CoreError> {
        let n: i64 = self
            .lock()
            .query_row("SELECT COUNT(*) FROM library WHERE media_id = ?1", params![media_id], |r| r.get(0))
            .map_err(st)?;
        Ok(n > 0)
    }

    pub fn library(&self) -> Result<Vec<LibraryItem>, CoreError> {
        let c = self.lock();
        let mut stmt = c.prepare("SELECT media_id, kind, title, poster, added_at FROM library ORDER BY added_at DESC").map_err(st)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(LibraryItem {
                    media_id: r.get(0)?,
                    kind: kind_of(&r.get::<_, String>(1)?),
                    title: r.get(2)?,
                    poster: r.get(3)?,
                    added_at: r.get(4)?,
                })
            })
            .map_err(st)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(st)
    }

    // ---------- history ----------

    pub fn add_history(&self, h: &HistoryEntry) -> Result<(), CoreError> {
        let c = self.lock();
        c.execute(
            "INSERT INTO history (media_id, title, poster, kind, source_id, engine, watched_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![h.media_id, h.title, h.poster, kind_str(h.kind), h.source_id, engine_str(h.engine), h.watched_at],
        )
        .map_err(st)?;
        // نخلي آخر 500 بس
        c.execute("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY watched_at DESC, id DESC LIMIT 500)", []).map_err(st)?;
        Ok(())
    }

    pub fn history(&self, limit: u32) -> Result<Vec<HistoryEntry>, CoreError> {
        let c = self.lock();
        let mut stmt = c
            .prepare("SELECT media_id, title, poster, kind, source_id, engine, watched_at FROM history ORDER BY watched_at DESC, id DESC LIMIT ?1")
            .map_err(st)?;
        let rows = stmt
            .query_map(params![limit], |r| {
                Ok(HistoryEntry {
                    media_id: r.get(0)?,
                    title: r.get(1)?,
                    poster: r.get(2)?,
                    kind: kind_of(&r.get::<_, String>(3)?),
                    source_id: r.get(4)?,
                    engine: engine_of(&r.get::<_, String>(5)?),
                    watched_at: r.get(6)?,
                })
            })
            .map_err(st)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(st)
    }

    pub fn clear_history(&self) -> Result<(), CoreError> {
        self.lock().execute("DELETE FROM history", []).map_err(st)?;
        Ok(())
    }

    // ---------- addons ----------

    pub fn save_addon(&self, m: &Manifest) -> Result<(), CoreError> {
        let json = manifest_to_json(m).to_string();
        let c = self.lock();
        let next: i64 = c.query_row("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM addons", [], |r| r.get(0)).map_err(st)?;
        c.execute(
            "INSERT INTO addons (transport_url, manifest_json, enabled, sort_order) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(transport_url) DO UPDATE SET manifest_json = ?2",
            params![m.transport_url, json, m.enabled as i64, next],
        )
        .map_err(st)?;
        Ok(())
    }

    pub fn addons(&self) -> Result<Vec<Manifest>, CoreError> {
        let c = self.lock();
        let mut stmt = c.prepare("SELECT transport_url, manifest_json, enabled FROM addons ORDER BY sort_order ASC").map_err(st)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)))
            .map_err(st)?;
        let mut out = Vec::new();
        for row in rows {
            let (url, json, enabled) = row.map_err(st)?;
            // سجل خربان ما يخرب الباقي
            if let Some(mut m) = serde_json::from_str::<serde_json::Value>(&json).ok().and_then(|v| manifest_from_json(&v, &url)) {
                m.enabled = enabled != 0;
                out.push(m);
            }
        }
        Ok(out)
    }

    pub fn set_addon_enabled(&self, transport_url: &str, enabled: bool) -> Result<(), CoreError> {
        self.lock()
            .execute("UPDATE addons SET enabled = ?2 WHERE transport_url = ?1", params![transport_url, enabled as i64])
            .map_err(st)?;
        Ok(())
    }

    pub fn remove_addon(&self, transport_url: &str) -> Result<(), CoreError> {
        self.lock().execute("DELETE FROM addons WHERE transport_url = ?1", params![transport_url]).map_err(st)?;
        Ok(())
    }

    pub fn reorder_addons(&self, ordered_urls: &[String]) -> Result<(), CoreError> {
        let mut c = self.lock();
        let tx = c.transaction().map_err(st)?;
        for (i, u) in ordered_urls.iter().enumerate() {
            tx.execute("UPDATE addons SET sort_order = ?2 WHERE transport_url = ?1", params![u, i as i64]).map_err(st)?;
        }
        tx.commit().map_err(st)?;
        Ok(())
    }

    // ---------- settings ----------

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), CoreError> {
        self.lock()
            .execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2)", params![key, value])
            .map_err(st)?;
        Ok(())
    }

    pub fn setting(&self, key: &str) -> Result<Option<String>, CoreError> {
        self.lock()
            .query_row("SELECT value FROM settings WHERE key = ?1", params![key], |r| r.get(0))
            .optional()
            .map_err(st)
    }

    // ---------- source memory ----------

    pub fn source_memory(&self, source_id: &str) -> Result<Option<SourceMemory>, CoreError> {
        self.lock()
            .query_row(
                "SELECT needs_vlc, fail_count, last_ok FROM source_memory WHERE url_hash = ?1",
                params![url_hash(source_id)],
                |r| Ok(SourceMemory { needs_vlc: r.get::<_, i64>(0)? != 0, fail_count: r.get::<_, i64>(1)?.max(0) as u32, last_ok: r.get(2)? }),
            )
            .optional()
            .map_err(st)
    }

    pub fn mark_source_ok(&self, source_id: &str, engine: Engine) -> Result<(), CoreError> {
        self.lock()
            .execute(
                "INSERT INTO source_memory (url_hash, needs_vlc, fail_count, last_ok) VALUES (?1, ?2, 0, ?3)
                 ON CONFLICT(url_hash) DO UPDATE SET needs_vlc = MAX(needs_vlc, ?2), fail_count = 0, last_ok = ?3",
                params![url_hash(source_id), (engine == Engine::Vlc) as i64, now()],
            )
            .map_err(st)?;
        Ok(())
    }

    pub fn mark_source_failed(&self, source_id: &str, native_failed: bool) -> Result<(), CoreError> {
        self.lock()
            .execute(
                "INSERT INTO source_memory (url_hash, needs_vlc, fail_count, last_ok) VALUES (?1, ?2, 1, NULL)
                 ON CONFLICT(url_hash) DO UPDATE SET needs_vlc = MAX(needs_vlc, ?2), fail_count = fail_count + 1",
                params![url_hash(source_id), native_failed as i64],
            )
            .map_err(st)?;
        Ok(())
    }
}

impl Store {
    /// تصدير المكتبة كملف (بدل iCloud): المكتبة، التقدّم، السجل، روابط الإضافات
    pub fn export_json(&self) -> Result<String, CoreError> {
        let lib: Vec<serde_json::Value> = self
            .library()?
            .into_iter()
            .map(|i| serde_json::json!({"media_id": i.media_id, "kind": kind_str(i.kind), "title": i.title, "poster": i.poster, "added_at": i.added_at}))
            .collect();
        let prog: Vec<serde_json::Value> = {
            let c = self.lock();
            let mut stmt = c
                .prepare("SELECT media_id, episode_id, kind, title, poster, position_s, duration_s, updated_at FROM progress ORDER BY updated_at DESC")
                .map_err(st)?;
            let rows = stmt.query_map([], row_progress).map_err(st)?;
            rows.filter_map(|r| r.ok())
                .map(|p| serde_json::json!({"media_id": p.media_id, "episode_id": p.episode_id, "kind": kind_str(p.kind), "title": p.title, "poster": p.poster, "position_s": p.position_s, "duration_s": p.duration_s, "updated_at": p.updated_at}))
                .collect()
        };
        let hist: Vec<serde_json::Value> = self
            .history(500)?
            .into_iter()
            .map(|h| serde_json::json!({"media_id": h.media_id, "title": h.title, "poster": h.poster, "kind": kind_str(h.kind), "source_id": h.source_id, "engine": engine_str(h.engine), "watched_at": h.watched_at}))
            .collect();
        let addons: Vec<String> = self.addons()?.into_iter().map(|a| a.transport_url).collect();
        Ok(serde_json::json!({"app": "QB", "format": 1, "exported_at": now(), "library": lib, "progress": prog, "history": hist, "addons": addons}).to_string())
    }

    /// استيراد ملف تصدير. يرجّع روابط الإضافات اللي في الملف عشان النواة تثبّتها.
    pub fn import_json(&self, json: &str) -> Result<(u32, Vec<String>), CoreError> {
        let v: serde_json::Value = serde_json::from_str(json).map_err(|e| CoreError::storage(format!("bad file: {e}")))?;
        if v.get("app").and_then(|a| a.as_str()) != Some("QB") {
            return Err(CoreError::storage("not a QB export file"));
        }
        let s = |x: &serde_json::Value, k: &str| x.get(k).and_then(|y| y.as_str()).map(String::from);
        let i = |x: &serde_json::Value, k: &str| x.get(k).and_then(|y| y.as_i64()).unwrap_or(0);
        let mut count = 0u32;
        for x in v.get("library").and_then(|a| a.as_array()).cloned().unwrap_or_default() {
            let (Some(id), Some(title)) = (s(&x, "media_id"), s(&x, "title")) else { continue };
            self.add_to_library(&LibraryItem { media_id: id, kind: kind_of(&s(&x, "kind").unwrap_or_default()), title, poster: s(&x, "poster"), added_at: i(&x, "added_at") })?;
            count += 1;
        }
        for x in v.get("progress").and_then(|a| a.as_array()).cloned().unwrap_or_default() {
            let (Some(id), Some(title)) = (s(&x, "media_id"), s(&x, "title")) else { continue };
            let incoming = Progress {
                media_id: id.clone(),
                episode_id: s(&x, "episode_id"),
                kind: kind_of(&s(&x, "kind").unwrap_or_default()),
                title,
                poster: s(&x, "poster"),
                position_s: x.get("position_s").and_then(|y| y.as_f64()).unwrap_or(0.0),
                duration_s: x.get("duration_s").and_then(|y| y.as_f64()),
                updated_at: i(&x, "updated_at"),
            };
            // الأحدث يكسب
            let keep = self.progress(&id)?.map(|p| p.updated_at < incoming.updated_at).unwrap_or(true);
            if keep {
                self.save_progress(&incoming)?;
                count += 1;
            }
        }
        for x in v.get("history").and_then(|a| a.as_array()).cloned().unwrap_or_default() {
            let (Some(id), Some(title)) = (s(&x, "media_id"), s(&x, "title")) else { continue };
            self.add_history(&HistoryEntry {
                media_id: id,
                title,
                poster: s(&x, "poster"),
                kind: kind_of(&s(&x, "kind").unwrap_or_default()),
                source_id: s(&x, "source_id").unwrap_or_default(),
                engine: engine_of(&s(&x, "engine").unwrap_or_default()),
                watched_at: i(&x, "watched_at"),
            })?;
            count += 1;
        }
        let known: Vec<String> = self.addons()?.into_iter().map(|a| a.transport_url).collect();
        let addons = v
            .get("addons")
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|u| u.as_str().map(String::from)).filter(|u| !known.contains(u)).collect())
            .unwrap_or_default();
        Ok((count, addons))
    }
}

fn row_progress(r: &rusqlite::Row<'_>) -> rusqlite::Result<Progress> {
    Ok(Progress {
        media_id: r.get(0)?,
        episode_id: r.get(1)?,
        kind: kind_of(&r.get::<_, String>(2)?),
        title: r.get(3)?,
        poster: r.get(4)?,
        position_s: r.get(5)?,
        duration_s: r.get(6)?,
        updated_at: r.get(7)?,
    })
}

// الـ Manifest يتخزن JSON (نفس شكل البروتوكول تقريبًا)
pub fn manifest_to_json(m: &Manifest) -> serde_json::Value {
    serde_json::json!({
        "id": m.id, "name": m.name, "version": m.version, "description": m.description, "logo": m.logo,
        "resources": m.resources, "types": m.types, "idPrefixes": m.id_prefixes, "configurable": m.configurable,
        "catalogs": m.catalogs.iter().map(|c| serde_json::json!({
            "id": c.id, "type": c.kind, "name": c.name, "genres": c.genres, "requiresExtra": c.requires_extra,
            "supportsSearch": c.supports_search, "supportsGenre": c.supports_genre, "supportsSkip": c.supports_skip
        })).collect::<Vec<_>>()
    })
}

pub fn manifest_from_json(v: &serde_json::Value, url: &str) -> Option<Manifest> {
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).map(|x| x.to_string());
    let list = |x: Option<&serde_json::Value>| -> Vec<String> {
        x.and_then(|a| a.as_array()).map(|a| a.iter().filter_map(|i| i.as_str().map(String::from)).collect()).unwrap_or_default()
    };
    let b = |x: &serde_json::Value, k: &str| x.get(k).and_then(|y| y.as_bool()).unwrap_or(false);
    Some(Manifest {
        id: s("id")?,
        name: s("name").unwrap_or_default(),
        version: s("version").unwrap_or_default(),
        description: s("description"),
        logo: s("logo"),
        resources: list(v.get("resources")),
        types: list(v.get("types")),
        id_prefixes: list(v.get("idPrefixes")),
        configurable: b(v, "configurable"),
        catalogs: v
            .get("catalogs")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|c| {
                        Some(CatalogDef {
                            id: c.get("id")?.as_str()?.to_string(),
                            kind: c.get("type")?.as_str()?.to_string(),
                            name: c.get("name").and_then(|n| n.as_str()).unwrap_or_default().to_string(),
                            genres: list(c.get("genres")),
                            requires_extra: b(c, "requiresExtra"),
                            supports_search: b(c, "supportsSearch"),
                            supports_genre: b(c, "supportsGenre"),
                            supports_skip: b(c, "supportsSkip"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
        transport_url: url.to_string(),
        enabled: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(url: &str) -> Manifest {
        Manifest {
            id: format!("id-{url}"), name: "X".into(), version: "1".into(), description: None, logo: None,
            resources: vec!["catalog".into(), "stream".into()], types: vec!["movie".into()],
            catalogs: vec![CatalogDef { id: "top".into(), kind: "movie".into(), name: "Top".into(), genres: vec!["A".into()], requires_extra: false, supports_search: true, supports_genre: true, supports_skip: true }],
            id_prefixes: vec!["tt".into()], configurable: false, transport_url: url.into(), enabled: true,
        }
    }

    #[test]
    fn migrations_run_once() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.schema_version(), MIGRATIONS.len() as i64);
        s.migrate().unwrap();
        assert_eq!(s.schema_version(), MIGRATIONS.len() as i64);
    }

    #[test]
    fn progress_and_continue_watching() {
        let s = Store::open_in_memory().unwrap();
        let mut p = Progress { media_id: "tt1".into(), episode_id: None, kind: MediaKind::Movie, title: "A".into(), poster: None, position_s: 100.0, duration_s: Some(1000.0), updated_at: 10 };
        s.save_progress(&p).unwrap();
        s.save_progress(&Progress { media_id: "tt2".into(), position_s: 990.0, updated_at: 20, ..p.clone() }).unwrap();
        s.save_progress(&Progress { media_id: "tt3".into(), duration_s: None, updated_at: 30, ..p.clone() }).unwrap();
        let cw = s.continue_watching(10).unwrap();
        assert_eq!(cw.iter().map(|x| x.media_id.as_str()).collect::<Vec<_>>(), vec!["tt3", "tt1"]);
        p.position_s = 200.0;
        s.save_progress(&p).unwrap();
        assert_eq!(s.progress("tt1").unwrap().unwrap().position_s, 200.0);
        s.remove_progress("tt1").unwrap();
        assert!(s.progress("tt1").unwrap().is_none());
    }

    #[test]
    fn library_roundtrip() {
        let s = Store::open_in_memory().unwrap();
        let i = LibraryItem { media_id: "tt1".into(), kind: MediaKind::Series, title: "S".into(), poster: Some("p".into()), added_at: 1 };
        s.add_to_library(&i).unwrap();
        assert!(s.in_library("tt1").unwrap());
        assert_eq!(s.library().unwrap(), vec![i]);
        s.remove_from_library("tt1").unwrap();
        assert!(!s.in_library("tt1").unwrap());
    }

    #[test]
    fn addons_order_enable_remove() {
        let s = Store::open_in_memory().unwrap();
        s.save_addon(&manifest("a")).unwrap();
        s.save_addon(&manifest("b")).unwrap();
        s.save_addon(&manifest("a")).unwrap(); // تحديث بدون تكرار
        assert_eq!(s.addons().unwrap().len(), 2);
        s.reorder_addons(&["b".into(), "a".into()]).unwrap();
        let list = s.addons().unwrap();
        assert_eq!(list[0].transport_url, "b");
        assert_eq!(list[1].catalogs[0].genres, vec!["A"]);
        s.set_addon_enabled("a", false).unwrap();
        assert!(!s.addons().unwrap()[1].enabled);
        s.remove_addon("b").unwrap();
        assert_eq!(s.addons().unwrap().len(), 1);
    }

    #[test]
    fn settings_history_memory() {
        let s = Store::open_in_memory().unwrap();
        s.set_setting("lang", "ar").unwrap();
        assert_eq!(s.setting("lang").unwrap().as_deref(), Some("ar"));
        assert!(s.setting("nope").unwrap().is_none());
        for i in 0..3 {
            s.add_history(&HistoryEntry { media_id: format!("m{i}"), title: "t".into(), poster: None, kind: MediaKind::Movie, source_id: "s".into(), engine: Engine::Vlc, watched_at: i }).unwrap();
        }
        let h = s.history(2).unwrap();
        assert_eq!(h.len(), 2);
        assert_eq!(h[0].media_id, "m2");
        assert_eq!(h[0].engine, Engine::Vlc);
        s.mark_source_failed("u", true).unwrap();
        s.mark_source_failed("u", false).unwrap();
        let m = s.source_memory("u").unwrap().unwrap();
        assert!(m.needs_vlc);
        assert_eq!(m.fail_count, 2);
        s.mark_source_ok("u", Engine::Native).unwrap();
        let m = s.source_memory("u").unwrap().unwrap();
        assert!(m.needs_vlc && m.fail_count == 0 && m.last_ok.is_some());
        s.clear_history().unwrap();
        assert!(s.history(10).unwrap().is_empty());
    }

    #[test]
    fn export_import_roundtrip() {
        let a = Store::open_in_memory().unwrap();
        a.add_to_library(&LibraryItem { media_id: "tt1".into(), kind: MediaKind::Series, title: "S".into(), poster: None, added_at: 5 }).unwrap();
        a.save_progress(&Progress { media_id: "tt1".into(), episode_id: Some("tt1:1:1".into()), kind: MediaKind::Series, title: "S".into(), poster: None, position_s: 50.0, duration_s: Some(100.0), updated_at: 9 }).unwrap();
        a.save_addon(&manifest("https://x/manifest.json")).unwrap();
        let json = a.export_json().unwrap();
        let b = Store::open_in_memory().unwrap();
        let (n, addons) = b.import_json(&json).unwrap();
        assert_eq!(n, 2);
        assert_eq!(addons, vec!["https://x/manifest.json"]);
        assert!(b.in_library("tt1").unwrap());
        assert_eq!(b.progress("tt1").unwrap().unwrap().episode_id.as_deref(), Some("tt1:1:1"));
        assert!(b.import_json("{}").is_err());
        assert!(b.import_json("nope").is_err());
    }

    #[test]
    fn file_db_persists() {
        let dir = std::env::temp_dir().join(format!("qb-store-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.sqlite");
        {
            let s = Store::open(path.to_str().unwrap()).unwrap();
            s.set_setting("k", "v").unwrap();
        }
        let s = Store::open(path.to_str().unwrap()).unwrap();
        assert_eq!(s.setting("k").unwrap().as_deref(), Some("v"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
