//! تحليل SRT / WebVTT / ASS، كشف الترميز (UTF-8 / UTF-16 / Windows-1256)، وإزاحة التوقيت.
use qb_model::Cue;

mod cp1256;

/// يفك بايتات ملف الترجمة إلى نص
pub fn decode(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(&bytes[3..]).into_owned();
    }
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return decode_utf16(&bytes[2..], true);
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        return decode_utf16(&bytes[2..], false);
    }
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        // مو UTF-8: أغلب الترجمات العربية القديمة Windows-1256
        Err(_) => decode_cp1256(bytes),
    }
}

fn decode_utf16(b: &[u8], le: bool) -> String {
    let units: Vec<u16> = b
        .as_chunks::<2>().0.iter()
        .map(|c| if le { u16::from_le_bytes([c[0], c[1]]) } else { u16::from_be_bytes([c[0], c[1]]) })
        .collect();
    String::from_utf16_lossy(&units)
}

pub fn decode_cp1256(b: &[u8]) -> String {
    b.iter().map(|&x| if x < 0x80 { x as char } else { cp1256::HIGH[(x - 0x80) as usize] }).collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Srt,
    Vtt,
    Ass,
}

pub fn detect_format(text: &str, url_hint: Option<&str>) -> Format {
    let t = text.trim_start_matches('\u{FEFF}').trim_start();
    if t.starts_with("WEBVTT") {
        return Format::Vtt;
    }
    if t.starts_with("[Script Info]") || t.contains("\n[Events]") || t.contains("Dialogue:") {
        return Format::Ass;
    }
    if let Some(u) = url_hint {
        let u = u.to_ascii_lowercase();
        let path = u.split('?').next().unwrap_or(&u);
        if path.ends_with(".vtt") {
            return Format::Vtt;
        }
        if path.ends_with(".ass") || path.ends_with(".ssa") {
            return Format::Ass;
        }
    }
    Format::Srt
}

/// يحلل أي صيغة معروفة ويرجّع cues مرتبة
pub fn parse(text: &str, url_hint: Option<&str>) -> Vec<Cue> {
    let mut cues = match detect_format(text, url_hint) {
        Format::Ass => parse_ass(text),
        _ => parse_srt_vtt(text),
    };
    cues.sort_by_key(|c| c.start_ms);
    cues
}

pub fn parse_bytes(bytes: &[u8], url_hint: Option<&str>) -> Vec<Cue> {
    parse(&decode(bytes), url_hint)
}

/// "00:01:02,500" أو "01:02.500" أو "0:01:02.50"
pub fn parse_timestamp(s: &str) -> Option<u64> {
    let s = s.split_whitespace().next()?;
    let s = s.replace(',', ".");
    let (hms, frac) = match s.rfind('.') {
        Some(i) => (&s[..i], &s[i + 1..]),
        None => (s.as_str(), "0"),
    };
    let parts: Vec<&str> = hms.split(':').collect();
    let (h, m, sec): (u64, u64, u64) = match parts.as_slice() {
        [h, m, s] => (h.parse().ok()?, m.parse().ok()?, s.parse().ok()?),
        [m, s] => (0, m.parse().ok()?, s.parse().ok()?),
        _ => return None,
    };
    if m >= 60 || sec >= 60 {
        return None;
    }
    let frac_digits: String = frac.chars().take(3).collect();
    if !frac_digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let ms = match frac_digits.len() {
        0 => 0,
        1 => frac_digits.parse::<u64>().ok()? * 100,
        2 => frac_digits.parse::<u64>().ok()? * 10,
        _ => frac_digits.parse::<u64>().ok()?,
    };
    Some(((h * 60 + m) * 60 + sec) * 1000 + ms)
}

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_angle = false;
    let mut in_brace = false;
    for c in s.chars() {
        match c {
            '<' => in_angle = true,
            '>' if in_angle => in_angle = false,
            '{' => in_brace = true,
            '}' if in_brace => in_brace = false,
            _ if !in_angle && !in_brace => out.push(c),
            _ => {}
        }
    }
    out.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ")
}

fn parse_srt_vtt(text: &str) -> Vec<Cue> {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut cues = Vec::new();
    for block in normalized.split("\n\n") {
        let lines: Vec<&str> = block.lines().map(|l| l.trim_end()).filter(|l| !l.is_empty()).collect();
        let Some(ti) = lines.iter().position(|l| l.contains("-->")) else { continue };
        let mut it = lines[ti].splitn(2, "-->");
        let (Some(a), Some(b)) = (it.next(), it.next()) else { continue };
        let (Some(start), Some(end)) = (parse_timestamp(a), parse_timestamp(b)) else { continue };
        if end < start {
            continue;
        }
        let body: Vec<String> = lines[ti + 1..].iter().map(|l| strip_tags(l)).filter(|l| !l.trim().is_empty()).collect();
        if body.is_empty() {
            continue;
        }
        cues.push(Cue { start_ms: start, end_ms: end, text: body.join("\n") });
    }
    cues
}

fn parse_ass(text: &str) -> Vec<Cue> {
    let normalized = text.replace("\r\n", "\n");
    let mut cues = Vec::new();
    let mut fields: Vec<String> = vec![];
    let mut in_events = false;
    for line in normalized.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            in_events = l.eq_ignore_ascii_case("[Events]");
            continue;
        }
        if !in_events {
            continue;
        }
        if let Some(f) = l.strip_prefix("Format:") {
            fields = f.split(',').map(|x| x.trim().to_ascii_lowercase()).collect();
            continue;
        }
        let Some(d) = l.strip_prefix("Dialogue:") else { continue };
        if fields.is_empty() {
            fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"].iter().map(|s| s.to_string()).collect();
        }
        let parts: Vec<&str> = d.splitn(fields.len(), ',').collect();
        if parts.len() < fields.len() {
            continue;
        }
        let get = |name: &str| fields.iter().position(|f| f == name).map(|i| parts[i].trim());
        let (Some(s), Some(e), Some(t)) = (get("start"), get("end"), fields.iter().position(|f| f == "text").map(|i| parts[i])) else { continue };
        let (Some(start), Some(end)) = (parse_timestamp(s), parse_timestamp(e)) else { continue };
        let body = strip_tags(&t.replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " "));
        if body.trim().is_empty() || end < start {
            continue;
        }
        cues.push(Cue { start_ms: start, end_ms: end, text: body.trim().to_string() });
    }
    cues
}

/// إزاحة التوقيت: موجب يأخّر وسالب يقدّم
pub fn shift(cues: &[Cue], offset_ms: i64) -> Vec<Cue> {
    cues.iter()
        .filter_map(|c| {
            let s = c.start_ms as i64 + offset_ms;
            let e = c.end_ms as i64 + offset_ms;
            if e <= 0 {
                return None;
            }
            Some(Cue { start_ms: s.max(0) as u64, end_ms: e as u64, text: c.text.clone() })
        })
        .collect()
}

/// الـ cue اللي ينعرض الحين (بحث ثنائي)
pub fn active_cue(cues: &[Cue], t_ms: u64) -> Option<&Cue> {
    let idx = cues.partition_point(|c| c.start_ms <= t_ms);
    cues[..idx].iter().rev().take(4).find(|c| c.end_ms >= t_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    const SRT: &str = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>مرحبا</i>\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nLine A\r\nLine B\r\n";

    #[test]
    fn parses_srt() {
        let c = parse(SRT, None);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].start_ms, 1000);
        assert_eq!(c[0].end_ms, 2500);
        assert_eq!(c[0].text, "مرحبا");
        assert_eq!(c[1].text, "Line A\nLine B");
    }

    #[test]
    fn parses_vtt() {
        let v = "WEBVTT\n\nNOTE x\n\n00:01.000 --> 00:02.000 align:start\nHi <b>there</b>\n\nid\n01:00:00.500 --> 01:00:01.000\nLater\n";
        let c = parse(v, None);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].start_ms, 1000);
        assert_eq!(c[0].text, "Hi there");
        assert_eq!(c[1].start_ms, 3_600_500);
    }

    #[test]
    fn parses_ass() {
        let a = "[Script Info]\nTitle: x\n\n[V4+ Styles]\nFormat: Name\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\b1}أهلًا, يا صديق\\Nسطر\n";
        let c = parse(a, None);
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].start_ms, 1500);
        assert_eq!(c[0].text, "أهلًا, يا صديق\nسطر");
    }

    #[test]
    fn decodes_cp1256_arabic() {
        // "مرحبا" بترميز Windows-1256
        let bytes = [0xE3, 0xD1, 0xCD, 0xC8, 0xC7];
        assert_eq!(decode(&bytes), "مرحبا");
    }

    #[test]
    fn decodes_utf16_and_bom() {
        let mut le = vec![0xFF, 0xFE];
        for u in "سلام".encode_utf16() {
            le.extend_from_slice(&u.to_le_bytes());
        }
        assert_eq!(decode(&le), "سلام");
        let mut bom = vec![0xEF, 0xBB, 0xBF];
        bom.extend_from_slice("abc".as_bytes());
        assert_eq!(decode(&bom), "abc");
    }

    #[test]
    fn shift_and_active() {
        let c = parse(SRT, None);
        let s = shift(&c, -1500);
        assert_eq!(s[0].start_ms, 0);
        assert_eq!(s[0].end_ms, 1000);
        assert_eq!(shift(&c, -10_000).len(), 0);
        assert_eq!(active_cue(&c, 1200).unwrap().start_ms, 1000);
        assert!(active_cue(&c, 2800).is_none());
        assert_eq!(active_cue(&c, 3500).unwrap().start_ms, 3000);
    }

    #[test]
    fn timestamps() {
        assert_eq!(parse_timestamp("00:00:01,000"), Some(1000));
        assert_eq!(parse_timestamp("1:02.5"), Some(62_500));
        assert_eq!(parse_timestamp("0:00:01.50"), Some(1500));
        assert_eq!(parse_timestamp("xx"), None);
        assert_eq!(parse_timestamp("00:61:00,000"), None);
    }

    proptest! {
        #[test]
        fn parse_never_panics(s in "\\PC*") { let _ = parse(&s, None); }

        #[test]
        fn decode_never_panics(b in proptest::collection::vec(any::<u8>(), 0..512)) { let _ = parse_bytes(&b, Some("x.srt")); }

        #[test]
        fn roundtrip_timestamp(h in 0u64..10, m in 0u64..60, s in 0u64..60, ms in 0u64..1000) {
            let t = format!("{h:02}:{m:02}:{s:02},{ms:03}");
            prop_assert_eq!(parse_timestamp(&t), Some(((h * 60 + m) * 60 + s) * 1000 + ms));
        }
    }
}
