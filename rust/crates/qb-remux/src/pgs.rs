//! PGS (Blu-ray image subtitles, Matroska `S_HDMV/PGS`) decoder.
//!
//! HLS has no image subtitles, so these are drawn by the app over the native player: the remuxer
//! keeps the raw display sets of the selected track while it builds segments, and `render` turns the
//! one showing at a given time into an RGBA bitmap placed on the subtitle canvas (= video frame).
//!
//! A Matroska block holds one display set: segments of `type(1) size(2) payload`, without the `PG`
//! magic / timestamps the .sup files carry.

use std::collections::HashMap;

const PDS: u8 = 0x14;
const ODS: u8 = 0x15;
const PCS: u8 = 0x16;

#[derive(Debug, Clone, PartialEq)]
pub struct Bitmap {
    /// subtitle canvas (normally the video size)
    pub canvas_w: u32,
    pub canvas_h: u32,
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    /// straight (non-premultiplied) RGBA, w*h*4
    pub rgba: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
struct CompObj {
    object: u16,
    x: u32,
    y: u32,
    crop: Option<(u32, u32, u32, u32)>,
}

#[derive(Debug, Clone)]
struct Pcs {
    w: u32,
    h: u32,
    state: u8,
    palette: u8,
    objects: Vec<CompObj>,
}

fn segments(block: &[u8]) -> Vec<(u8, &[u8])> {
    let mut out = vec![];
    let mut p = 0;
    // tolerate .sup style blocks ("PG" + pts + dts before each segment)
    while p + 3 <= block.len() {
        if block[p] == b'P' && block.get(p + 1) == Some(&b'G') && p + 13 <= block.len() {
            p += 10;
            continue;
        }
        let t = block[p];
        let n = u16::from_be_bytes([block[p + 1], block[p + 2]]) as usize;
        let end = (p + 3 + n).min(block.len());
        out.push((t, &block[p + 3..end]));
        p = p + 3 + n;
    }
    out
}

fn parse_pcs(d: &[u8]) -> Option<Pcs> {
    if d.len() < 11 {
        return None;
    }
    let w = u16::from_be_bytes([d[0], d[1]]) as u32;
    let h = u16::from_be_bytes([d[2], d[3]]) as u32;
    let state = d[7];
    let palette = d[9];
    let n = d[10] as usize;
    let mut objects = vec![];
    let mut p = 11;
    for _ in 0..n {
        if p + 8 > d.len() {
            break;
        }
        let object = u16::from_be_bytes([d[p], d[p + 1]]);
        let flags = d[p + 3];
        let x = u16::from_be_bytes([d[p + 4], d[p + 5]]) as u32;
        let y = u16::from_be_bytes([d[p + 6], d[p + 7]]) as u32;
        p += 8;
        let mut crop = None;
        if flags & 0x80 != 0 {
            if p + 8 > d.len() {
                break;
            }
            let r = |i: usize| u16::from_be_bytes([d[p + i], d[p + i + 1]]) as u32;
            crop = Some((r(0), r(2), r(4), r(6)));
            p += 8;
        }
        objects.push(CompObj { object, x, y, crop });
    }
    Some(Pcs { w, h, state, palette, objects })
}

/// is this display set the start of an epoch / acquisition point (decodable on its own)?
pub fn is_refresh(block: &[u8]) -> bool {
    segments(block).iter().any(|(t, d)| *t == PCS && parse_pcs(d).map(|p| p.state & 0xC0 != 0).unwrap_or(false))
}

/// does this display set clear the screen (composition without objects)?
pub fn is_clear(block: &[u8]) -> bool {
    segments(block).iter().any(|(t, d)| *t == PCS && parse_pcs(d).map(|p| p.objects.is_empty()).unwrap_or(false))
}

#[derive(Default)]
struct State {
    palettes: HashMap<u8, [[u8; 4]; 256]>,
    /// object id -> (width, height, rle data being collected)
    objects: HashMap<u16, (u32, u32, Vec<u8>)>,
    hd: bool,
}

impl State {
    fn feed(&mut self, block: &[u8]) -> Option<Pcs> {
        let mut pcs = None;
        for (t, d) in segments(block) {
            match t {
                PCS => {
                    let p = parse_pcs(d);
                    if let Some(p) = &p {
                        self.hd = p.h > 576;
                        if p.state & 0x80 != 0 {
                            // epoch start: everything before is gone
                            self.objects.clear();
                            self.palettes.clear();
                        }
                    }
                    pcs = p;
                }
                PDS if d.len() >= 2 => {
                    let id = d[0];
                    let pal = self.palettes.entry(id).or_insert([[0u8; 4]; 256]);
                    for e in d[2..].chunks_exact(5) {
                        pal[e[0] as usize] = ycbcr_to_rgba(e[1], e[3], e[2], e[4], self.hd);
                    }
                }
                ODS if d.len() >= 4 => {
                    let id = u16::from_be_bytes([d[0], d[1]]);
                    let seq = d[3];
                    if seq & 0x80 != 0 {
                        // first fragment: data length(3) width(2) height(2)
                        if d.len() < 11 {
                            continue;
                        }
                        let w = u16::from_be_bytes([d[7], d[8]]) as u32;
                        let h = u16::from_be_bytes([d[9], d[10]]) as u32;
                        self.objects.insert(id, (w, h, d[11..].to_vec()));
                    } else if let Some(o) = self.objects.get_mut(&id) {
                        o.2.extend_from_slice(&d[4..]);
                    }
                }
                _ => {}
            }
        }
        pcs
    }
}

/// limited-range YCbCr (BT.709 for HD, BT.601 for SD) to RGBA
fn ycbcr_to_rgba(y: u8, cb: u8, cr: u8, a: u8, hd: bool) -> [u8; 4] {
    let y = (y as f32 - 16.0) * 255.0 / 219.0;
    let cb = (cb as f32 - 128.0) * 255.0 / 224.0;
    let cr = (cr as f32 - 128.0) * 255.0 / 224.0;
    let (r, g, b) = if hd {
        (y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb)
    } else {
        (y + 1.402 * cr, y - 0.344_136 * cb - 0.714_136 * cr, y + 1.772 * cb)
    };
    let c = |v: f32| v.round().clamp(0.0, 255.0) as u8;
    [c(r), c(g), c(b), a]
}

/// PGS run-length decoding into palette indexes
fn decode_rle(data: &[u8], w: u32, h: u32) -> Vec<u8> {
    let (w, h) = (w as usize, h as usize);
    let mut out = vec![0u8; w * h];
    let (mut x, mut y, mut p) = (0usize, 0usize, 0usize);
    let mut put = |x: &mut usize, y: usize, n: usize, c: u8| {
        if y >= h {
            return;
        }
        let from = (*x).min(w);
        let to = (*x + n).min(w);
        out[y * w + from..y * w + to].fill(c);
        *x += n;
    };
    while p < data.len() && y < h {
        let b = data[p];
        p += 1;
        if b != 0 {
            put(&mut x, y, 1, b);
            continue;
        }
        let Some(&f) = data.get(p) else { break };
        p += 1;
        if f == 0 {
            x = 0;
            y += 1;
            continue;
        }
        let long = f & 0x40 != 0;
        let mut n = (f & 0x3F) as usize;
        if long {
            let Some(&l) = data.get(p) else { break };
            p += 1;
            n = (n << 8) | l as usize;
        }
        let color = if f & 0x80 != 0 {
            let Some(&c) = data.get(p) else { break };
            p += 1;
            c
        } else {
            0
        };
        put(&mut x, y, n, color);
    }
    out
}

/// Renders the display set `blocks.last()`, replaying `blocks` (from the last epoch start /
/// acquisition point up to it) for the palettes and objects it may reuse. None = nothing on screen.
pub fn render(blocks: &[&[u8]]) -> Option<Bitmap> {
    let mut st = State::default();
    let mut pcs = None;
    for b in blocks {
        pcs = st.feed(b);
    }
    let pcs = pcs?;
    if pcs.objects.is_empty() || pcs.w == 0 || pcs.h == 0 {
        return None;
    }
    let pal = st.palettes.get(&pcs.palette).copied().unwrap_or([[0u8; 4]; 256]);
    // each placed object: (x, y, w, h, indexes)
    let mut placed = vec![];
    for o in &pcs.objects {
        let Some((w, h, rle)) = st.objects.get(&o.object) else { continue };
        if *w == 0 || *h == 0 || *w > 8192 || *h > 8192 {
            continue;
        }
        let idx = decode_rle(rle, *w, *h);
        let (cx, cy, cw, ch) = o.crop.unwrap_or((0, 0, *w, *h));
        let cx = cx.min(*w);
        let cy = cy.min(*h);
        let cw = cw.min(*w - cx);
        let ch = ch.min(*h - cy);
        if cw == 0 || ch == 0 {
            continue;
        }
        let mut cut = Vec::with_capacity((cw * ch) as usize);
        for row in cy..cy + ch {
            let s = (row * *w + cx) as usize;
            cut.extend_from_slice(&idx[s..s + cw as usize]);
        }
        placed.push((o.x, o.y, cw, ch, cut));
    }
    if placed.is_empty() {
        return None;
    }
    let x0 = placed.iter().map(|p| p.0).min()?;
    let y0 = placed.iter().map(|p| p.1).min()?;
    let x1 = placed.iter().map(|p| p.0 + p.2).max()?;
    let y1 = placed.iter().map(|p| p.1 + p.3).max()?;
    let (bw, bh) = (x1 - x0, y1 - y0);
    let mut rgba = vec![0u8; (bw * bh * 4) as usize];
    let mut visible = false;
    for (x, y, w, h, idx) in &placed {
        for row in 0..*h {
            for col in 0..*w {
                let c = pal[idx[(row * w + col) as usize] as usize];
                if c[3] == 0 {
                    continue;
                }
                visible = true;
                let o = (((y - y0 + row) * bw + (x - x0 + col)) * 4) as usize;
                rgba[o..o + 4].copy_from_slice(&c);
            }
        }
    }
    if !visible {
        return None;
    }
    Some(Bitmap { canvas_w: pcs.w, canvas_h: pcs.h, x: x0, y: y0, w: bw, h: bh, rgba })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(t: u8, d: &[u8]) -> Vec<u8> {
        let mut v = vec![t];
        v.extend_from_slice(&(d.len() as u16).to_be_bytes());
        v.extend_from_slice(d);
        v
    }

    /// a 4x2 object: first row color 1, second row two pixels of color 2 then transparent
    fn display_set(state: u8, with_objects: bool) -> Vec<u8> {
        let mut pcs = vec![0x07, 0x80, 0x04, 0x38, 0x10, 0, 1, state, 0, 0, if with_objects { 1 } else { 0 }];
        if with_objects {
            pcs.extend_from_slice(&[0, 0, 0, 0, 0x01, 0x00, 0x03, 0x00]); // obj 0 at (256, 768)
        }
        let mut b = seg(PCS, &pcs);
        if state & 0x80 != 0 {
            // palette 0: index 1 = white opaque, 2 = black half transparent
            b.extend(seg(PDS, &[0, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 128]));
            let rle = [0u8, 0x84, 1, 0, 0, 0, 0x82, 2, 0, 0x02, 0, 0];
            let mut ods = vec![0, 0, 0, 0xC0];
            let len = (rle.len() + 4) as u32;
            ods.extend_from_slice(&len.to_be_bytes()[1..]);
            ods.extend_from_slice(&[0, 4, 0, 2]);
            ods.extend_from_slice(&rle);
            b.extend(seg(ODS, &ods));
        }
        b.extend(seg(0x80, &[]));
        b
    }

    #[test]
    fn renders_object_with_palette() {
        let ds = display_set(0x80, true);
        assert!(is_refresh(&ds));
        let bm = render(&[&ds]).unwrap();
        assert_eq!((bm.canvas_w, bm.canvas_h, bm.x, bm.y, bm.w, bm.h), (1920, 1080, 256, 768, 4, 2));
        assert_eq!(&bm.rgba[0..4], &[255, 255, 255, 255]);
        assert_eq!(&bm.rgba[12..16], &[255, 255, 255, 255]);
        assert_eq!(bm.rgba[16 + 3], 128); // second row, color 2
        assert_eq!(bm.rgba[16 + 8 + 3], 0); // transparent run
    }

    #[test]
    fn normal_case_reuses_objects_and_clear_hides() {
        let first = display_set(0x80, true);
        let again = display_set(0x00, true);
        assert!(!is_refresh(&again));
        assert!(render(&[&first, &again]).is_some());
        let clear = display_set(0x00, false);
        assert!(is_clear(&clear));
        assert!(render(&[&first, &clear]).is_none());
    }
}
