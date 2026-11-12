//! fMP4 (CMAF-style) init segment and fragments.

use crate::codec::{AudioCodec, AudioOut, VideoCodec};

pub const VIDEO_ID: u32 = 1;
pub const AUDIO_ID: u32 = 2;
pub const VIDEO_TIMESCALE: u32 = 90_000;

struct W {
    b: Vec<u8>,
}

impl W {
    fn new() -> Self {
        W { b: Vec::with_capacity(4096) }
    }
    fn u8(&mut self, v: u8) {
        self.b.push(v);
    }
    fn u16(&mut self, v: u16) {
        self.b.extend_from_slice(&v.to_be_bytes());
    }
    fn u32(&mut self, v: u32) {
        self.b.extend_from_slice(&v.to_be_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.b.extend_from_slice(&v.to_be_bytes());
    }
    fn bytes(&mut self, v: &[u8]) {
        self.b.extend_from_slice(v);
    }
    fn zeros(&mut self, n: usize) {
        self.b.resize(self.b.len() + n, 0);
    }
    fn open(&mut self, t: &[u8; 4]) -> usize {
        let p = self.b.len();
        self.u32(0);
        self.bytes(t);
        p
    }
    fn full(&mut self, t: &[u8; 4], version: u8, flags: u32) -> usize {
        let p = self.open(t);
        self.u32(((version as u32) << 24) | (flags & 0xFF_FFFF));
        p
    }
    fn close(&mut self, p: usize) {
        let len = (self.b.len() - p) as u32;
        self.b[p..p + 4].copy_from_slice(&len.to_be_bytes());
    }
}

const MATRIX: [u32; 9] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000];

pub struct VideoInit<'a> {
    pub codec: VideoCodec,
    pub config: &'a [u8],
    pub width: u32,
    pub height: u32,
}

pub fn init(video: &VideoInit, audio: Option<&AudioOut>, lang: &str) -> Vec<u8> {
    let mut w = W::new();
    let p = w.open(b"ftyp");
    w.bytes(b"iso6");
    w.u32(0);
    for b in [b"iso6", b"cmfc", b"mp41", b"dash"] {
        w.bytes(b);
    }
    w.close(p);

    let moov = w.open(b"moov");
    let p = w.full(b"mvhd", 0, 0);
    w.u32(0);
    w.u32(0);
    w.u32(1000);
    w.u32(0);
    w.u32(0x0001_0000);
    w.u16(0x0100);
    w.zeros(10);
    MATRIX.iter().for_each(|m| w.u32(*m));
    w.zeros(24);
    w.u32(3);
    w.close(p);

    trak(&mut w, VIDEO_ID, VIDEO_TIMESCALE, "und", |w| video_entry(w, video), Some((video.width, video.height)));
    if let Some(a) = audio {
        trak(&mut w, AUDIO_ID, a.rate, lang, |w| audio_entry(w, a), None);
    }

    let mvex = w.open(b"mvex");
    let mut ids = vec![VIDEO_ID];
    if audio.is_some() {
        ids.push(AUDIO_ID);
    }
    for id in ids {
        let p = w.full(b"trex", 0, 0);
        w.u32(id);
        w.u32(1);
        w.u32(0);
        w.u32(0);
        w.u32(0);
        w.close(p);
    }
    w.close(mvex);
    w.close(moov);
    w.b
}

fn lang_code(lang: &str) -> u16 {
    let l: Vec<u8> = lang.bytes().filter(|c| c.is_ascii_lowercase()).take(3).collect();
    if l.len() != 3 {
        return lang_code("und");
    }
    (((l[0] - 0x60) as u16) << 10) | (((l[1] - 0x60) as u16) << 5) | ((l[2] - 0x60) as u16)
}

fn trak(w: &mut W, id: u32, timescale: u32, lang: &str, entry: impl FnOnce(&mut W), size: Option<(u32, u32)>) {
    let trak = w.open(b"trak");
    let p = w.full(b"tkhd", 0, 3);
    w.u32(0);
    w.u32(0);
    w.u32(id);
    w.u32(0);
    w.u32(0);
    w.zeros(8);
    w.u16(0);
    w.u16(0);
    w.u16(if size.is_none() { 0x0100 } else { 0 });
    w.u16(0);
    MATRIX.iter().for_each(|m| w.u32(*m));
    let (wd, ht) = size.unwrap_or((0, 0));
    w.u32(wd << 16);
    w.u32(ht << 16);
    w.close(p);

    let mdia = w.open(b"mdia");
    let p = w.full(b"mdhd", 0, 0);
    w.u32(0);
    w.u32(0);
    w.u32(timescale);
    w.u32(0);
    w.u16(lang_code(lang));
    w.u16(0);
    w.close(p);
    let p = w.full(b"hdlr", 0, 0);
    w.u32(0);
    w.bytes(if size.is_some() { b"vide" } else { b"soun" });
    w.zeros(12);
    w.bytes(if size.is_some() { b"VideoHandler\0" } else { b"SoundHandler\0" });
    w.close(p);

    let minf = w.open(b"minf");
    if size.is_some() {
        let p = w.full(b"vmhd", 0, 1);
        w.zeros(8);
        w.close(p);
    } else {
        let p = w.full(b"smhd", 0, 0);
        w.zeros(4);
        w.close(p);
    }
    let dinf = w.open(b"dinf");
    let dref = w.full(b"dref", 0, 0);
    w.u32(1);
    let p = w.full(b"url ", 0, 1);
    w.close(p);
    w.close(dref);
    w.close(dinf);

    let stbl = w.open(b"stbl");
    let stsd = w.full(b"stsd", 0, 0);
    w.u32(1);
    entry(w);
    w.close(stsd);
    for t in [b"stts", b"stsc", b"stco"] {
        let p = w.full(t, 0, 0);
        w.u32(0);
        w.close(p);
    }
    let p = w.full(b"stsz", 0, 0);
    w.u32(0);
    w.u32(0);
    w.close(p);
    w.close(stbl);
    w.close(minf);
    w.close(mdia);
    w.close(trak);
}

fn video_entry(w: &mut W, v: &VideoInit) {
    let p = w.open(match v.codec {
        VideoCodec::Avc => b"avc1",
        VideoCodec::Hevc => b"hvc1",
    });
    w.zeros(6);
    w.u16(1);
    w.zeros(16);
    w.u16(v.width as u16);
    w.u16(v.height as u16);
    w.u32(0x0048_0000);
    w.u32(0x0048_0000);
    w.u32(0);
    w.u16(1);
    w.zeros(32);
    w.u16(0x0018);
    w.u16(0xFFFF);
    let c = w.open(match v.codec {
        VideoCodec::Avc => b"avcC",
        VideoCodec::Hevc => b"hvcC",
    });
    w.bytes(v.config);
    w.close(c);
    w.close(p);
}

fn descriptor(w: &mut W, tag: u8, body: &[u8]) {
    w.u8(tag);
    let n = body.len() as u32;
    w.u8(0x80 | ((n >> 21) & 0x7F) as u8);
    w.u8(0x80 | ((n >> 14) & 0x7F) as u8);
    w.u8(0x80 | ((n >> 7) & 0x7F) as u8);
    w.u8((n & 0x7F) as u8);
    w.bytes(body);
}

fn esds(w: &mut W, object_type: u8, dsi: &[u8]) {
    let p = w.full(b"esds", 0, 0);
    let mut dec = W::new();
    dec.u8(object_type);
    dec.u8(0x15); // audio stream
    dec.zeros(3);
    dec.u32(0);
    dec.u32(0);
    if !dsi.is_empty() {
        descriptor(&mut dec, 0x05, dsi);
    }
    let mut es = W::new();
    es.u16(0);
    es.u8(0);
    descriptor(&mut es, 0x04, &dec.b);
    descriptor(&mut es, 0x06, &[0x02]);
    descriptor(w, 0x03, &es.b);
    w.close(p);
}

fn audio_entry(w: &mut W, a: &AudioOut) {
    let p = w.open(match a.codec {
        AudioCodec::Aac(_) | AudioCodec::Mp3 => b"mp4a",
        AudioCodec::Ac3(_) => b"ac-3",
        AudioCodec::Eac3(_) => b"ec-3",
    });
    w.zeros(6);
    w.u16(1);
    w.zeros(8);
    w.u16(a.channels.clamp(1, 8) as u16);
    w.u16(16);
    w.u16(0);
    w.u16(0);
    w.u32((a.rate.min(65535)) << 16);
    match &a.codec {
        AudioCodec::Aac(asc) => esds(w, 0x40, asc),
        AudioCodec::Mp3 => esds(w, 0x6B, &[]),
        AudioCodec::Ac3(d) => {
            let c = w.open(b"dac3");
            w.bytes(d);
            w.close(c);
        }
        AudioCodec::Eac3(d) => {
            let c = w.open(b"dec3");
            w.bytes(d);
            w.close(c);
        }
    }
    w.close(p);
}

pub struct Sample<'a> {
    pub data: &'a [u8],
    pub duration: u32,
    pub cto: i32,
    pub key: bool,
}

pub struct TrackRun<'a> {
    pub id: u32,
    pub base_time: u64,
    pub samples: Vec<Sample<'a>>,
    pub video: bool,
}

/// styp + moof + mdat for one segment
pub fn fragment(seq: u32, runs: &[TrackRun]) -> Vec<u8> {
    let mut w = W::new();
    let p = w.open(b"styp");
    w.bytes(b"msdh");
    w.u32(0);
    w.bytes(b"msdh");
    w.bytes(b"msix");
    w.close(p);

    let moof_start = w.b.len();
    let moof = w.open(b"moof");
    let p = w.full(b"mfhd", 0, 0);
    w.u32(seq);
    w.close(p);
    let mut offset_slots = Vec::new();
    for r in runs.iter().filter(|r| !r.samples.is_empty()) {
        let traf = w.open(b"traf");
        let p = w.full(b"tfhd", 0, 0x02_0000);
        w.u32(r.id);
        w.close(p);
        let p = w.full(b"tfdt", 1, 0);
        w.u64(r.base_time);
        w.close(p);
        let flags = 0x001 | 0x100 | 0x200 | 0x400 | if r.video { 0x800 } else { 0 };
        let p = w.full(b"trun", if r.video { 1 } else { 0 }, flags);
        w.u32(r.samples.len() as u32);
        offset_slots.push(w.b.len());
        w.u32(0);
        for s in &r.samples {
            w.u32(s.duration);
            w.u32(s.data.len() as u32);
            let sf: u32 = if !r.video || s.key { 0x0200_0000 } else { 0x0101_0000 };
            w.u32(sf);
            if r.video {
                w.u32(s.cto as u32);
            }
        }
        w.close(p);
        w.close(traf);
    }
    w.close(moof);
    let moof_len = w.b.len() - moof_start;

    let total: usize = runs.iter().flat_map(|r| r.samples.iter()).map(|s| s.data.len()).sum();
    let mut data_off = moof_len + 8;
    for (slot, r) in offset_slots.iter().zip(runs.iter().filter(|r| !r.samples.is_empty())) {
        w.b[*slot..*slot + 4].copy_from_slice(&(data_off as u32).to_be_bytes());
        data_off += r.samples.iter().map(|s| s.data.len()).sum::<usize>();
    }
    w.u32((total + 8) as u32);
    w.bytes(b"mdat");
    for r in runs.iter().filter(|r| !r.samples.is_empty()) {
        for s in &r.samples {
            w.bytes(s.data);
        }
    }
    w.b
}
