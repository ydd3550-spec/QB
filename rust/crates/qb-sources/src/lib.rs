//! ترتيب المصادر + فحص الصحة + تحديد المشغّل.
use qb_model::*;
use qb_net::Client;
use qb_protocol::RawStream;
use std::collections::HashMap;
use std::time::Duration;

/// الجودة من اسم المصدر: 2160 / 1080 / 720 / 480، أو 0 لا ما عرفنا
pub fn parse_quality(text: &str) -> u16 {
    let t = text.to_ascii_lowercase();
    if t.contains("2160") || t.contains("4k") || t.contains("uhd") {
        2160
    } else if t.contains("1440") {
        1440
    } else if t.contains("1080") || t.contains("fhd") {
        1080
    } else if t.contains("720") || t.contains("hd") && !t.contains("hdr") && !t.contains("hdcam") {
        720
    } else if t.contains("576") {
        576
    } else if t.contains("480") || t.contains("sd") {
        480
    } else if t.contains("360") {
        360
    } else {
        0
    }
}

const NATIVE_EXT: &[&str] = &["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac"];
const VLC_EXT: &[&str] = &["mkv", "avi", "webm", "flv", "wmv", "ts", "m2ts", "mpg", "mpeg", "ogv", "3gp", "divx", "vob", "rmvb", "mpd"];

fn extension(url: &str) -> Option<String> {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    let last = path.rsplit('/').next().unwrap_or(path);
    let dot = last.rfind('.')?;
    let ext = last[dot + 1..].to_ascii_lowercase();
    if ext.is_empty() || ext.len() > 5 { None } else { Some(ext) }
}

/// المشغّل من الامتداد أو نوع الملف أو أول البايتات
pub fn detect_engine(target: &StreamTarget, hint_name: Option<&str>, mime: Option<&str>, first_bytes: &[u8], not_web_ready: bool) -> Engine {
    let url = match target {
        StreamTarget::YouTube { .. } => return Engine::YouTube,
        StreamTarget::External { .. } => return Engine::External,
        StreamTarget::Direct { url, .. } => url,
    };
    // 1) البايتات أوثق شي
    if let Some(e) = sniff(first_bytes) {
        return e;
    }
    // 2) نوع الملف
    if let Some(m) = mime {
        let m = m.to_ascii_lowercase();
        if m.contains("mpegurl") || m == "video/mp4" || m == "video/quicktime" || m.starts_with("audio/mp4") || m == "audio/mpeg" {
            return Engine::Native;
        }
        if m.contains("matroska") || m.contains("webm") || m.contains("x-msvideo") || m.contains("x-flv") || m.contains("mp2t") || m.contains("dash") {
            return Engine::Vlc;
        }
    }
    // 3) الامتداد من الرابط أو اسم الملف
    for candidate in [extension(url), hint_name.and_then(extension)].into_iter().flatten() {
        if NATIVE_EXT.contains(&candidate.as_str()) {
            return if not_web_ready && candidate != "m3u8" { Engine::Vlc } else { Engine::Native };
        }
        if VLC_EXT.contains(&candidate.as_str()) {
            return Engine::Vlc;
        }
    }
    // 4) ما عرفنا: VLC يشغّل كل شي، إلا لو الإضافة قالت إنه جاهز للويب
    if not_web_ready { Engine::Vlc } else { Engine::Native }
}

/// يعرف الحاوية من أول البايتات
pub fn sniff(b: &[u8]) -> Option<Engine> {
    if b.len() >= 4 && b[0..4] == [0x1A, 0x45, 0xDF, 0xA3] {
        return Some(Engine::Vlc); // Matroska / WebM
    }
    if b.len() >= 12 && &b[4..8] == b"ftyp" {
        return Some(Engine::Native); // MP4 / MOV
    }
    if b.len() >= 7 && &b[0..7] == b"#EXTM3U" {
        return Some(Engine::Native); // HLS
    }
    if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"AVI " {
        return Some(Engine::Vlc);
    }
    if b.len() >= 3 && &b[0..3] == b"FLV" {
        return Some(Engine::Vlc);
    }
    if b.len() >= 189 && b[0] == 0x47 && b[188] == 0x47 {
        return Some(Engine::Vlc); // MPEG-TS
    }
    None
}

/// النقاط: الجودة، المشغّل الأصلي، الصحة، السرعة، الذاكرة
pub fn score(quality: u16, engine: Engine, health: &Health, memory: Option<&SourceMemory>, addon_rank: usize) -> i32 {
    let mut s: i32 = match quality {
        2160 => 380,
        1440 => 360,
        1080 => 400, // 1080 أفضل توازن للجوال
        720 => 300,
        576 | 480 => 200,
        360 => 120,
        _ => 150,
    };
    s += match engine {
        Engine::Native => 120,
        Engine::Vlc => 60,
        Engine::YouTube => 20,
        Engine::External => -200,
    };
    s += match health {
        Health::Alive { latency_ms, .. } => 200 - (*latency_ms as i32 / 20).min(150),
        Health::Checking => 0,
        Health::Unreachable => -1000,
    };
    if let Some(m) = memory {
        s -= (m.fail_count as i32).min(5) * 80;
        if m.last_ok.is_some() {
            s += 60;
        }
    }
    s - (addon_rank as i32).min(20) * 5
}

pub fn source_id(target: &StreamTarget) -> String {
    match target {
        StreamTarget::Direct { url, .. } => url.clone(),
        StreamTarget::YouTube { yt_id } => format!("yt:{yt_id}"),
        StreamTarget::External { url } => format!("ext:{url}"),
    }
}

/// يحوّل مصدر خام إلى RankedSource قبل فحص الصحة
pub fn rank_raw(raw: &RawStream, memory: Option<&SourceMemory>, addon_rank: usize) -> RankedSource {
    let text = format!("{} {} {}", raw.name, raw.title, raw.filename.clone().unwrap_or_default());
    let quality = parse_quality(&text);
    let mut engine = detect_engine(&raw.target, raw.filename.as_deref(), None, &[], raw.not_web_ready);
    if memory.map(|m| m.needs_vlc).unwrap_or(false) && engine == Engine::Native {
        engine = Engine::Vlc;
    }
    let health = match raw.target {
        StreamTarget::Direct { .. } => Health::Checking,
        _ => Health::Alive { mime: None, latency_ms: 0 },
    };
    let title = if raw.title.is_empty() { raw.name.clone() } else { raw.title.clone() };
    RankedSource {
        id: source_id(&raw.target),
        addon: raw.addon.clone(),
        title: if raw.name.is_empty() || title == raw.name { title } else { format!("{} · {}", raw.name, title) },
        description: raw.description.clone(),
        quality,
        engine,
        target: raw.target.clone(),
        score: score(quality, engine, &health, memory, addon_rank),
        health,
        subtitles: raw.subtitles.clone(),
    }
}

/// نوع ملف واضح؟ (application/octet-stream وأمثاله ما تكفي نحدد منها المشغّل)
fn mime_is_clear(m: Option<&str>) -> bool {
    match m {
        None => false,
        Some(m) => {
            let m = m.to_ascii_lowercase();
            !(m.is_empty() || m == "application/octet-stream" || m == "binary/octet-stream" || m.starts_with("text/") || m == "application/force-download")
        }
    }
}

/// فحص الصحة حسب الخطة:
/// HEAD بمهلة 4 ثواني؛ لو فشل أو نوع الملف مو واضح → GET مع Range: bytes=0-4095 ونقرا البايتات.
/// محاولتين بتأخير متزايد. (التوازي 4 بالمرة يتحكم فيه qb-core بـ Semaphore، والكاش 10 دقايق في qb-cache.)
pub async fn probe(net: &Client, src: &RankedSource, memory: Option<&SourceMemory>, addon_rank: usize) -> RankedSource {
    let mut out = src.clone();
    let StreamTarget::Direct { url, headers } = &src.target else { return out };
    let timeout = Duration::from_secs(4);
    let mut result: Option<(Option<String>, u32, Vec<u8>)> = None;
    for attempt in 0..2u32 {
        if attempt > 0 {
            tokio::time::sleep(qb_net::backoff(attempt)).await;
        }
        let mut head_ok: Option<(Option<String>, u32)> = None;
        if let Ok(r) = net.head(url, headers, timeout).await {
            if r.status < 400 {
                head_ok = Some((r.content_type, r.latency_ms));
            }
        }
        let need_bytes = match &head_ok {
            Some((ct, _)) => !mime_is_clear(ct.as_deref()),
            None => true,
        };
        if need_bytes {
            if let Ok(r) = net.range_get(url, headers, 4096, timeout).await {
                if r.status < 400 {
                    let ct = r.content_type.or_else(|| head_ok.as_ref().and_then(|h| h.0.clone()));
                    result = Some((ct, head_ok.as_ref().map(|h| h.1).unwrap_or(r.latency_ms), r.first_bytes));
                }
            }
            if result.is_none() {
                if let Some((ct, lat)) = head_ok {
                    result = Some((ct, lat, vec![]));
                }
            }
        } else if let Some((ct, lat)) = head_ok {
            result = Some((ct, lat, vec![]));
        }
        if result.is_some() {
            break;
        }
    }
    match result {
        Some((mime, latency, bytes)) => {
            let mut engine = detect_engine(&src.target, None, mime.as_deref(), &bytes, src.engine == Engine::Vlc && bytes.is_empty() && !mime_is_clear(mime.as_deref()));
            if engine == Engine::Native && memory.map(|m| m.needs_vlc).unwrap_or(false) {
                engine = Engine::Vlc;
            }
            out.engine = engine;
            out.health = Health::Alive { mime, latency_ms: latency };
        }
        None => out.health = Health::Unreachable,
    }
    out.score = score(out.quality, out.engine, &out.health, memory, addon_rank);
    out
}

/// تفضيلات المستخدم من الإعدادات
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Prefs {
    /// 0 = تلقائي
    pub quality: u16,
    /// اجبار VLC لكل الروابط المباشرة
    pub force_vlc: bool,
}

/// يطبّق التفضيلات على مصدر: الجودة المفضلة تطلع فوق، والأعلى منها ينزل شوي
pub fn apply_prefs(s: &mut RankedSource, p: Prefs) {
    if p.force_vlc && s.engine == Engine::Native && matches!(s.target, StreamTarget::Direct { .. }) {
        s.engine = Engine::Vlc;
    }
    if p.quality > 0 && s.quality > 0 {
        if s.quality == p.quality {
            s.score += 150;
        } else if s.quality > p.quality {
            s.score -= 60;
        }
    }
}

/// مجموعة المشغّل في الترتيب: Native ثم VLC ثم YouTube ثم الخارجي
pub fn engine_group(e: Engine) -> u8 {
    match e {
        Engine::Native => 0,
        Engine::Vlc => 1,
        Engine::YouTube => 2,
        Engine::External => 3,
    }
}

/// الحي قبل المجهول، والمجهول قبل اللي ما يرد. محد ينحذف من القائمة.
pub fn health_rank(h: &Health) -> u8 {
    match h {
        Health::Alive { .. } => 0,
        Health::Checking => 1,
        Health::Unreachable => 2,
    }
}

/// الترتيب النهائي حسب الخطة:
/// Native (حسب الجودة) ← VLC ← YouTube ← خارجي، وداخل كل مجموعة الحي قبل المجهول.
/// النقاط (الجودة، السرعة، ذاكرة الفشل) تفرز داخل المجموعة. ونشيل المكرر بس.
pub fn sort_and_dedupe(list: &mut Vec<RankedSource>) {
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut out: Vec<RankedSource> = Vec::with_capacity(list.len());
    for s in list.drain(..) {
        match seen.get(&s.id) {
            Some(&i) if out[i].score >= s.score => {}
            Some(&i) => out[i] = s,
            None => {
                seen.insert(s.id.clone(), out.len());
                out.push(s);
            }
        }
    }
    out.sort_by(|a, b| {
        engine_group(a.engine)
            .cmp(&engine_group(b.engine))
            .then_with(|| health_rank(&a.health).cmp(&health_rank(&b.health)))
            .then_with(|| b.score.cmp(&a.score))
            .then_with(|| b.quality.cmp(&a.quality))
    });
    *list = out;
}

/// تقرير لكل إضافة (للـ add-on tour)
pub fn report(sources: &[RankedSource]) -> Vec<AddonReport> {
    let mut by: Vec<AddonReport> = Vec::new();
    for s in sources {
        let idx = match by.iter().position(|r| r.addon == s.addon) {
            Some(i) => i,
            None => {
                by.push(AddonReport { addon: s.addon.clone(), total: 0, alive: 0, native: 0, vlc: 0, other: 0 });
                by.len() - 1
            }
        };
        let r = &mut by[idx];
        r.total += 1;
        if matches!(s.health, Health::Alive { .. }) {
            r.alive += 1;
        }
        match s.engine {
            Engine::Native => r.native += 1,
            Engine::Vlc => r.vlc += 1,
            _ => r.other += 1,
        }
    }
    by
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn direct(u: &str) -> StreamTarget {
        StreamTarget::Direct { url: u.into(), headers: HashMap::new() }
    }

    #[test]
    fn quality_parsing() {
        assert_eq!(parse_quality("Movie 2160p HDR"), 2160);
        assert_eq!(parse_quality("4K WEB"), 2160);
        assert_eq!(parse_quality("1080p BluRay"), 1080);
        assert_eq!(parse_quality("720p"), 720);
        assert_eq!(parse_quality("HDR only"), 0);
        assert_eq!(parse_quality("480p"), 480);
        assert_eq!(parse_quality("بدون"), 0);
    }

    #[test]
    fn engine_by_extension() {
        assert_eq!(detect_engine(&direct("https://a/x.mp4?t=1"), None, None, &[], false), Engine::Native);
        assert_eq!(detect_engine(&direct("https://a/x.m3u8"), None, None, &[], true), Engine::Native);
        assert_eq!(detect_engine(&direct("https://a/x.mkv"), None, None, &[], false), Engine::Vlc);
        assert_eq!(detect_engine(&direct("https://a/x.avi"), None, None, &[], false), Engine::Vlc);
        assert_eq!(detect_engine(&direct("https://a/play"), Some("Movie.webm"), None, &[], false), Engine::Vlc);
        assert_eq!(detect_engine(&direct("https://a/play"), None, None, &[], true), Engine::Vlc);
        assert_eq!(detect_engine(&StreamTarget::YouTube { yt_id: "x".into() }, None, None, &[], false), Engine::YouTube);
    }

    #[test]
    fn engine_by_bytes_beats_extension() {
        let mkv = [0x1A, 0x45, 0xDF, 0xA3, 0, 0];
        assert_eq!(detect_engine(&direct("https://a/x.mp4"), None, None, &mkv, false), Engine::Vlc);
        let mut mp4 = vec![0, 0, 0, 0x20];
        mp4.extend_from_slice(b"ftypisom");
        assert_eq!(detect_engine(&direct("https://a/x.mkv"), None, None, &mp4, false), Engine::Native);
        assert_eq!(detect_engine(&direct("https://a/x"), None, None, b"#EXTM3U\n", false), Engine::Native);
    }

    #[test]
    fn engine_by_mime() {
        assert_eq!(detect_engine(&direct("https://a/x"), None, Some("video/x-matroska"), &[], false), Engine::Vlc);
        assert_eq!(detect_engine(&direct("https://a/x"), None, Some("application/vnd.apple.mpegurl"), &[], false), Engine::Native);
    }

    #[test]
    fn unreachable_sinks_to_bottom() {
        let alive = Health::Alive { mime: None, latency_ms: 300 };
        assert!(score(480, Engine::Vlc, &alive, None, 3) > score(2160, Engine::Native, &Health::Unreachable, None, 0));
        assert!(score(1080, Engine::Native, &alive, None, 0) > score(1080, Engine::Vlc, &alive, None, 0));
        let bad = SourceMemory { needs_vlc: false, fail_count: 3, last_ok: None };
        assert!(score(1080, Engine::Native, &alive, Some(&bad), 0) < score(1080, Engine::Native, &alive, None, 0));
    }

    #[test]
    fn dedupe_keeps_best() {
        let raw = RawStream {
            addon: "A".into(), name: "A".into(), title: "1080p".into(), description: None,
            target: direct("https://a/x.mp4"), not_web_ready: false, filename: None, subtitles: vec![],
        };
        let a = rank_raw(&raw, None, 0);
        let mut b = a.clone();
        b.score += 50;
        let mut c = rank_raw(&RawStream { target: direct("https://a/y.mkv"), ..raw.clone() }, None, 1);
        c.score = -5;
        let mut list = vec![a, c, b.clone()];
        sort_and_dedupe(&mut list);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0], b);
    }

    #[test]
    fn memory_forces_vlc() {
        let raw = RawStream {
            addon: "A".into(), name: "".into(), title: "x".into(), description: None,
            target: direct("https://a/x.mp4"), not_web_ready: false, filename: None, subtitles: vec![],
        };
        let m = SourceMemory { needs_vlc: true, fail_count: 0, last_ok: None };
        assert_eq!(rank_raw(&raw, Some(&m), 0).engine, Engine::Vlc);
    }

    #[test]
    fn native_group_first_and_unreachable_kept() {
        let raw = RawStream {
            addon: "A".into(), name: "".into(), title: "x".into(), description: None,
            target: direct("https://a/x.mp4"), not_web_ready: false, filename: None, subtitles: vec![],
        };
        let base = rank_raw(&raw, None, 0);
        let mut list = vec![
            RankedSource { id: "vlc".into(), engine: Engine::Vlc, health: Health::Alive { mime: None, latency_ms: 1 }, score: 999, ..base.clone() },
            RankedSource { id: "dead".into(), engine: Engine::Native, health: Health::Unreachable, score: -900, ..base.clone() },
            RankedSource { id: "nat".into(), engine: Engine::Native, health: Health::Alive { mime: None, latency_ms: 1 }, score: 10, ..base.clone() },
            RankedSource { id: "yt".into(), engine: Engine::YouTube, health: Health::Checking, score: 0, ..base.clone() },
        ];
        sort_and_dedupe(&mut list);
        assert_eq!(list.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec!["nat", "dead", "vlc", "yt"]);
    }

    #[test]
    fn prefs_apply() {
        let raw = RawStream {
            addon: "A".into(), name: "".into(), title: "1080p".into(), description: None,
            target: direct("https://a/x.mp4"), not_web_ready: false, filename: None, subtitles: vec![],
        };
        let base = rank_raw(&raw, None, 0);
        let mut a = base.clone();
        apply_prefs(&mut a, Prefs { quality: 1080, force_vlc: false });
        assert_eq!(a.score, base.score + 150);
        let mut b = base.clone();
        apply_prefs(&mut b, Prefs { quality: 720, force_vlc: true });
        assert_eq!(b.score, base.score - 60);
        assert_eq!(b.engine, Engine::Vlc);
        let mut c = base.clone();
        apply_prefs(&mut c, Prefs::default());
        assert_eq!(c, base);
    }

    #[test]
    fn clear_mime() {
        assert!(!mime_is_clear(None));
        assert!(!mime_is_clear(Some("application/octet-stream")));
        assert!(mime_is_clear(Some("video/mp4")));
    }

    #[test]
    fn report_counts() {
        let raw = RawStream {
            addon: "A".into(), name: "".into(), title: "x".into(), description: None,
            target: direct("https://a/x.mp4"), not_web_ready: false, filename: None, subtitles: vec![],
        };
        let mut s = rank_raw(&raw, None, 0);
        s.health = Health::Alive { mime: None, latency_ms: 1 };
        let r = report(&[s.clone(), RankedSource { engine: Engine::Vlc, health: Health::Unreachable, ..s }]);
        assert_eq!(r[0].total, 2);
        assert_eq!(r[0].alive, 1);
        assert_eq!(r[0].vlc, 1);
    }

    proptest! {
        #[test]
        fn sort_is_descending(scores in proptest::collection::vec(-2000i32..2000, 0..40)) {
            let raw = RawStream {
                addon: "A".into(), name: "".into(), title: "x".into(), description: None,
                target: direct("https://a/x.mp4"), not_web_ready: false, filename: None, subtitles: vec![],
            };
            let base = rank_raw(&raw, None, 0);
            let mut list: Vec<RankedSource> = scores.iter().enumerate().map(|(i, s)| RankedSource { id: i.to_string(), score: *s, ..base.clone() }).collect();
            sort_and_dedupe(&mut list);
            prop_assert_eq!(list.len(), scores.len());
            for w in list.windows(2) { prop_assert!(w[0].score >= w[1].score); }
        }

        #[test]
        fn groups_and_health_order(spec in proptest::collection::vec((0u8..4, 0u8..3, -500i32..500), 0..40)) {
            let raw = RawStream {
                addon: "A".into(), name: "".into(), title: "x".into(), description: None,
                target: direct("https://a/x.mp4"), not_web_ready: false, filename: None, subtitles: vec![],
            };
            let base = rank_raw(&raw, None, 0);
            let engines = [Engine::Native, Engine::Vlc, Engine::YouTube, Engine::External];
            let healths = [Health::Alive { mime: None, latency_ms: 1 }, Health::Checking, Health::Unreachable];
            let mut list: Vec<RankedSource> = spec.iter().enumerate().map(|(i, (e, h, s))| RankedSource {
                id: i.to_string(), engine: engines[*e as usize], health: healths[*h as usize].clone(), score: *s, ..base.clone()
            }).collect();
            sort_and_dedupe(&mut list);
            prop_assert_eq!(list.len(), spec.len());
            for w in list.windows(2) {
                let ka = (engine_group(w[0].engine), health_rank(&w[0].health), -w[0].score);
                let kb = (engine_group(w[1].engine), health_rank(&w[1].health), -w[1].score);
                prop_assert!(ka <= kb);
            }
        }

        #[test]
        fn quality_never_panics(s in "\\PC*") { let _ = parse_quality(&s); }

        #[test]
        fn sniff_never_panics(b in proptest::collection::vec(any::<u8>(), 0..300)) { let _ = sniff(&b); }
    }
}
