//! Matroska text subtitles (SRT / ASS / SSA / WebVTT) -> WebVTT segments for HLS.

use crate::mkv::Track;

pub fn supported(t: &Track) -> bool {
    t.kind == 0x11 && matches!(t.codec_id.as_str(), "S_TEXT/UTF8" | "S_TEXT/ASS" | "S_TEXT/SSA" | "S_TEXT/WEBVTT" | "S_ASS" | "S_SSA")
}

#[derive(Debug, Clone)]
pub struct Cue {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

/// Text of one stored subtitle frame, as WebVTT cue payload (empty = nothing to show)
pub fn cue_text(t: &Track, data: &[u8]) -> String {
    let raw = String::from_utf8_lossy(data).to_string();
    let text = match t.codec_id.as_str() {
        "S_TEXT/ASS" | "S_TEXT/SSA" | "S_ASS" | "S_SSA" => {
            // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            let body = raw.splitn(9, ',').nth(8).unwrap_or("").to_string();
            strip_ass(&body)
        }
        _ => raw,
    };
    clean_markup(&text)
}

fn strip_ass(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut depth = 0;
    let mut italic = false;
    let mut chars = s.chars().peekable();
    let mut tag = String::new();
    while let Some(c) = chars.next() {
        match c {
            '{' => {
                depth += 1;
                tag.clear();
            }
            '}' if depth > 0 => {
                depth -= 1;
                // keep italics (\i1 / \i0), the one style that changes meaning
                if tag.contains("\\i1") && !italic {
                    out.push_str("<i>");
                    italic = true;
                } else if tag.contains("\\i0") && italic {
                    out.push_str("</i>");
                    italic = false;
                }
            }
            _ if depth > 0 => tag.push(c),
            '\\' => match chars.peek() {
                Some('N') | Some('n') => {
                    chars.next();
                    out.push('\n');
                }
                Some('h') => {
                    chars.next();
                    out.push(' ');
                }
                _ => out.push(c),
            },
            _ => out.push(c),
        }
    }
    if italic {
        out.push_str("</i>");
    }
    out
}

/// Keeps <i> <b> <u>, drops other tags, escapes the rest for WebVTT
fn clean_markup(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let b = s.as_bytes();
    while i < s.len() {
        let c = s[i..].chars().next().unwrap();
        if c == '<' {
            if let Some(end) = s[i..].find('>') {
                let tag = s[i + 1..i + end].trim().to_ascii_lowercase();
                let keep = matches!(tag.as_str(), "i" | "/i" | "b" | "/b" | "u" | "/u");
                if keep {
                    out.push('<');
                    out.push_str(&tag);
                    out.push('>');
                }
                i += end + 1;
                continue;
            }
            out.push_str("&lt;");
        } else if c == '>' {
            out.push_str("&gt;");
        } else if c == '&' {
            out.push_str("&amp;");
        } else if c == '\r' {
        } else {
            out.push(c);
        }
        i += c.len_utf8();
        let _ = b;
    }
    // no blank lines inside a cue (they would end it)
    out.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n")
}

fn stamp(ms: i64) -> String {
    let ms = ms.max(0);
    format!("{:02}:{:02}:{:02}.{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

/// One WebVTT segment (times are media times; MPEGTS:0 = media time 0 in the fMP4 video)
pub fn segment(cues: &[Cue]) -> String {
    let mut out = String::from("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n");
    for c in cues {
        if c.text.is_empty() || c.end_ms <= c.start_ms {
            continue;
        }
        out.push_str(&format!("{} --> {}\n{}\n\n", stamp(c.start_ms), stamp(c.end_ms), c.text));
    }
    out
}

/// ISO 639-2 -> the 2-letter code AVPlayer shows nicely
pub fn lang2(l: &str) -> String {
    let m = match l {
        "ara" => "ar",
        "eng" => "en",
        "fre" | "fra" => "fr",
        "spa" => "es",
        "ger" | "deu" => "de",
        "ita" => "it",
        "tur" => "tr",
        "per" | "fas" => "fa",
        "urd" => "ur",
        "hin" => "hi",
        "rus" => "ru",
        "por" => "pt",
        "jpn" => "ja",
        "kor" => "ko",
        "chi" | "zho" => "zh",
        "ind" => "id",
        "may" | "msa" => "ms",
        "dut" | "nld" => "nl",
        "pol" => "pl",
        "swe" => "sv",
        "heb" => "he",
        "gre" | "ell" => "el",
        "tha" => "th",
        "vie" => "vi",
        "rum" | "ron" => "ro",
        "und" | "" => "und",
        other => other,
    };
    m.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ass_text() {
        let t = Track { kind: 0x11, codec_id: "S_TEXT/ASS".into(), ..Default::default() };
        assert_eq!(cue_text(&t, b"3,0,Default,,0,0,0,,{\\i1}Hello{\\i0}\\Nworld, ok"), "<i>Hello</i>\nworld, ok");
        let s = Track { kind: 0x11, codec_id: "S_TEXT/UTF8".into(), ..Default::default() };
        assert_eq!(cue_text(&s, b"<font color=red>A & B</font>\r\n<i>c</i>"), "A &amp; B\n<i>c</i>");
        assert_eq!(stamp(3_723_004), "01:02:03.004");
    }
}
