//! عميل بروتوكول Stremio: manifest, catalog, meta, stream, subtitles + url / ytId / externalUrl.
//! Deserialize متسامح: أي حقل ناقص يصير اختياري، وعنصر خربان ما يخرب الباقي.
use qb_model::*;
use serde_json::Value;
use std::collections::HashMap;

pub mod raw;
pub mod client;
pub use client::AddonClient;

/// ينظّف رابط إضافة: stremio:// ← https://، ويضيف manifest.json لا نقص
pub fn normalize_manifest_url(input: &str) -> Result<String, CoreError> {
    let mut s = input.trim().to_string();
    if s.is_empty() {
        return Err(CoreError::addon("empty url"));
    }
    if let Some(rest) = s.strip_prefix("stremio://") {
        s = format!("https://{rest}");
    }
    if !s.starts_with("http://") && !s.starts_with("https://") {
        s = format!("https://{s}");
    }
    // شل أي query أو fragment بعد manifest.json؟ لا: بعض الإضافات تحتاجها. نخليها زي ما هي.
    let (path_part, query) = match s.find('?') {
        Some(i) => (s[..i].to_string(), s[i..].to_string()),
        None => (s.clone(), String::new()),
    };
    let mut path_part = path_part.trim_end_matches('/').to_string();
    if path_part.ends_with("/configure") {
        path_part.truncate(path_part.len() - "/configure".len());
    }
    if !path_part.to_ascii_lowercase().ends_with("manifest.json") {
        path_part.push_str("/manifest.json");
    }
    Ok(format!("{path_part}{query}"))
}

/// الأساس اللي تنبني عليه روابط الموارد
pub fn base_url(transport_url: &str) -> String {
    let no_query = transport_url.split('?').next().unwrap_or(transport_url);
    let trimmed = no_query.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(i) if trimmed[i + 1..].eq_ignore_ascii_case("manifest.json") => trimmed[..i].to_string(),
        _ => trimmed.to_string(),
    }
}

/// مثل encodeURIComponent
pub fn encode_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric() || "-_.!~*'()".contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

pub fn resource_url(transport_url: &str, resource: &str, kind: &str, id: &str, extra: &[(String, String)]) -> String {
    let base = base_url(transport_url);
    let mut url = format!("{base}/{resource}/{}/{}", encode_component(kind), encode_component(id));
    if !extra.is_empty() {
        let e: Vec<String> = extra.iter().map(|(k, v)| format!("{}={}", encode_component(k), encode_component(v))).collect();
        url.push('/');
        url.push_str(&e.join("&"));
    }
    url.push_str(".json");
    url
}

// ---------- manifest ----------

pub fn parse_manifest(v: &Value, transport_url: &str) -> Result<Manifest, CoreError> {
    let id = raw::str_field(v, "id").ok_or_else(|| CoreError::addon("manifest has no id"))?;
    let name = raw::str_field(v, "name").unwrap_or_else(|| id.clone());
    let version = raw::str_field(v, "version").unwrap_or_else(|| "0.0.0".into());
    let types = raw::str_list(v.get("types"));
    let mut id_prefixes = raw::str_list(v.get("idPrefixes"));

    // resources: نص أو object {name, types, idPrefixes}
    let mut resources = Vec::new();
    if let Some(arr) = v.get("resources").and_then(|r| r.as_array()) {
        for r in arr {
            if let Some(s) = r.as_str() {
                resources.push(s.to_string());
            } else if let Some(n) = r.get("name").and_then(|n| n.as_str()) {
                resources.push(n.to_string());
                for p in raw::str_list(r.get("idPrefixes")) {
                    if !id_prefixes.contains(&p) {
                        id_prefixes.push(p);
                    }
                }
            }
        }
    }
    resources.dedup();

    let catalogs = v
        .get("catalogs")
        .and_then(|c| c.as_array())
        .map(|arr| arr.iter().filter_map(parse_catalog_def).collect())
        .unwrap_or_default();
    if !resources.iter().any(|r| r == "catalog") && !Vec::<CatalogDef>::is_empty(&catalogs) {
        resources.push("catalog".into());
    }

    let hints = v.get("behaviorHints");
    let configurable = hints.and_then(|h| h.get("configurable")).and_then(|b| b.as_bool()).unwrap_or(false);
    Ok(Manifest {
        id,
        name,
        version,
        description: raw::str_field(v, "description"),
        logo: raw::str_field(v, "logo").or_else(|| raw::str_field(v, "icon")),
        resources,
        types,
        catalogs,
        id_prefixes,
        configurable,
        transport_url: transport_url.to_string(),
        enabled: true,
    })
}

fn parse_catalog_def(c: &Value) -> Option<CatalogDef> {
    let id = raw::str_field(c, "id")?;
    let kind = raw::str_field(c, "type")?;
    let name = raw::str_field(c, "name").unwrap_or_else(|| id.clone());
    let mut genres = raw::str_list(c.get("genres"));
    let mut requires_extra = false;
    let mut supports_search = false;
    let mut supports_genre = !genres.is_empty();
    let mut supports_skip = false;
    // extra الجديدة
    if let Some(extra) = c.get("extra").and_then(|e| e.as_array()) {
        for e in extra {
            let n = raw::str_field(e, "name").unwrap_or_default();
            let req = e.get("isRequired").and_then(|b| b.as_bool()).unwrap_or(false);
            if req {
                requires_extra = true;
            }
            match n.as_str() {
                "search" => supports_search = true,
                "genre" => {
                    supports_genre = true;
                    for g in raw::str_list(e.get("options")) {
                        if !genres.contains(&g) {
                            genres.push(g);
                        }
                    }
                }
                "skip" => supports_skip = true,
                _ => {}
            }
        }
    }
    // الصيغة القديمة extraSupported / extraRequired
    for n in raw::str_list(c.get("extraSupported")) {
        match n.as_str() {
            "search" => supports_search = true,
            "genre" => supports_genre = true,
            "skip" => supports_skip = true,
            _ => {}
        }
    }
    if !raw::str_list(c.get("extraRequired")).is_empty() {
        requires_extra = true;
    }
    Some(CatalogDef { id, kind, name, genres, requires_extra, supports_search, supports_genre, supports_skip })
}

pub fn manifest_supports(m: &Manifest, resource: &str, kind: &str, id: &str) -> bool {
    if !m.resources.iter().any(|r| r == resource) {
        return false;
    }
    if !m.types.is_empty() && !m.types.iter().any(|t| t == kind) {
        // بعض الإضافات تحط "tv" أو ما تحط الأنواع صح
        if !(kind == "series" && m.types.iter().any(|t| t == "tv" || t == "anime")) {
            return false;
        }
    }
    if m.id_prefixes.is_empty() {
        return true;
    }
    m.id_prefixes.iter().any(|p| id.starts_with(p.as_str()))
}

// ---------- catalog / meta ----------

pub fn parse_metas(v: &Value, addon: &str, fallback_kind: MediaKind) -> Vec<MetaPreview> {
    v.get("metas")
        .and_then(|m| m.as_array())
        .map(|arr| arr.iter().filter_map(|m| parse_preview(m, addon, fallback_kind)).collect())
        .unwrap_or_default()
}

pub fn parse_preview(m: &Value, addon: &str, fallback_kind: MediaKind) -> Option<MetaPreview> {
    let id = raw::str_field(m, "id").or_else(|| raw::str_field(m, "imdb_id"))?;
    let name = raw::str_field(m, "name").or_else(|| raw::str_field(m, "title")).unwrap_or_default();
    if name.is_empty() {
        return None;
    }
    let kind = raw::str_field(m, "type").and_then(|t| MediaKind::parse(&t)).unwrap_or(fallback_kind);
    Some(MetaPreview {
        id,
        kind,
        name,
        poster: raw::str_field(m, "poster"),
        background: raw::str_field(m, "background"),
        logo: raw::str_field(m, "logo"),
        description: raw::str_field(m, "description"),
        release_info: raw::str_field(m, "releaseInfo").or_else(|| raw::str_field(m, "year")),
        imdb_rating: raw::str_field(m, "imdbRating"),
        genres: raw::str_list(m.get("genres")).into_iter().chain(raw::str_list(m.get("genre"))).collect(),
        addon: addon.to_string(),
    })
}

pub fn parse_meta_detail(v: &Value, addon: &str, fallback_kind: MediaKind) -> Option<MetaDetail> {
    let m = v.get("meta")?;
    let p = parse_preview(m, addon, fallback_kind)?;
    let mut videos: Vec<Video> = m
        .get("videos")
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|x| {
                    let id = raw::str_field(x, "id")?;
                    let season = raw::u32_field(x, "season");
                    let episode = raw::u32_field(x, "episode").or_else(|| raw::u32_field(x, "number"));
                    let title = raw::str_field(x, "title").or_else(|| raw::str_field(x, "name")).unwrap_or_else(|| match episode {
                        Some(e) => format!("الحلقة {e}"),
                        None => id.clone(),
                    });
                    Some(Video {
                        id,
                        title,
                        season,
                        episode,
                        released: raw::str_field(x, "released").or_else(|| raw::str_field(x, "firstAired")),
                        thumbnail: raw::str_field(x, "thumbnail"),
                        overview: raw::str_field(x, "overview").or_else(|| raw::str_field(x, "description")),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    videos.sort_by_key(|v| (v.season.unwrap_or(0), v.episode.unwrap_or(0)));

    let mut trailer_yt_ids: Vec<String> = Vec::new();
    if let Some(arr) = m.get("trailerStreams").and_then(|a| a.as_array()) {
        for t in arr {
            if let Some(y) = raw::str_field(t, "ytId") {
                trailer_yt_ids.push(y);
            }
        }
    }
    if let Some(arr) = m.get("trailers").and_then(|a| a.as_array()) {
        for t in arr {
            if let Some(y) = raw::str_field(t, "source")
                && !trailer_yt_ids.contains(&y) {
                    trailer_yt_ids.push(y);
                }
        }
    }

    let mut links = Vec::new();
    let mut cast = raw::str_list(m.get("cast"));
    let mut directors = raw::str_list(m.get("director"));
    let mut genres = p.genres.clone();
    if let Some(arr) = m.get("links").and_then(|a| a.as_array()) {
        for l in arr {
            let (Some(name), Some(category)) = (raw::str_field(l, "name"), raw::str_field(l, "category")) else { continue };
            let url = raw::str_field(l, "url").unwrap_or_default();
            match category.as_str() {
                "Cast" if !cast.contains(&name) => cast.push(name.clone()),
                "Directors" if !directors.contains(&name) => directors.push(name.clone()),
                "Genres" if !genres.contains(&name) => genres.push(name.clone()),
                _ => {}
            }
            links.push(Link { name, category, url });
        }
    }

    Some(MetaDetail {
        id: p.id,
        kind: p.kind,
        name: p.name,
        poster: p.poster,
        background: p.background,
        logo: p.logo,
        description: p.description,
        release_info: p.release_info,
        runtime: raw::str_field(m, "runtime"),
        imdb_rating: p.imdb_rating,
        genres,
        cast,
        directors,
        trailer_yt_ids,
        videos,
        links,
        addon: addon.to_string(),
    })
}

// ---------- stream ----------

/// مصدر خام من إضافة قبل الترتيب
#[derive(Debug, Clone, PartialEq)]
pub struct RawStream {
    pub addon: String,
    pub name: String,
    pub title: String,
    pub description: Option<String>,
    pub target: StreamTarget,
    pub not_web_ready: bool,
    pub filename: Option<String>,
    pub subtitles: Vec<SubtitleTrack>,
}

pub fn parse_streams(v: &Value, addon: &str) -> Vec<RawStream> {
    v.get("streams")
        .and_then(|s| s.as_array())
        .map(|arr| arr.iter().filter_map(|s| parse_stream(s, addon)).collect())
        .unwrap_or_default()
}

pub fn parse_stream(s: &Value, addon: &str) -> Option<RawStream> {
    let hints = s.get("behaviorHints");
    let target = if let Some(url) = raw::str_field(s, "url") {
        if url.starts_with("magnet:") {
            return None;
        }
        let mut headers: HashMap<String, String> = HashMap::new();
        if let Some(req) = hints.and_then(|h| h.get("proxyHeaders")).and_then(|p| p.get("request")).and_then(|r| r.as_object()) {
            for (k, v) in req {
                if let Some(v) = v.as_str() {
                    headers.insert(k.clone(), v.to_string());
                }
            }
        }
        StreamTarget::Direct { url, headers }
    } else if let Some(yt) = raw::str_field(s, "ytId") {
        StreamTarget::YouTube { yt_id: yt }
    } else {
        let ext = raw::str_field(s, "externalUrl")?;
        StreamTarget::External { url: ext }
    };
    let name = raw::str_field(s, "name").unwrap_or_default();
    let title = raw::str_field(s, "title").or_else(|| raw::str_field(s, "description")).unwrap_or_default();
    let subtitles = s
        .get("subtitles")
        .and_then(|a| a.as_array())
        .map(|arr| arr.iter().filter_map(|x| parse_subtitle_track(x, addon)).collect())
        .unwrap_or_default();
    Some(RawStream {
        addon: addon.to_string(),
        name,
        title,
        description: raw::str_field(s, "description"),
        target,
        not_web_ready: hints.and_then(|h| h.get("notWebReady")).and_then(|b| b.as_bool()).unwrap_or(false),
        filename: hints.and_then(|h| raw::str_field(h, "filename")),
        subtitles,
    })
}

// ---------- subtitles ----------

pub fn parse_subtitles(v: &Value, addon: &str) -> Vec<SubtitleTrack> {
    v.get("subtitles")
        .and_then(|s| s.as_array())
        .map(|arr| arr.iter().filter_map(|x| parse_subtitle_track(x, addon)).collect())
        .unwrap_or_default()
}

fn parse_subtitle_track(x: &Value, addon: &str) -> Option<SubtitleTrack> {
    let url = raw::str_field(x, "url")?;
    let lang = raw::str_field(x, "lang").unwrap_or_else(|| "und".into());
    let id = raw::str_field(x, "id").unwrap_or_else(|| url.clone());
    Some(SubtitleTrack { id, url, lang, addon: addon.to_string() })
}

#[cfg(test)]
mod tests;
