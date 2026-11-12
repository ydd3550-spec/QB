//! الأنواع المشتركة بين Rust وSwift.
uniffi::setup_scaffolding!();

use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum MediaKind {
    Movie,
    Series,
}

impl MediaKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            MediaKind::Movie => "movie",
            MediaKind::Series => "series",
        }
    }
    pub fn parse(s: &str) -> Option<MediaKind> {
        match s {
            "movie" => Some(MediaKind::Movie),
            "series" | "tv" | "anime" => Some(MediaKind::Series),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CatalogDef {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub genres: Vec<String>,
    /// كتالوج يحتاج search أو genre إجباري ما يطلع رف في الرئيسية
    pub requires_extra: bool,
    pub supports_search: bool,
    pub supports_genre: bool,
    pub supports_skip: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    pub logo: Option<String>,
    pub resources: Vec<String>, // catalog / meta / stream / subtitles
    pub types: Vec<String>,
    pub catalogs: Vec<CatalogDef>,
    pub id_prefixes: Vec<String>,
    pub configurable: bool,
    /// رابط الـ manifest اللي تثبّتت منه الإضافة
    pub transport_url: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MetaPreview {
    pub id: String,
    pub kind: MediaKind,
    pub name: String,
    pub poster: Option<String>,
    pub background: Option<String>,
    pub logo: Option<String>,
    pub description: Option<String>,
    pub release_info: Option<String>,
    pub imdb_rating: Option<String>,
    pub genres: Vec<String>,
    pub addon: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CatalogRow {
    pub addon_id: String,
    pub addon_name: String,
    pub catalog_id: String,
    pub kind: MediaKind,
    pub title: String,
    pub items: Vec<MetaPreview>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Video {
    pub id: String,
    pub title: String,
    pub season: Option<u32>,
    pub episode: Option<u32>,
    pub released: Option<String>,
    pub thumbnail: Option<String>,
    pub overview: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Link {
    pub name: String,
    pub category: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MetaDetail {
    pub id: String,
    pub kind: MediaKind,
    pub name: String,
    pub poster: Option<String>,
    pub background: Option<String>,
    pub logo: Option<String>,
    pub description: Option<String>,
    pub release_info: Option<String>,
    pub runtime: Option<String>,
    pub imdb_rating: Option<String>,
    pub genres: Vec<String>,
    pub cast: Vec<String>,
    pub directors: Vec<String>,
    pub trailer_yt_ids: Vec<String>,
    pub videos: Vec<Video>,
    pub links: Vec<Link>,
    pub addon: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum StreamTarget {
    Direct { url: String, headers: HashMap<String, String> },
    YouTube { yt_id: String },
    External { url: String },
    // torrent / magnet / debrid: مستبعدة عمدًا
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Engine {
    Native,
    Vlc,
    YouTube,
    External,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Health {
    Checking,
    Alive { mime: Option<String>, latency_ms: u32 },
    Unreachable,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RankedSource {
    pub id: String,
    pub addon: String,
    pub title: String,
    pub description: Option<String>,
    pub quality: u16, // 2160 / 1080 / 720 …
    pub engine: Engine,
    pub target: StreamTarget,
    pub score: i32,
    pub health: Health,
    /// ترجمات جاية مع المصدر نفسه
    pub subtitles: Vec<SubtitleTrack>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Cue {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SubtitleTrack {
    pub id: String,
    pub url: String,
    pub lang: String,
    pub addon: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Progress {
    pub media_id: String,
    /// للمسلسلات: معرّف الحلقة (tt123:1:2)، للأفلام فاضي
    pub episode_id: Option<String>,
    pub kind: MediaKind,
    pub title: String,
    pub poster: Option<String>,
    pub position_s: f64,
    pub duration_s: Option<f64>, // ممكن تكون مجهولة
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LibraryItem {
    pub media_id: String,
    pub kind: MediaKind,
    pub title: String,
    pub poster: Option<String>,
    pub added_at: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryEntry {
    pub media_id: String,
    pub title: String,
    pub poster: Option<String>,
    pub kind: MediaKind,
    pub source_id: String,
    pub engine: Engine,
    pub watched_at: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SourceMemory {
    pub needs_vlc: bool,
    pub fail_count: u32,
    pub last_ok: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AddonReport {
    pub addon: String,
    pub total: u32,
    pub alive: u32,
    pub native: u32,
    pub vlc: u32,
    pub other: u32,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("network: {0}")]
    Network(String),
    #[error("addon: {0}")]
    Addon(String),
    #[error("storage: {0}")]
    Storage(String),
    #[error("cancelled")]
    Cancelled,
}

impl CoreError {
    pub fn network(m: impl std::fmt::Display) -> Self {
        CoreError::Network(m.to_string())
    }
    pub fn addon(m: impl std::fmt::Display) -> Self {
        CoreError::Addon(m.to_string())
    }
    pub fn storage(m: impl std::fmt::Display) -> Self {
        CoreError::Storage(m.to_string())
    }
}

/// دالة المرحلة 0: تتأكد إن Rust يوصل Swift
#[uniffi::export]
pub fn hello() -> String {
    "QB core ready".to_string()
}
