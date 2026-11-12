//! What AVPlayer can take as-is, and the codec configuration boxes it needs.

use crate::mkv::Track;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum VideoCodec {
    Avc,
    Hevc,
}

impl VideoCodec {
    pub fn from_track(t: &Track) -> Result<Self, String> {
        match t.codec_id.as_str() {
            "V_MPEG4/ISO/AVC" if !t.private.is_empty() => Ok(VideoCodec::Avc),
            "V_MPEGH/ISO/HEVC" if !t.private.is_empty() => Ok(VideoCodec::Hevc),
            other => Err(format!("video codec {other}")),
        }
    }
    pub fn name(&self) -> &'static str {
        match self {
            VideoCodec::Avc => "H.264",
            VideoCodec::Hevc => "HEVC",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum AudioCodec {
    /// AudioSpecificConfig
    Aac(Vec<u8>),
    /// dac3 payload (3 bytes)
    Ac3([u8; 3]),
    /// dec3 payload
    Eac3(Vec<u8>),
    Mp3,
}

/// Audio as it goes into the MP4
#[derive(Debug, Clone, PartialEq)]
pub struct AudioOut {
    pub codec: AudioCodec,
    pub rate: u32,
    pub channels: u32,
    /// samples per frame (0 = per frame, E-AC-3)
    pub frame_samples: u32,
}

impl AudioOut {
    pub fn name(&self) -> &'static str {
        match self.codec {
            AudioCodec::Aac(_) => "AAC",
            AudioCodec::Ac3(_) => "AC-3",
            AudioCodec::Eac3(_) => "E-AC-3",
            AudioCodec::Mp3 => "MP3",
        }
    }
}

/// Can this audio track be passed through? (needs its first frame for AC-3 / E-AC-3 / MP3)
pub fn audio_supported(t: &Track) -> Result<(), String> {
    let id = t.codec_id.as_str();
    if id.starts_with("A_AAC") || id == "A_AC3" || id == "A_EAC3" || id == "A_MPEG/L3" {
        Ok(())
    } else {
        Err(format!("audio codec {id}"))
    }
}

const AAC_RATES: [u32; 13] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

pub fn audio_out(t: &Track, first_frame: &[u8]) -> Result<AudioOut, String> {
    let id = t.codec_id.as_str();
    let rate = t.rate.round() as u32;
    if id.starts_with("A_AAC") {
        let asc = if id == "A_AAC" && t.private.len() >= 2 {
            t.private.clone()
        } else {
            // legacy IDs (A_AAC/MPEG4/LC ...): build the AudioSpecificConfig
            let aot: u8 = if id.ends_with("/MAIN") { 1 } else if id.ends_with("/SSR") { 3 } else if id.ends_with("/LTP") { 4 } else { 2 };
            let idx = AAC_RATES.iter().position(|r| *r == rate).ok_or("aac rate")? as u8;
            let ch = t.channels.min(7) as u8;
            vec![(aot << 3) | (idx >> 1), ((idx & 1) << 7) | (ch << 3)]
        };
        // timescale = the AAC core rate written in the config
        let core = asc_rate(&asc).unwrap_or(rate);
        return Ok(AudioOut { codec: AudioCodec::Aac(asc), rate: core, channels: t.channels, frame_samples: 1024 });
    }
    match id {
        "A_AC3" => {
            let (dac3, rate) = ac3_config(first_frame).ok_or("ac3 header")?;
            Ok(AudioOut { codec: AudioCodec::Ac3(dac3), rate, channels: t.channels, frame_samples: 1536 })
        }
        "A_EAC3" => {
            let (dec3, rate) = eac3_config(first_frame)?;
            Ok(AudioOut { codec: AudioCodec::Eac3(dec3), rate, channels: t.channels, frame_samples: 0 })
        }
        "A_MPEG/L3" => {
            if first_frame.len() < 4 || first_frame[0] != 0xFF || first_frame[1] & 0xE0 != 0xE0 {
                return Err("mp3 header".into());
            }
            let mpeg1 = (first_frame[1] >> 3) & 3 == 3;
            Ok(AudioOut { codec: AudioCodec::Mp3, rate, channels: t.channels, frame_samples: if mpeg1 { 1152 } else { 576 } })
        }
        other => Err(format!("audio codec {other}")),
    }
}

fn asc_rate(asc: &[u8]) -> Option<u32> {
    if asc.len() < 2 {
        return None;
    }
    let idx = ((asc[0] & 7) << 1) | (asc[1] >> 7);
    if idx == 15 {
        if asc.len() < 5 {
            return None;
        }
        let v = ((asc[1] as u32 & 0x7F) << 17) | ((asc[2] as u32) << 9) | ((asc[3] as u32) << 1) | (asc[4] as u32 >> 7);
        return Some(v);
    }
    AAC_RATES.get(idx as usize).copied()
}

struct Bits<'a> {
    b: &'a [u8],
    pos: usize,
}

impl Bits<'_> {
    fn get(&mut self, n: usize) -> Option<u32> {
        let mut v = 0u32;
        for _ in 0..n {
            let byte = *self.b.get(self.pos / 8)?;
            v = (v << 1) | ((byte >> (7 - self.pos % 8)) & 1) as u32;
            self.pos += 1;
        }
        Some(v)
    }
}

struct BitW {
    out: Vec<u8>,
    n: usize,
}

impl BitW {
    fn put(&mut self, bits: usize, v: u32) {
        for i in (0..bits).rev() {
            if self.n % 8 == 0 {
                self.out.push(0);
            }
            let bit = ((v >> i) & 1) as u8;
            let last = self.out.len() - 1;
            self.out[last] |= bit << (7 - self.n % 8);
            self.n += 1;
        }
    }
}

fn ac3_config(f: &[u8]) -> Option<([u8; 3], u32)> {
    if f.len() < 8 || f[0] != 0x0B || f[1] != 0x77 {
        return None;
    }
    let mut r = Bits { b: f, pos: 32 };
    let fscod = r.get(2)?;
    let frmsizecod = r.get(6)?;
    let bsid = r.get(5)?;
    let bsmod = r.get(3)?;
    let acmod = r.get(3)?;
    if (acmod & 1) != 0 && acmod != 1 {
        r.get(2)?;
    }
    if acmod & 4 != 0 {
        r.get(2)?;
    }
    if acmod == 2 {
        r.get(2)?;
    }
    let lfeon = r.get(1)?;
    let rate = [48000, 44100, 32000].get(fscod as usize).copied()?;
    let mut w = BitW { out: vec![], n: 0 };
    w.put(2, fscod);
    w.put(5, bsid);
    w.put(3, bsmod);
    w.put(3, acmod);
    w.put(1, lfeon);
    w.put(5, frmsizecod >> 1);
    w.put(5, 0);
    Some(([w.out[0], w.out[1], w.out[2]], rate))
}

/// One E-AC-3 syncframe header
struct Eac3Frame {
    strmtyp: u32,
    substream: u32,
    size: usize,
    fscod: u32,
    rate: u32,
    blocks: u32,
    acmod: u32,
    lfeon: u32,
    bsid: u32,
}

fn eac3_frame(f: &[u8]) -> Option<Eac3Frame> {
    if f.len() < 6 || f[0] != 0x0B || f[1] != 0x77 {
        return None;
    }
    let mut r = Bits { b: f, pos: 16 };
    let strmtyp = r.get(2)?;
    let substream = r.get(3)?;
    let frmsiz = r.get(11)?;
    let fscod = r.get(2)?;
    let (rate, blocks) = if fscod == 3 {
        let fscod2 = r.get(2)?;
        ([24000, 22050, 16000].get(fscod2 as usize).copied()?, 6)
    } else {
        let numblkscod = r.get(2)?;
        ([48000, 44100, 32000][fscod as usize], [1, 2, 3, 6][numblkscod as usize])
    };
    let acmod = r.get(3)?;
    let lfeon = r.get(1)?;
    let bsid = r.get(5)?;
    Some(Eac3Frame { strmtyp, substream, size: (frmsiz as usize + 1) * 2, fscod, rate, blocks, acmod, lfeon, bsid })
}

fn eac3_config(block: &[u8]) -> Result<(Vec<u8>, u32), String> {
    let first = eac3_frame(block).ok_or("eac3 header")?;
    // dependent substreams (7.1) or several programs need a full dec3: leave those to VLC
    let mut p = 0;
    while p < block.len() {
        let Some(fr) = eac3_frame(&block[p..]) else { break };
        if fr.strmtyp == 1 || fr.substream != 0 {
            return Err("E-AC-3 with dependent substreams".into());
        }
        p += fr.size.max(2);
    }
    let kbps = (first.size as u64 * 8 * first.rate as u64 / (first.blocks as u64 * 256) / 1000) as u32;
    let fscod = if first.fscod == 3 { 3 } else { first.fscod };
    let mut w = BitW { out: vec![], n: 0 };
    w.put(13, kbps.min(8191));
    w.put(3, 0); // num_ind_sub - 1
    w.put(2, fscod);
    w.put(5, first.bsid);
    w.put(1, 0); // reserved
    w.put(1, 0); // asvc
    w.put(3, 0); // bsmod
    w.put(3, first.acmod);
    w.put(1, first.lfeon);
    w.put(3, 0); // reserved
    w.put(4, 0); // num_dep_sub
    w.put(1, 0); // reserved
    Ok((w.out, first.rate))
}

/// Audio samples in one stored frame (E-AC-3: sum of its independent syncframes)
pub fn frame_samples(out: &AudioOut, data: &[u8]) -> u32 {
    if out.frame_samples > 0 {
        return out.frame_samples;
    }
    let mut total = 0;
    let mut p = 0;
    while p < data.len() {
        let Some(fr) = eac3_frame(&data[p..]) else { break };
        if fr.strmtyp != 1 {
            total += fr.blocks * 256;
        }
        p += fr.size.max(2);
    }
    if total == 0 { 1536 } else { total }
}

/// RFC 6381 codec string from avcC / hvcC (AVPlayer checks it against what the device can decode)
pub fn video_codec_string(codec: VideoCodec, config: &[u8]) -> String {
    match codec {
        VideoCodec::Avc => {
            if config.len() >= 4 {
                format!("avc1.{:02X}{:02X}{:02X}", config[1], config[2], config[3])
            } else {
                "avc1.640028".into()
            }
        }
        VideoCodec::Hevc => {
            if config.len() < 13 {
                return "hvc1.1.6.L120.90".into();
            }
            let space = config[1] >> 6;
            let tier = (config[1] >> 5) & 1;
            let profile = config[1] & 0x1F;
            let compat = u32::from_be_bytes([config[2], config[3], config[4], config[5]]);
            let level = config[12];
            let space_s = match space {
                1 => "A",
                2 => "B",
                3 => "C",
                _ => "",
            };
            // compatibility flags are written bit-reversed, in hex without leading zeros
            let compat_s = format!("{:X}", compat.reverse_bits());
            let mut s = format!("hvc1.{space_s}{profile}.{compat_s}.{}{level}", if tier == 1 { "H" } else { "L" });
            // constraint bytes, trailing zero bytes dropped
            let mut cons: Vec<u8> = config[6..12].to_vec();
            while cons.last() == Some(&0) {
                cons.pop();
            }
            for b in cons {
                s.push_str(&format!(".{b:X}"));
            }
            s
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codec_strings() {
        assert_eq!(video_codec_string(VideoCodec::Avc, &[1, 0x64, 0x00, 0x28]), "avc1.640028");
        // Main profile, compat flags 0x60000000, level 120 (4.0), constraint 0x90
        let h = [1, 0x01, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 120];
        assert_eq!(video_codec_string(VideoCodec::Hevc, &h), "hvc1.1.6.L120.90");
    }

    #[test]
    fn asc_rates() {
        assert_eq!(asc_rate(&[0x12, 0x10]), Some(44100));
        assert_eq!(asc_rate(&[0x11, 0x90]), Some(48000));
    }
}
