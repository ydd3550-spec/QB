//! Minimal EBML (Matroska) reader over an in-memory buffer.

/// Size value meaning "unknown size" (live / streamed Matroska)
pub const UNKNOWN: u64 = u64::MAX;

#[derive(Debug, Clone, Copy)]
pub struct Element {
    pub id: u32,
    /// offset of the element's data inside the buffer
    pub data: usize,
    /// data size (UNKNOWN when not known)
    pub size: u64,
    /// offset of the element header inside the buffer
    pub start: usize,
}

impl Element {
    /// end of the data inside a buffer of length `len` (clamped)
    pub fn end(&self, len: usize) -> usize {
        if self.size == UNKNOWN {
            len
        } else {
            (self.data as u64).saturating_add(self.size).min(len as u64) as usize
        }
    }
    pub fn complete(&self, len: usize) -> bool {
        self.size != UNKNOWN && (self.data as u64 + self.size) <= len as u64
    }
}

/// Element ID (keeps the length marker bits, like the spec's IDs: 0x1A45DFA3 ...)
pub fn read_id(b: &[u8], pos: usize) -> Option<(u32, usize)> {
    let first = *b.get(pos)?;
    let len = first.leading_zeros() as usize + 1;
    if len > 4 || pos + len > b.len() {
        return None;
    }
    let mut v: u32 = 0;
    for i in 0..len {
        v = (v << 8) | b[pos + i] as u32;
    }
    Some((v, len))
}

/// Data size vint (marker removed). All-ones = unknown.
pub fn read_size(b: &[u8], pos: usize) -> Option<(u64, usize)> {
    let first = *b.get(pos)?;
    if first == 0 {
        return None;
    }
    let len = first.leading_zeros() as usize + 1;
    if pos + len > b.len() {
        return None;
    }
    let mut v: u64 = (first as u64) & ((1u64 << (8 - len)) - 1);
    let mut all_ones = v == (1u64 << (8 - len)) - 1;
    for i in 1..len {
        let x = b[pos + i];
        if x != 0xFF {
            all_ones = false;
        }
        v = (v << 8) | x as u64;
    }
    if all_ones {
        return Some((UNKNOWN, len));
    }
    Some((v, len))
}

/// Signed-less vint used inside blocks (track number, EBML lacing sizes)
pub fn read_vint(b: &[u8], pos: usize) -> Option<(u64, usize)> {
    let first = *b.get(pos)?;
    if first == 0 {
        return None;
    }
    let len = first.leading_zeros() as usize + 1;
    if pos + len > b.len() {
        return None;
    }
    let mut v: u64 = (first as u64) & ((1u64 << (8 - len)) - 1);
    for i in 1..len {
        v = (v << 8) | b[pos + i] as u64;
    }
    Some((v, len))
}

pub fn read_element(b: &[u8], pos: usize) -> Option<Element> {
    let (id, il) = read_id(b, pos)?;
    let (size, sl) = read_size(b, pos + il)?;
    Some(Element { id, data: pos + il + sl, size, start: pos })
}

/// Children of [from, to)
pub fn children(b: &[u8], from: usize, to: usize) -> Vec<Element> {
    let mut out = Vec::new();
    let mut pos = from;
    let to = to.min(b.len());
    while pos < to {
        let Some(e) = read_element(b, pos) else { break };
        out.push(e);
        if e.size == UNKNOWN {
            break;
        }
        let next = e.data as u64 + e.size;
        if next > to as u64 {
            break;
        }
        pos = next as usize;
    }
    out
}

pub fn uint(b: &[u8], e: &Element) -> u64 {
    let end = e.end(b.len());
    b[e.data..end].iter().take(8).fold(0u64, |a, x| (a << 8) | *x as u64)
}

pub fn float(b: &[u8], e: &Element) -> f64 {
    let end = e.end(b.len());
    let s = &b[e.data..end];
    match s.len() {
        4 => f32::from_be_bytes([s[0], s[1], s[2], s[3]]) as f64,
        8 => f64::from_be_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]),
        _ => 0.0,
    }
}

pub fn string(b: &[u8], e: &Element) -> String {
    let end = e.end(b.len());
    String::from_utf8_lossy(&b[e.data..end]).trim_end_matches('\0').to_string()
}

pub fn bytes<'a>(b: &'a [u8], e: &Element) -> &'a [u8] {
    &b[e.data..e.end(b.len())]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn vints() {
        assert_eq!(read_size(&[0x81], 0), Some((1, 1)));
        assert_eq!(read_size(&[0x40, 0x02], 0), Some((2, 2)));
        assert_eq!(read_size(&[0xFF], 0), Some((UNKNOWN, 1)));
        assert_eq!(read_size(&[0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], 0), Some((UNKNOWN, 8)));
        assert_eq!(read_id(&[0x1A, 0x45, 0xDF, 0xA3], 0), Some((0x1A45DFA3, 4)));
    }
}
