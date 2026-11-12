//! Matroska structure: header (Info, Tracks, SeekHead), Cues and Clusters.

use crate::ebml::{self, Element, UNKNOWN};

pub const EBML: u32 = 0x1A45DFA3;
pub const SEGMENT: u32 = 0x18538067;
pub const SEEK_HEAD: u32 = 0x114D9B74;
const SEEK: u32 = 0x4DBB;
const SEEK_ID: u32 = 0x53AB;
const SEEK_POSITION: u32 = 0x53AC;
pub const INFO: u32 = 0x1549A966;
const TIMESTAMP_SCALE: u32 = 0x2AD7B1;
const DURATION: u32 = 0x4489;
pub const TRACKS: u32 = 0x1654AE6B;
const TRACK_ENTRY: u32 = 0xAE;
const TRACK_NUMBER: u32 = 0xD7;
const TRACK_TYPE: u32 = 0x83;
const CODEC_ID: u32 = 0x86;
const CODEC_PRIVATE: u32 = 0x63A2;
const DEFAULT_DURATION: u32 = 0x23E383;
const FLAG_DEFAULT: u32 = 0x88;
const FLAG_ENABLED: u32 = 0xB9;
const LANGUAGE: u32 = 0x22B59C;
const NAME: u32 = 0x536E;
const FLAG_FORCED: u32 = 0x55AA;
const BLOCK_DURATION: u32 = 0x9B;
const VIDEO: u32 = 0xE0;
const PIXEL_WIDTH: u32 = 0xB0;
const PIXEL_HEIGHT: u32 = 0xBA;
const AUDIO: u32 = 0xE1;
const SAMPLING_FREQUENCY: u32 = 0xB5;
const OUTPUT_SAMPLING_FREQUENCY: u32 = 0x78B5;
const CHANNELS: u32 = 0x9F;
const CONTENT_ENCODINGS: u32 = 0x6D80;
pub const CLUSTER: u32 = 0x1F43B675;
pub const CUES: u32 = 0x1C53BB6B;
const CUE_POINT: u32 = 0xBB;
const CUE_TIME: u32 = 0xB3;
const CUE_TRACK_POSITIONS: u32 = 0xB7;
const CUE_TRACK: u32 = 0xF7;
const CUE_CLUSTER_POSITION: u32 = 0xF1;
const TIMECODE: u32 = 0xE7;
const SIMPLE_BLOCK: u32 = 0xA3;
const BLOCK_GROUP: u32 = 0xA0;
const BLOCK: u32 = 0xA1;
const REFERENCE_BLOCK: u32 = 0xFB;

/// Level-1 elements: an unknown-size Cluster ends where one of these starts
const LEVEL1: [u32; 9] = [
    CLUSTER, CUES, INFO, TRACKS, SEEK_HEAD, 0x1254C367, 0x1043A770, 0x1941A469, SEGMENT,
];

#[derive(Debug, Clone, Default)]
pub struct Track {
    pub number: u64,
    pub kind: u64,
    pub codec_id: String,
    pub private: Vec<u8>,
    pub default_duration_ns: u64,
    pub default: bool,
    pub enabled: bool,
    pub language: String,
    pub name: String,
    pub forced: bool,
    pub width: u32,
    pub height: u32,
    pub rate: f64,
    pub out_rate: f64,
    pub channels: u32,
    /// compressed / encrypted content (header stripping etc.): we can't pass it through
    pub encoded: bool,
}

#[derive(Debug, Clone, Default)]
pub struct Header {
    /// absolute file offset of the Segment's data (positions in SeekHead / Cues are relative to it)
    pub segment_data: u64,
    /// absolute end of the Segment (None = unknown size)
    pub segment_end: Option<u64>,
    pub timescale: u64,
    pub duration_ns: f64,
    pub tracks: Vec<Track>,
    pub seeks: Vec<(u32, u64)>,
    /// absolute offset of the first Cluster
    pub first_cluster: Option<u64>,
    pub have_info: bool,
    pub have_tracks: bool,
}

impl Header {
    pub fn seek_abs(&self, id: u32) -> Option<u64> {
        self.seeks.iter().find(|(i, _)| *i == id).map(|(_, p)| self.segment_data + p)
    }
}

#[derive(Debug)]
pub struct MkvError(pub String);

fn err(m: &str) -> MkvError {
    MkvError(m.to_string())
}

/// Parses the start of the file (EBML header, Segment, SeekHead, Info, Tracks up to the first Cluster)
pub fn parse_head(b: &[u8]) -> Result<Header, MkvError> {
    let ebml = ebml::read_element(b, 0).ok_or_else(|| err("not EBML"))?;
    if ebml.id != EBML {
        return Err(err("not Matroska"));
    }
    let seg_pos = ebml.end(b.len());
    let seg = ebml::read_element(b, seg_pos).ok_or_else(|| err("no segment"))?;
    if seg.id != SEGMENT {
        return Err(err("no segment"));
    }
    let mut h = Header {
        segment_data: seg.data as u64,
        segment_end: if seg.size == UNKNOWN { None } else { Some(seg.data as u64 + seg.size) },
        timescale: 1_000_000,
        ..Default::default()
    };
    let mut pos = seg.data;
    while pos < b.len() {
        let Some(e) = ebml::read_element(b, pos) else { break };
        match e.id {
            CLUSTER => {
                h.first_cluster = Some(e.start as u64);
                break;
            }
            SEEK_HEAD if e.complete(b.len()) => parse_seek_head(b, &e, &mut h),
            INFO if e.complete(b.len()) => parse_info(b, &e, &mut h),
            TRACKS if e.complete(b.len()) => parse_tracks(b, &e, &mut h),
            _ => {}
        }
        if e.size == UNKNOWN {
            break;
        }
        pos = e.data + e.size as usize;
    }
    Ok(h)
}

pub fn parse_seek_head(b: &[u8], e: &Element, h: &mut Header) {
    for s in ebml::children(b, e.data, e.end(b.len())) {
        if s.id != SEEK {
            continue;
        }
        let mut id = 0u32;
        let mut p = None;
        for c in ebml::children(b, s.data, s.end(b.len())) {
            match c.id {
                SEEK_ID => id = ebml::uint(b, &c) as u32,
                SEEK_POSITION => p = Some(ebml::uint(b, &c)),
                _ => {}
            }
        }
        if let Some(p) = p {
            h.seeks.push((id, p));
        }
    }
}

pub fn parse_info(b: &[u8], e: &Element, h: &mut Header) {
    h.have_info = true;
    let mut dur = 0.0;
    for c in ebml::children(b, e.data, e.end(b.len())) {
        match c.id {
            TIMESTAMP_SCALE => h.timescale = ebml::uint(b, &c).max(1),
            DURATION => dur = ebml::float(b, &c),
            _ => {}
        }
    }
    h.duration_ns = dur * h.timescale as f64;
}

pub fn parse_tracks(b: &[u8], e: &Element, h: &mut Header) {
    h.have_tracks = true;
    for t in ebml::children(b, e.data, e.end(b.len())) {
        if t.id != TRACK_ENTRY {
            continue;
        }
        let mut tr = Track { default: true, enabled: true, language: "eng".into(), ..Default::default() };
        for c in ebml::children(b, t.data, t.end(b.len())) {
            match c.id {
                TRACK_NUMBER => tr.number = ebml::uint(b, &c),
                TRACK_TYPE => tr.kind = ebml::uint(b, &c),
                CODEC_ID => tr.codec_id = ebml::string(b, &c),
                CODEC_PRIVATE => tr.private = ebml::bytes(b, &c).to_vec(),
                DEFAULT_DURATION => tr.default_duration_ns = ebml::uint(b, &c),
                FLAG_DEFAULT => tr.default = ebml::uint(b, &c) != 0,
                FLAG_ENABLED => tr.enabled = ebml::uint(b, &c) != 0,
                LANGUAGE => tr.language = ebml::string(b, &c),
                NAME => tr.name = ebml::string(b, &c),
                FLAG_FORCED => tr.forced = ebml::uint(b, &c) != 0,
                CONTENT_ENCODINGS => tr.encoded = true,
                VIDEO => {
                    for v in ebml::children(b, c.data, c.end(b.len())) {
                        match v.id {
                            PIXEL_WIDTH => tr.width = ebml::uint(b, &v) as u32,
                            PIXEL_HEIGHT => tr.height = ebml::uint(b, &v) as u32,
                            _ => {}
                        }
                    }
                }
                AUDIO => {
                    for a in ebml::children(b, c.data, c.end(b.len())) {
                        match a.id {
                            SAMPLING_FREQUENCY => tr.rate = ebml::float(b, &a),
                            OUTPUT_SAMPLING_FREQUENCY => tr.out_rate = ebml::float(b, &a),
                            CHANNELS => tr.channels = ebml::uint(b, &a) as u32,
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
        if tr.kind == 2 {
            if tr.rate <= 0.0 {
                tr.rate = 8000.0;
            }
            if tr.channels == 0 {
                tr.channels = 1;
            }
        }
        h.tracks.push(tr);
    }
}

/// One Cues index entry for the video track: time (in timestamp units) and absolute Cluster offset
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cue {
    pub time: u64,
    pub cluster: u64,
}

/// `b` holds the whole Cues element at offset 0
pub fn parse_cues(b: &[u8], segment_data: u64, track: u64) -> Vec<Cue> {
    let Some(cues) = ebml::read_element(b, 0) else { return vec![] };
    if cues.id != CUES {
        return vec![];
    }
    let mut out = Vec::new();
    for p in ebml::children(b, cues.data, cues.end(b.len())) {
        if p.id != CUE_POINT {
            continue;
        }
        let mut time = None;
        let mut pos = None;
        for c in ebml::children(b, p.data, p.end(b.len())) {
            match c.id {
                CUE_TIME => time = Some(ebml::uint(b, &c)),
                CUE_TRACK_POSITIONS => {
                    let mut t = 0;
                    let mut cp = None;
                    for x in ebml::children(b, c.data, c.end(b.len())) {
                        match x.id {
                            CUE_TRACK => t = ebml::uint(b, &x),
                            CUE_CLUSTER_POSITION => cp = Some(ebml::uint(b, &x)),
                            _ => {}
                        }
                    }
                    if t == track && pos.is_none() {
                        pos = cp;
                    }
                }
                _ => {}
            }
        }
        if let (Some(time), Some(pos)) = (time, pos) {
            out.push(Cue { time, cluster: segment_data + pos });
        }
    }
    out.sort_by_key(|c| c.time);
    out.dedup_by_key(|c| c.cluster);
    out
}

#[derive(Debug, Clone)]
pub struct Frame {
    pub track: u64,
    /// presentation time in timestamp units (scaled by Header.timescale), may be negative
    pub pts: i64,
    pub key: bool,
    pub data: Vec<u8>,
    /// index of the lace inside its block (0 for unlaced)
    pub lace: u32,
    /// first frame of a Cluster
    pub cluster_start: bool,
    /// BlockDuration (timestamp units), subtitles
    pub duration: Option<i64>,
}

/// Frames of every complete block in `b`, which starts at a Cluster boundary.
/// Only tracks in `wanted` are kept.
pub fn parse_clusters(b: &[u8], wanted: &[u64]) -> Vec<Frame> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < b.len() {
        let Some(e) = ebml::read_element(b, pos) else { break };
        if e.id == CLUSTER {
            pos = parse_cluster(b, &e, wanted, &mut out);
            continue;
        }
        if e.size == UNKNOWN {
            break;
        }
        pos = e.data + e.size as usize;
    }
    out
}

fn parse_cluster(b: &[u8], cl: &Element, wanted: &[u64], out: &mut Vec<Frame>) -> usize {
    let end = cl.end(b.len());
    let mut tc: i64 = 0;
    let mut pos = cl.data;
    let mut first = true;
    while pos < end {
        let Some(e) = ebml::read_element(b, pos) else { return b.len() };
        if cl.size == UNKNOWN && LEVEL1.contains(&e.id) {
            return pos;
        }
        if e.size == UNKNOWN || e.data as u64 + e.size > b.len() as u64 {
            // truncated at the end of the buffer
            return b.len();
        }
        let data_end = e.data + e.size as usize;
        match e.id {
            TIMECODE => tc = ebml::uint(b, &e) as i64,
            SIMPLE_BLOCK => {
                let before = out.len();
                parse_block(&b[e.data..data_end], tc, None, None, wanted, out);
                if first && out.len() > before {
                    out[before].cluster_start = true;
                    first = false;
                }
            }
            BLOCK_GROUP => {
                let mut block = None;
                let mut referenced = false;
                let mut duration = None;
                for c in ebml::children(b, e.data, data_end) {
                    match c.id {
                        BLOCK => block = Some(c),
                        REFERENCE_BLOCK => referenced = true,
                        BLOCK_DURATION => duration = Some(ebml::uint(b, &c) as i64),
                        _ => {}
                    }
                }
                if let Some(bl) = block {
                    let be = bl.end(b.len());
                    let before = out.len();
                    parse_block(&b[bl.data..be], tc, Some(!referenced), duration, wanted, out);
                    if first && out.len() > before {
                        out[before].cluster_start = true;
                        first = false;
                    }
                }
            }
            _ => {}
        }
        pos = data_end;
    }
    end
}

fn parse_block(d: &[u8], cluster_tc: i64, key_override: Option<bool>, duration: Option<i64>, wanted: &[u64], out: &mut Vec<Frame>) {
    let Some((track, tl)) = ebml::read_vint(d, 0) else { return };
    if !wanted.contains(&track) || d.len() < tl + 3 {
        return;
    }
    let rel = i16::from_be_bytes([d[tl], d[tl + 1]]) as i64;
    let flags = d[tl + 2];
    let key = key_override.unwrap_or(flags & 0x80 != 0);
    let pts = cluster_tc + rel;
    let mut p = tl + 3;
    let lacing = (flags >> 1) & 3;
    if lacing == 0 {
        out.push(Frame { track, pts, key, data: d[p..].to_vec(), lace: 0, cluster_start: false, duration });
        return;
    }
    let Some(&n) = d.get(p) else { return };
    let count = n as usize + 1;
    p += 1;
    let mut sizes: Vec<usize> = Vec::with_capacity(count);
    match lacing {
        1 => {
            // Xiph
            for _ in 0..count - 1 {
                let mut s = 0usize;
                loop {
                    let Some(&x) = d.get(p) else { return };
                    p += 1;
                    s += x as usize;
                    if x != 255 {
                        break;
                    }
                }
                sizes.push(s);
            }
        }
        3 => {
            // EBML
            let Some((first, l)) = ebml::read_vint(d, p) else { return };
            p += l;
            sizes.push(first as usize);
            let mut last = first as i64;
            for _ in 1..count - 1 {
                let Some((raw, l)) = ebml::read_vint(d, p) else { return };
                p += l;
                let bias = (1i64 << (7 * l - 1)) - 1;
                last += raw as i64 - bias;
                if last < 0 {
                    return;
                }
                sizes.push(last as usize);
            }
        }
        _ => {
            // fixed
            let total = d.len().saturating_sub(p);
            for _ in 0..count - 1 {
                sizes.push(total / count);
            }
        }
    }
    let used: usize = sizes.iter().sum();
    if p + used > d.len() {
        return;
    }
    sizes.push(d.len() - p - used);
    for (i, s) in sizes.into_iter().enumerate() {
        out.push(Frame { track, pts, key, data: d[p..p + s].to_vec(), lace: i as u32, cluster_start: false, duration });
        p += s;
    }
}
