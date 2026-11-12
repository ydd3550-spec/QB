use super::*;

fn manifest(url: &str, name: &str) -> Manifest {
    Manifest {
        id: format!("id.{name}"), name: name.into(), version: "1".into(), description: None, logo: None,
        resources: vec!["catalog".into(), "meta".into(), "stream".into()], types: vec!["movie".into(), "series".into()],
        catalogs: vec![
            CatalogDef { id: "top".into(), kind: "movie".into(), name: "Popular".into(), genres: vec![], requires_extra: false, supports_search: false, supports_genre: false, supports_skip: true },
            CatalogDef { id: "search".into(), kind: "movie".into(), name: "Search".into(), genres: vec![], requires_extra: true, supports_search: true, supports_genre: false, supports_skip: false },
        ],
        id_prefixes: vec!["tt".into()], configurable: false, transport_url: url.into(), enabled: true,
    }
}

#[tokio::test]
async fn discover_skips_search_only_catalogs() {
    let core = Core::in_memory().unwrap();
    core.store().save_addon(&manifest("http://127.0.0.1:9/a/manifest.json", "A")).unwrap();
    let d = core.discover_catalogs();
    assert_eq!(d.len(), 1);
    assert_eq!(d[0].catalog.id, "top");
    core.set_addon_enabled("http://127.0.0.1:9/a/manifest.json", false).unwrap();
    assert!(core.discover_catalogs().is_empty());
}

#[tokio::test]
async fn unreachable_addon_does_not_break_home_or_sources() {
    let core = Core::in_memory().unwrap();
    // منفذ 9 مقفول: الطلب يفشل فورًا
    core.store().save_addon(&manifest("http://127.0.0.1:9/a/manifest.json", "A")).unwrap();
    let rows = core.home_rows().await.unwrap();
    assert!(rows.is_empty());
    let s = core.load_sources(MediaKind::Movie, "tt1", true, |_| {}).await.unwrap();
    assert!(s.is_empty());
    // المعرّف ما يبدأ بـ tt: ولا إضافة تدعمه
    assert!(core.meta(MediaKind::Movie, "kitsu:1").await.is_err());
}

#[tokio::test]
async fn cancel_all_stops_work() {
    let core = Core::in_memory().unwrap();
    let c2 = core.clone();
    let h = tokio::spawn(async move {
        c2.cancellable(async {
            tokio::time::sleep(Duration::from_secs(10)).await;
            Ok::<_, CoreError>(1)
        })
        .await
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    core.cancel_all();
    let r = tokio::time::timeout(Duration::from_secs(2), h).await.unwrap().unwrap();
    assert!(matches!(r, Err(CoreError::Cancelled)));
}

#[test]
fn next_episode_works() {
    let v = |id: &str| Video { id: id.into(), title: id.into(), season: Some(1), episode: None, released: None, thumbnail: None, overview: None };
    let meta = MetaDetail {
        id: "tt1".into(), kind: MediaKind::Series, name: "S".into(), poster: None, background: None, logo: None, description: None,
        release_info: None, runtime: None, imdb_rating: None, genres: vec![], cast: vec![], directors: vec![], trailer_yt_ids: vec![],
        videos: vec![v("a"), v("b")], links: vec![], addon: "x".into(),
    };
    assert_eq!(Core::next_episode(&meta, "a").unwrap().id, "b");
    assert!(Core::next_episode(&meta, "b").is_none());
    assert!(Core::next_episode(&meta, "z").is_none());
}

#[test]
fn subtitles_sorted_by_preference() {
    let t = |l: &str, u: &str| SubtitleTrack { id: u.into(), url: u.into(), lang: l.into(), addon: "x".into() };
    let mut list = vec![t("fre", "1"), t("eng", "2"), t("ara", "3"), t("ara", "3")];
    sort_subtitles(&mut list, "ar");
    assert_eq!(list.iter().map(|s| s.url.as_str()).collect::<Vec<_>>(), vec!["3", "2", "1"]);
}

#[test]
fn row_titles_are_arabic() {
    let c = CatalogDef { id: "top".into(), kind: "movie".into(), name: "Popular".into(), genres: vec![], requires_extra: false, supports_search: false, supports_genre: false, supports_skip: false };
    assert_eq!(row_title(&c), "الأكثر شهرة · أفلام");
}

#[tokio::test]
async fn install_bad_url_fails_cleanly() {
    let core = Core::in_memory().unwrap();
    assert!(core.install_addon("   ").await.is_err());
    assert!(core.install_addon("http://127.0.0.1:9/x").await.is_err());
    assert!(core.addons().unwrap().is_empty());
}

/// اختبار تكامل على الشبكة الحقيقية (جولة الإضافات): cargo test -- --ignored
#[tokio::test]
#[ignore]
async fn live_addon_tour() {
    let core = Core::in_memory().unwrap();
    assert_eq!(core.seed_default_addons().await, 2);
    let rows = core.home_rows().await.unwrap();
    assert!(!rows.is_empty());
    let meta = core.meta(MediaKind::Movie, "tt0111161").await.unwrap();
    assert!(!meta.name.is_empty());
    let subs = core.subtitles(MediaKind::Movie, "tt0111161").await.unwrap();
    println!("rows={} meta={} subs={}", rows.len(), meta.name, subs.len());
    if let Some(s) = subs.first() {
        let cues = core.load_subtitle(&s.url).await.unwrap();
        assert!(!cues.is_empty());
    }
    let found = core.search_flat("batman").await.unwrap();
    assert!(!found.is_empty());
    let sim = core.similar(MediaKind::Movie, "tt0111161").await.unwrap();
    println!("search={} similar={}", found.len(), sim.len());
    assert!(!sim.iter().any(|m| m.id == "tt0111161"));
}

#[test]
fn flatten_unique_dedupes_and_excludes() {
    let m = |id: &str| MetaPreview { id: id.into(), kind: MediaKind::Movie, name: id.into(), poster: None, background: None, logo: None, description: None, release_info: None, imdb_rating: None, genres: vec![], addon: "x".into() };
    let out = flatten_unique(vec![m("a"), m("b"), m("a"), m("self"), m("c")], Some("self"), 2);
    assert_eq!(out.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["a", "b"]);
}

#[tokio::test]
async fn events_get_finished_even_without_addons() {
    use std::sync::atomic::{AtomicBool, Ordering};
    struct E(AtomicBool);
    impl SourceEvents for E {
        fn on_sources(&self, _: Vec<RankedSource>) {}
        fn on_health(&self, _: String, _: Health) {}
        fn on_finished(&self) { self.0.store(true, Ordering::SeqCst); }
    }
    let core = Core::in_memory().unwrap();
    let e = Arc::new(E(AtomicBool::new(false)));
    core.load_sources_with(MediaKind::Movie, "tt1", true, e.clone()).await.unwrap();
    assert!(e.0.load(Ordering::SeqCst));
}

#[tokio::test]
async fn async_write_goes_through_blocking_pool() {
    let core = Core::in_memory().unwrap();
    core.write(|s| s.set_setting("k", "v")).await.unwrap();
    assert_eq!(core.store().setting("k").unwrap().as_deref(), Some("v"));
}
