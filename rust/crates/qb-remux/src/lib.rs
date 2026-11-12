//! On-the-fly MKV -> HLS (fMP4) remux for AVPlayer, served from 127.0.0.1.
//!
//! AVPlayer can't open Matroska, but most MKV releases carry H.264/HEVC with AAC/AC-3/E-AC-3,
//! which AVPlayer decodes in hardware. We read the MKV over HTTP range requests, cut it at the
//! video keyframes listed in its Cues index, and rewrap each piece as an fMP4 segment. Nothing is
//! re-encoded. Anything else (DTS, TrueHD, Opus, VP9, no Cues index, ...) returns an error and the
//! app plays the source with VLC.

pub mod codec;
pub mod ebml;
pub mod mkv;
pub mod mp4;
pub mod vtt;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use codec::{AudioOut, VideoCodec};
use mkv::{Cue, Frame, Header, Track};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::OnceCell;

#[derive(Debug, Clone)]
pub struct RemuxError(pub String);

impl std::fmt::Display for RemuxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RemuxError {}

fn e(m: impl Into<String>) -> RemuxError {
    RemuxError(m.into())
}

/// Target length of one HLS segment
const TARGET_NS: u64 = 5_000_000_000;
/// Biggest byte range read at once for one segment (a 5s piece of a 4K remux is ~30 MB)
const MAX_SEGMENT_BYTES: u64 = 160 * 1024 * 1024;

// MARK: - source reader

enum Source {
    Http { client: reqwest::Client, url: String, headers: reqwest::header::HeaderMap },
    File(PathBuf),
}

impl Source {
    async fn len(&self) -> Result<u64, RemuxError> {
        match self {
            Source::File(p) => Ok(tokio::fs::metadata(p).await.map_err(|x| e(x.to_string()))?.len()),
            Source::Http { client, url, headers } => {
                let r = client
                    .get(url)
                    .headers(headers.clone())
                    .header(reqwest::header::RANGE, "bytes=0-0")
                    .send()
                    .await
                    .map_err(|x| e(format!("http: {x}")))?;
                if r.status() == reqwest::StatusCode::PARTIAL_CONTENT {
                    if let Some(total) = r
                        .headers()
                        .get(reqwest::header::CONTENT_RANGE)
                        .and_then(|v| v.to_str().ok())
                        .and_then(|v| v.rsplit('/').next())
                        .and_then(|v| v.trim().parse::<u64>().ok())
                    {
                        return Ok(total);
                    }
                }
                Err(e(format!("server doesn't support byte ranges (HTTP {})", r.status().as_u16())))
            }
        }
    }

    /// bytes [from, to)
    async fn read(&self, from: u64, to: u64) -> Result<Vec<u8>, RemuxError> {
        if to <= from {
            return Ok(vec![]);
        }
        match self {
            Source::File(p) => {
                use tokio::io::AsyncSeekExt;
                let mut f = tokio::fs::File::open(p).await.map_err(|x| e(x.to_string()))?;
                f.seek(std::io::SeekFrom::Start(from)).await.map_err(|x| e(x.to_string()))?;
                let mut buf = vec![0u8; (to - from) as usize];
                let mut got = 0;
                while got < buf.len() {
                    let n = f.read(&mut buf[got..]).await.map_err(|x| e(x.to_string()))?;
                    if n == 0 {
                        break;
                    }
                    got += n;
                }
                buf.truncate(got);
                Ok(buf)
            }
            Source::Http { client, url, headers } => {
                let mut last = String::new();
                for attempt in 0..3 {
                    if attempt > 0 {
                        tokio::time::sleep(Duration::from_millis(400 * attempt)).await;
                    }
                    let r = client
                        .get(url)
                        .headers(headers.clone())
                        .header(reqwest::header::RANGE, format!("bytes={}-{}", from, to - 1))
                        .send()
                        .await;
                    match r {
                        Ok(r) if r.status() == reqwest::StatusCode::PARTIAL_CONTENT => match r.bytes().await {
                            Ok(b) => return Ok(b.to_vec()),
                            Err(x) => last = x.to_string(),
                        },
                        Ok(r) => last = format!("HTTP {}", r.status().as_u16()),
                        Err(x) => last = x.to_string(),
                    }
                }
                Err(e(format!("read {from}-{to}: {last}")))
            }
        }
    }
}

// MARK: - session

#[derive(Debug, Clone)]
struct Segment {
    /// presentation window in Matroska timestamp units
    start: u64,
    end: u64,
    /// byte range [from, to)
    from: u64,
    to: u64,
}

pub struct Session {
    source: Source,
    header: Header,
    video: Track,
    video_codec: VideoCodec,
    audio: Option<(Track, AudioOut)>,
    segments: Vec<Segment>,
    init: Vec<u8>,
    /// text subtitle tracks carried along as WebVTT renditions (the native player lists them)
    subs: Vec<Track>,
    cache: Mutex<HashMap<usize, Arc<OnceCell<Arc<Built>>>>>,
}

/// One segment: the fMP4 piece and the subtitle cues inside its window, per subtitle track
struct Built {
    media: Arc<Vec<u8>>,
    subs: Vec<Vec<vtt::Cue>>,
}

#[derive(Debug, Clone)]
pub struct Info {
    pub video_codec: String,
    pub audio_codec: String,
    pub duration_s: f64,
    pub segments: usize,
    pub subtitles: usize,
}

fn to_ticks(ts: i64, timescale: u64, rate: u64) -> i64 {
    ((ts as i128 * timescale as i128 * rate as i128) / 1_000_000_000i128) as i64
}

impl Session {
    async fn open(source: Source) -> Result<Session, RemuxError> {
        let len = source.len().await?;
        let head = source.read(0, len.min(2 * 1024 * 1024)).await?;
        let mut header = mkv::parse_head(&head).map_err(|x| e(x.0))?;

        // Info / Tracks after the first megabytes: follow the SeekHead
        for (id, have) in [(mkv::INFO, header.have_info), (mkv::TRACKS, header.have_tracks)] {
            if have {
                continue;
            }
            let pos = header.seek_abs(id).ok_or_else(|| e("no track list"))?;
            let buf = read_element(&source, pos, len, 8 * 1024 * 1024).await?;
            let el = ebml::read_element(&buf, 0).ok_or_else(|| e("bad header"))?;
            if id == mkv::INFO {
                mkv::parse_info(&buf, &el, &mut header);
            } else {
                mkv::parse_tracks(&buf, &el, &mut header);
            }
        }

        let video = header
            .tracks
            .iter()
            .find(|t| t.kind == 1 && t.enabled)
            .or_else(|| header.tracks.iter().find(|t| t.kind == 1))
            .cloned()
            .ok_or_else(|| e("no video track"))?;
        if video.encoded {
            return Err(e("compressed video track"));
        }
        let video_codec = VideoCodec::from_track(&video).map_err(e)?;
        let audio_track = header
            .tracks
            .iter()
            .find(|t| t.kind == 2 && t.enabled && t.default)
            .or_else(|| header.tracks.iter().find(|t| t.kind == 2))
            .cloned();
        if let Some(a) = &audio_track {
            codec::audio_supported(a).map_err(e)?;
            if a.encoded {
                return Err(e("compressed audio track"));
            }
        }

        // Cues: keyframe index of the video track
        let cues_pos = header.seek_abs(mkv::CUES).ok_or_else(|| e("no seek index (Cues)"))?;
        let cues_buf = read_element(&source, cues_pos, len, 16 * 1024 * 1024).await?;
        let cues = mkv::parse_cues(&cues_buf, header.segment_data, video.number);
        if cues.len() < 2 {
            return Err(e("seek index too small"));
        }
        let first_cluster = header.first_cluster.unwrap_or(cues[0].cluster).min(cues[0].cluster);
        let mut clusters_end = header.segment_end.unwrap_or(len).min(len);
        let last_cluster = cues.last().map(|c| c.cluster).unwrap_or(0);
        if cues_pos > last_cluster && cues_pos < clusters_end {
            clusters_end = cues_pos;
        }
        let duration_ts = if header.duration_ns > 0.0 {
            (header.duration_ns / header.timescale as f64) as u64
        } else {
            return Err(e("unknown duration"));
        };
        let segments = plan_segments(&cues, header.timescale, first_cluster, clusters_end, duration_ts);
        if segments.iter().any(|s| s.to - s.from > MAX_SEGMENT_BYTES) {
            return Err(e("keyframes too far apart"));
        }

        let subs: Vec<Track> = header.tracks.iter().filter(|t| vtt::supported(t) && !t.encoded).cloned().collect();
        let mut s = Session {
            source,
            header,
            video,
            video_codec,
            audio: None,
            segments,
            init: vec![],
            subs,
            cache: Mutex::new(HashMap::new()),
        };

        // Audio config (AC-3 / E-AC-3 / MP3 need a real frame) from the first segment
        let first = s.read_frames(0).await?;
        if let Some(at) = audio_track {
            let frame = first.iter().find(|f| f.track == at.number).ok_or_else(|| e("no audio in first segment"))?;
            let out = codec::audio_out(&at, &frame.data).map_err(e)?;
            s.audio = Some((at, out));
        }
        if !first.iter().any(|f| f.track == s.video.number && f.key) {
            return Err(e("no keyframe in first segment"));
        }
        let lang = s.audio.as_ref().map(|(t, _)| t.language.clone()).unwrap_or_else(|| "und".into());
        s.init = mp4::init(
            &mp4::VideoInit { codec: s.video_codec, config: &s.video.private, width: s.video.width, height: s.video.height },
            s.audio.as_ref().map(|(_, o)| o),
            &lang,
        );
        // first segment is ready already
        let built = Arc::new(s.build(0, first)?);
        let cell = Arc::new(OnceCell::new());
        let _ = cell.set(built);
        s.cache.lock().unwrap().insert(0, cell);
        Ok(s)
    }

    pub fn info(&self) -> Info {
        Info {
            video_codec: self.video_codec.name().into(),
            audio_codec: self.audio.as_ref().map(|(_, o)| o.name().to_string()).unwrap_or_default(),
            duration_s: self.header.duration_ns / 1e9,
            segments: self.segments.len(),
            subtitles: self.subs.len(),
        }
    }

    fn secs(&self, ts: u64) -> f64 {
        ts as f64 * self.header.timescale as f64 / 1e9
    }

    /// Master playlist: the video+audio stream plus one WebVTT rendition per text subtitle track
    pub fn master(&self) -> String {
        let mut out = String::from("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n");
        for (i, t) in self.subs.iter().enumerate() {
            let lang = vtt::lang2(&t.language);
            let name = if t.name.trim().is_empty() { lang.to_uppercase() } else { t.name.replace('"', "'") };
            out.push_str(&format!(
                "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"{}\",LANGUAGE=\"{}\",DEFAULT=NO,AUTOSELECT={},FORCED={},URI=\"sub{}.m3u8\"\n",
                if i > 0 && self.subs[..i].iter().any(|p| p.name == t.name && p.language == t.language) { format!("{name} {}", i + 1) } else { name },
                lang,
                if t.forced { "YES" } else { "NO" },
                if t.forced { "YES" } else { "NO" },
                i
            ));
        }
        let codecs = (codec::video_codec_string(self.video_codec, &self.video.private), self.audio.as_ref().map(|(_, o)| &o.codec));
        let audio = match codecs.1 {
            Some(codec::AudioCodec::Aac(_)) => ",mp4a.40.2",
            Some(codec::AudioCodec::Ac3(_)) => ",ac-3",
            Some(codec::AudioCodec::Eac3(_)) => ",ec-3",
            Some(codec::AudioCodec::Mp3) => ",mp4a.40.34",
            None => "",
        };
        let res = if self.video.width > 0 { format!(",RESOLUTION={}x{}", self.video.width, self.video.height) } else { String::new() };
        out.push_str(&format!(
            "#EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS=\"{}{}\"{}{}\nindex.m3u8\n",
            codecs.0,
            audio,
            res,
            if self.subs.is_empty() { "" } else { ",SUBTITLES=\"subs\"" }
        ));
        out
    }

    pub fn sub_playlist(&self, track: usize) -> Option<String> {
        if track >= self.subs.len() {
            return None;
        }
        let durations: Vec<f64> = self.segments.iter().map(|s| self.secs(s.end.saturating_sub(s.start))).collect();
        let target = durations.iter().cloned().fold(1.0f64, f64::max).ceil() as u64;
        let mut out = format!("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:{target}\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n");
        for (i, d) in durations.iter().enumerate() {
            out.push_str(&format!("#EXTINF:{:.3},\nsub{track}_{i}.vtt\n", d.max(0.001)));
        }
        out.push_str("#EXT-X-ENDLIST\n");
        Some(out)
    }

    pub fn playlist(&self) -> String {
        let durations: Vec<f64> = self.segments.iter().map(|s| self.secs(s.end.saturating_sub(s.start))).collect();
        let target = durations.iter().cloned().fold(1.0f64, f64::max).ceil() as u64;
        let mut out = format!(
            "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:{target}\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        );
        for (i, d) in durations.iter().enumerate() {
            out.push_str(&format!("#EXTINF:{:.3},\n{i}.m4s\n", d.max(0.001)));
        }
        out.push_str("#EXT-X-ENDLIST\n");
        out
    }

    async fn read_frames(&self, n: usize) -> Result<Vec<Frame>, RemuxError> {
        let seg = self.segments.get(n).ok_or_else(|| e("no such segment"))?;
        let buf = self.source.read(seg.from, seg.to).await?;
        let mut wanted = vec![self.video.number];
        wanted.extend(self.subs.iter().map(|t| t.number));
        if let Some((a, _)) = &self.audio {
            wanted.push(a.number);
        } else if let Some(a) = self.header.tracks.iter().find(|t| t.kind == 2 && t.enabled && t.default).or_else(|| self.header.tracks.iter().find(|t| t.kind == 2)) {
            wanted.push(a.number);
        }
        Ok(mkv::parse_clusters(&buf, &wanted))
    }

    fn build(&self, n: usize, frames: Vec<Frame>) -> Result<Built, RemuxError> {
        let media = self.build_media(n, &frames)?;
        let ts = self.header.timescale as i64;
        let to_ms = |t: i64| t * ts / 1_000_000;
        let subs = self
            .subs
            .iter()
            .map(|t| {
                frames
                    .iter()
                    .filter(|f| f.track == t.number)
                    .map(|f| {
                        let start = to_ms(f.pts);
                        let dur = f.duration.map(to_ms).filter(|d| *d > 0).or_else(|| {
                            (t.default_duration_ns > 0).then(|| (t.default_duration_ns / 1_000_000) as i64)
                        });
                        vtt::Cue { start_ms: start, end_ms: start + dur.unwrap_or(3000), text: vtt::cue_text(t, &f.data) }
                    })
                    .collect()
            })
            .collect();
        Ok(Built { media: Arc::new(media), subs })
    }

    fn build_media(&self, n: usize, frames: &[Frame]) -> Result<Vec<u8>, RemuxError> {
        let ts = self.header.timescale;
        // video: from the first keyframe, in storage (decode) order
        let vframes: Vec<&Frame> = frames
            .iter()
            .filter(|f| f.track == self.video.number)
            .skip_while(|f| !f.key)
            .collect();
        if vframes.is_empty() {
            return Err(e(format!("segment {n}: no video")));
        }
        let pts: Vec<i64> = vframes.iter().map(|f| to_ticks(f.pts, ts, mp4::VIDEO_TIMESCALE as u64).max(0)).collect();
        let mut dts = pts.clone();
        dts.sort_unstable();
        let default_dur = if self.video.default_duration_ns > 0 {
            (self.video.default_duration_ns as u128 * mp4::VIDEO_TIMESCALE as u128 / 1_000_000_000) as i64
        } else {
            0
        };
        let next_start = self
            .segments
            .get(n + 1)
            .map(|s| to_ticks(s.start as i64, ts, mp4::VIDEO_TIMESCALE as u64));
        let mut vsamples = Vec::with_capacity(vframes.len());
        for (i, f) in vframes.iter().enumerate() {
            let dur = if i + 1 < dts.len() {
                dts[i + 1] - dts[i]
            } else if let Some(ns) = next_start.filter(|ns| *ns > dts[i]) {
                (ns - dts[i]).min(if default_dur > 0 { default_dur * 4 } else { 15_000 })
            } else if default_dur > 0 {
                default_dur
            } else if i > 0 {
                dts[i] - dts[i - 1]
            } else {
                3754
            };
            vsamples.push(mp4::Sample { data: &f.data, duration: dur.max(1) as u32, cto: (pts[i] - dts[i]) as i32, key: f.key });
        }
        let mut runs = vec![mp4::TrackRun { id: mp4::VIDEO_ID, base_time: dts[0].max(0) as u64, samples: vsamples, video: true }];

        if let Some((at, out)) = &self.audio {
            let aframes: Vec<&Frame> = frames.iter().filter(|f| f.track == at.number).collect();
            if let Some(first) = aframes.first() {
                let base = to_ticks(first.pts, ts, out.rate as u64).max(0) as u64;
                let samples = aframes
                    .iter()
                    .map(|f| mp4::Sample { data: &f.data, duration: codec::frame_samples(out, &f.data), cto: 0, key: true })
                    .collect();
                runs.push(mp4::TrackRun { id: mp4::AUDIO_ID, base_time: base, samples, video: false });
            }
        }
        Ok(mp4::fragment(n as u32 + 1, &runs))
    }

    async fn segment(self: &Arc<Self>, n: usize) -> Result<Arc<Built>, RemuxError> {
        if n >= self.segments.len() {
            return Err(e("no such segment"));
        }
        let cell = {
            let mut cache = self.cache.lock().unwrap();
            // keep a small window around what's playing
            cache.retain(|k, _| *k + 4 >= n && *k <= n + 6);
            cache.entry(n).or_insert_with(|| Arc::new(OnceCell::new())).clone()
        };
        let me = self.clone();
        let out = cell
            .get_or_try_init(|| async move {
                let frames = me.read_frames(n).await?;
                me.build(n, frames).map(Arc::new)
            })
            .await?
            .clone();
        // read ahead the next two
        for k in [n + 1, n + 2] {
            if k < self.segments.len() {
                let me = self.clone();
                tokio::spawn(async move {
                    let _ = me.segment_no_prefetch(k).await;
                });
            }
        }
        Ok(out)
    }

    async fn segment_no_prefetch(self: &Arc<Self>, n: usize) -> Result<Arc<Built>, RemuxError> {
        let cell = {
            let mut cache = self.cache.lock().unwrap();
            cache.entry(n).or_insert_with(|| Arc::new(OnceCell::new())).clone()
        };
        let me = self.clone();
        Ok(cell
            .get_or_try_init(|| async move {
                let frames = me.read_frames(n).await?;
                me.build(n, frames).map(Arc::new)
            })
            .await?
            .clone())
    }
}

/// reads one whole element at `pos` (header first, then its full size)
async fn read_element(source: &Source, pos: u64, len: u64, max: u64) -> Result<Vec<u8>, RemuxError> {
    let head = source.read(pos, (pos + 64 * 1024).min(len)).await?;
    let el = ebml::read_element(&head, 0).ok_or_else(|| e("bad element"))?;
    if el.size == ebml::UNKNOWN {
        return Err(e("element of unknown size"));
    }
    let total = el.data as u64 + el.size;
    if total > max {
        return Err(e("element too big"));
    }
    if total <= head.len() as u64 {
        return Ok(head[..total as usize].to_vec());
    }
    source.read(pos, (pos + total).min(len)).await
}

/// Segments of ~5 s starting on keyframes listed in the Cues
fn plan_segments(cues: &[Cue], timescale: u64, first_cluster: u64, clusters_end: u64, duration_ts: u64) -> Vec<Segment> {
    let target = TARGET_NS / timescale.max(1);
    let mut starts: Vec<&Cue> = vec![&cues[0]];
    for c in &cues[1..] {
        let last = starts.last().unwrap();
        if c.time >= last.time + target && c.cluster > last.cluster {
            starts.push(c);
        }
    }
    // a tiny last piece joins the one before it
    if starts.len() > 1 && duration_ts.saturating_sub(starts.last().unwrap().time) < target / 3 {
        starts.pop();
    }
    let mut out = Vec::with_capacity(starts.len());
    for (i, c) in starts.iter().enumerate() {
        let (end, to) = match starts.get(i + 1) {
            Some(n) => (n.time, n.cluster),
            None => (duration_ts.max(c.time + 1), clusters_end),
        };
        out.push(Segment {
            start: if i == 0 { 0 } else { c.time },
            end,
            from: if i == 0 { first_cluster } else { c.cluster },
            to,
        });
    }
    out
}

// MARK: - local server

struct Server {
    port: u16,
    sessions: Mutex<Vec<(String, Arc<Session>)>>,
    next: Mutex<u64>,
}

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("qb-remux")
            .enable_all()
            .build()
            .expect("remux runtime")
    })
}

static SERVER: OnceCell<Arc<Server>> = OnceCell::const_new();

async fn server() -> Result<Arc<Server>, RemuxError> {
    SERVER
        .get_or_try_init(|| async {
            let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|x| e(x.to_string()))?;
            let port = listener.local_addr().map_err(|x| e(x.to_string()))?.port();
            let srv = Arc::new(Server { port, sessions: Mutex::new(vec![]), next: Mutex::new(1) });
            let s2 = srv.clone();
            tokio::spawn(async move {
                loop {
                    let Ok((sock, _)) = listener.accept().await else {
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        continue;
                    };
                    let srv = s2.clone();
                    tokio::spawn(async move {
                        let _ = serve(sock, srv).await;
                    });
                }
            });
            Ok(srv)
        })
        .await
        .cloned()
}

async fn serve(mut sock: TcpStream, srv: Arc<Server>) -> std::io::Result<()> {
    let _ = sock.set_nodelay(true);
    let mut buf = Vec::with_capacity(4096);
    loop {
        // one request head
        let head_end = loop {
            if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                break p + 4;
            }
            if buf.len() > 32 * 1024 {
                return Ok(());
            }
            let mut chunk = [0u8; 4096];
            let n = sock.read(&mut chunk).await?;
            if n == 0 {
                return Ok(());
            }
            buf.extend_from_slice(&chunk[..n]);
        };
        let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
        buf.drain(..head_end);
        let mut lines = head.split("\r\n");
        let request = lines.next().unwrap_or_default();
        let mut parts = request.split(' ');
        let method = parts.next().unwrap_or_default().to_string();
        let path = parts.next().unwrap_or_default().to_string();
        let mut range: Option<(u64, Option<u64>)> = None;
        let mut close = false;
        for l in lines {
            let lower = l.to_ascii_lowercase();
            if let Some(v) = lower.strip_prefix("range:") {
                if let Some(r) = v.trim().strip_prefix("bytes=") {
                    let mut it = r.split('-');
                    let a = it.next().and_then(|x| x.trim().parse().ok());
                    let b = it.next().and_then(|x| x.trim().parse().ok());
                    if let Some(a) = a {
                        range = Some((a, b));
                    }
                }
            } else if lower.starts_with("connection:") && lower.contains("close") {
                close = true;
            }
        }

        let (status, ctype, body) = route(&srv, &path).await;
        let body = body.unwrap_or_else(|| Arc::new(Vec::new()));
        let total = body.len() as u64;
        let (code, from, to) = match (status, range) {
            (200, Some((a, b))) if a < total => (206, a, b.map(|b| b.min(total - 1)).unwrap_or(total - 1) + 1),
            (200, Some(_)) if total > 0 => (416, 0, 0),
            (s, _) => (s, 0, total),
        };
        let reason = match code {
            200 => "OK",
            206 => "Partial Content",
            404 => "Not Found",
            416 => "Range Not Satisfiable",
            _ => "Bad Gateway",
        };
        let mut resp = format!(
            "HTTP/1.1 {code} {reason}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: {}\r\n",
            to - from,
            if close { "close" } else { "keep-alive" }
        );
        if code == 206 {
            resp.push_str(&format!("Content-Range: bytes {}-{}/{}\r\n", from, to - 1, total));
        }
        resp.push_str("\r\n");
        sock.write_all(resp.as_bytes()).await?;
        if method != "HEAD" && to > from {
            sock.write_all(&body[from as usize..to as usize]).await?;
        }
        sock.flush().await?;
        if close {
            return Ok(());
        }
    }
}

async fn route(srv: &Arc<Server>, path: &str) -> (u16, &'static str, Option<Arc<Vec<u8>>>) {
    let path = path.split('?').next().unwrap_or_default();
    let mut parts = path.trim_start_matches('/').splitn(2, '/');
    let id = parts.next().unwrap_or_default();
    let file = parts.next().unwrap_or_default();
    let session = srv.sessions.lock().unwrap().iter().find(|(k, _)| k == id).map(|(_, s)| s.clone());
    let Some(s) = session else { return (404, "text/plain", None) };
    if file == "master.m3u8" {
        return (200, "application/vnd.apple.mpegurl", Some(Arc::new(s.master().into_bytes())));
    }
    if let Some(t) = file.strip_prefix("sub").and_then(|r| r.strip_suffix(".m3u8")).and_then(|t| t.parse::<usize>().ok()) {
        return match s.sub_playlist(t) {
            Some(p) => (200, "application/vnd.apple.mpegurl", Some(Arc::new(p.into_bytes()))),
            None => (404, "text/plain", None),
        };
    }
    if let Some((t, n)) = file
        .strip_prefix("sub")
        .and_then(|r| r.strip_suffix(".vtt"))
        .and_then(|r| r.split_once('_'))
        .and_then(|(t, n)| Some((t.parse::<usize>().ok()?, n.parse::<usize>().ok()?)))
    {
        if t >= s.subs.len() {
            return (404, "text/plain", None);
        }
        return match s.segment_no_prefetch(n).await {
            Ok(b) => (200, "text/vtt", Some(Arc::new(vtt::segment(&b.subs[t]).into_bytes()))),
            Err(x) => {
                tracing::warn!("remux subs {n}: {x}");
                (502, "text/plain", None)
            }
        };
    }
    if file == "index.m3u8" {
        return (200, "application/vnd.apple.mpegurl", Some(Arc::new(s.playlist().into_bytes())));
    }
    if file == "init.mp4" {
        return (200, "video/mp4", Some(Arc::new(s.init.clone())));
    }
    if let Some(n) = file.strip_suffix(".m4s").and_then(|n| n.parse::<usize>().ok()) {
        return match s.segment(n).await {
            Ok(b) => (200, "video/iso.segment", Some(b.media.clone())),
            Err(x) => {
                tracing::warn!("remux segment {n}: {x}");
                (502, "text/plain", None)
            }
        };
    }
    (404, "text/plain", None)
}

// MARK: - API

#[derive(Debug, Clone)]
pub struct Opened {
    pub playlist_url: String,
    pub info: Info,
}

async fn open_source(source: Source) -> Result<Opened, RemuxError> {
    let srv = server().await?;
    let session = Arc::new(Session::open(source).await?);
    let id = {
        let mut n = srv.next.lock().unwrap();
        *n += 1;
        format!("s{}", *n)
    };
    let info = session.info();
    {
        let mut list = srv.sessions.lock().unwrap();
        list.push((id.clone(), session));
        // only the two newest stay (the one playing + the one before, while switching)
        while list.len() > 2 {
            list.remove(0);
        }
    }
    Ok(Opened { playlist_url: format!("http://127.0.0.1:{}/{}/master.m3u8", srv.port, id), info })
}

/// Opens a remote MKV and returns a local HLS playlist URL for AVPlayer.
/// Errors mean "not remuxable" (codec, no index, no range support ...): play it with VLC.
pub async fn open_url(url: String, headers: HashMap<String, String>) -> Result<Opened, RemuxError> {
    runtime()
        .spawn(async move {
            let mut map = reqwest::header::HeaderMap::new();
            for (k, v) in headers {
                if let (Ok(k), Ok(v)) = (
                    reqwest::header::HeaderName::from_bytes(k.as_bytes()),
                    reqwest::header::HeaderValue::from_str(&v),
                ) {
                    map.insert(k, v);
                }
            }
            let client = reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(15))
                .timeout(Duration::from_secs(90))
                .build()
                .map_err(|x| e(x.to_string()))?;
            let fut = open_source(Source::Http { client, url, headers: map });
            tokio::time::timeout(Duration::from_secs(25), fut).await.map_err(|_| e("timed out reading the file index"))?
        })
        .await
        .map_err(|x| e(x.to_string()))?
}

/// Local file (tests)
pub async fn open_file(path: PathBuf) -> Result<Opened, RemuxError> {
    runtime().spawn(open_source(Source::File(path))).await.map_err(|x| e(x.to_string()))?
}

/// Drops a session (the player closed or moved on)
pub fn close(playlist_url: &str) {
    let Some(srv) = SERVER.get() else { return };
    let id = playlist_url.rsplit('/').nth(1).unwrap_or_default().to_string();
    srv.sessions.lock().unwrap().retain(|(k, _)| *k != id);
}
