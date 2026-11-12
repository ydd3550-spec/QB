use super::*;
use proptest::prelude::*;
use serde_json::json;

#[test]
fn normalizes_urls() {
    assert_eq!(normalize_manifest_url("stremio://a.com/x/manifest.json").unwrap(), "https://a.com/x/manifest.json");
    assert_eq!(normalize_manifest_url("https://a.com/x/").unwrap(), "https://a.com/x/manifest.json");
    assert_eq!(normalize_manifest_url("a.com").unwrap(), "https://a.com/manifest.json");
    assert_eq!(normalize_manifest_url("https://a.com/cfg/configure").unwrap(), "https://a.com/cfg/manifest.json");
    assert_eq!(normalize_manifest_url("http://a.com/manifest.json?k=1").unwrap(), "http://a.com/manifest.json?k=1");
    assert!(normalize_manifest_url("  ").is_err());
}

#[test]
fn builds_resource_urls() {
    let t = "https://v3-cinemeta.strem.io/manifest.json";
    assert_eq!(base_url(t), "https://v3-cinemeta.strem.io");
    assert_eq!(resource_url(t, "meta", "movie", "tt123", &[]), "https://v3-cinemeta.strem.io/meta/movie/tt123.json");
    assert_eq!(
        resource_url(t, "catalog", "movie", "top", &[("genre".into(), "دراما".into()), ("skip".into(), "20".into())]),
        "https://v3-cinemeta.strem.io/catalog/movie/top/genre=%D8%AF%D8%B1%D8%A7%D9%85%D8%A7&skip=20.json"
    );
    assert_eq!(resource_url(t, "stream", "series", "tt1:1:2", &[]), "https://v3-cinemeta.strem.io/stream/series/tt1%3A1%3A2.json");
}

#[test]
fn parses_manifest_with_object_resources() {
    let v = json!({
        "id": "x.addon", "name": "X", "version": "1.0.0",
        "resources": ["catalog", {"name": "stream", "types": ["movie"], "idPrefixes": ["tt"]}],
        "types": ["movie", "series"],
        "catalogs": [
            {"type": "movie", "id": "top", "name": "Top", "extra": [{"name": "genre", "options": ["Drama"]}, {"name": "skip"}]},
            {"type": "movie", "id": "search", "extra": [{"name": "search", "isRequired": true}]},
            {"id": "broken"}
        ],
        "behaviorHints": {"configurable": true}
    });
    let m = parse_manifest(&v, "https://x/manifest.json").unwrap();
    assert_eq!(m.resources, vec!["catalog", "stream"]);
    assert_eq!(m.id_prefixes, vec!["tt"]);
    assert_eq!(m.catalogs.len(), 2);
    assert!(m.catalogs[0].supports_genre && m.catalogs[0].supports_skip && !m.catalogs[0].requires_extra);
    assert_eq!(m.catalogs[0].genres, vec!["Drama"]);
    assert!(m.catalogs[1].requires_extra && m.catalogs[1].supports_search);
    assert!(m.configurable);
    assert!(manifest_supports(&m, "stream", "movie", "tt1"));
    assert!(!manifest_supports(&m, "stream", "movie", "kitsu:1"));
    assert!(!manifest_supports(&m, "meta", "movie", "tt1"));
}

#[test]
fn manifest_without_id_fails() {
    assert!(parse_manifest(&json!({"name": "x"}), "u").is_err());
}

#[test]
fn parses_streams_tolerantly() {
    let v = json!({"streams": [
        {"url": "https://cdn/x.mkv", "name": "A", "title": "1080p", "behaviorHints": {"proxyHeaders": {"request": {"Referer": "https://r"}}, "notWebReady": true}},
        {"ytId": "abc"},
        {"externalUrl": "https://netflix.com/title/1"},
        {"infoHash": "deadbeef"},
        {"url": "magnet:?xt=1"},
        "garbage",
        {"url": "https://cdn/y.mp4", "subtitles": [{"url": "https://s/a.srt", "lang": "ara"}]}
    ]});
    let s = parse_streams(&v, "A");
    assert_eq!(s.len(), 4);
    match &s[0].target {
        StreamTarget::Direct { headers, .. } => assert_eq!(headers.get("Referer").unwrap(), "https://r"),
        _ => panic!("expected direct"),
    }
    assert!(s[0].not_web_ready);
    assert!(matches!(s[1].target, StreamTarget::YouTube { .. }));
    assert!(matches!(s[2].target, StreamTarget::External { .. }));
    assert_eq!(s[3].subtitles[0].lang, "ara");
}

#[test]
fn parses_meta_detail_with_videos_and_links() {
    let v = json!({"meta": {
        "id": "tt1", "type": "series", "name": "Show",
        "videos": [
            {"id": "tt1:1:2", "season": 1, "episode": 2, "title": "Two"},
            {"id": "tt1:1:1", "season": "1", "number": 1},
            {"title": "no id"}
        ],
        "links": [{"name": "Drama", "category": "Genres", "url": "stremio:///x"}, {"name": "Ali", "category": "Cast", "url": ""}],
        "trailerStreams": [{"ytId": "yt1"}]
    }});
    let d = parse_meta_detail(&v, "Cinemeta", MediaKind::Movie).unwrap();
    assert_eq!(d.kind, MediaKind::Series);
    assert_eq!(d.videos.len(), 2);
    assert_eq!(d.videos[0].id, "tt1:1:1");
    assert_eq!(d.videos[0].title, "الحلقة 1");
    assert_eq!(d.genres, vec!["Drama"]);
    assert_eq!(d.cast, vec!["Ali"]);
    assert_eq!(d.trailer_yt_ids, vec!["yt1"]);
}

#[test]
fn metas_skip_items_without_name() {
    let v = json!({"metas": [{"id": "a", "name": "A", "type": "movie"}, {"id": "b"}, {"name": "no id"}, 5]});
    let m = parse_metas(&v, "x", MediaKind::Movie);
    assert_eq!(m.len(), 1);
}

proptest! {
    #[test]
    fn encode_component_is_url_safe(s in "\\PC*") {
        let e = encode_component(&s);
        prop_assert!(e.chars().all(|c| c.is_ascii_alphanumeric() || "-_.!~*'()%".contains(c)));
    }

    #[test]
    fn parse_never_panics_on_random_json(s in "\\PC*") {
        let v = serde_json::Value::String(s);
        let _ = parse_streams(&v, "x");
        let _ = parse_metas(&v, "x", MediaKind::Movie);
        let _ = parse_manifest(&v, "u");
    }

    #[test]
    fn normalized_url_ends_with_manifest(host in "[a-z]{1,10}\\.[a-z]{2,4}", path in "(/[a-z0-9]{1,6}){0,3}") {
        let u = normalize_manifest_url(&format!("{host}{path}")).unwrap();
        prop_assert!(u.ends_with("/manifest.json"));
        prop_assert!(u.starts_with("https://"));
    }
}
