//! cargo run -p qb-remux --example pgsdump -- file.mkv|URL track seconds...
//! Writes pgs_<s>.rgba (+ .txt with geometry) of what the app would draw over the native player.
use std::collections::HashMap;

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let src = &args[1];
    let track: usize = args[2].parse().unwrap();
    let o = if src.starts_with("http") {
        qb_remux::open_url(src.clone(), HashMap::new()).await
    } else {
        qb_remux::open_file(src.into()).await
    }
    .expect("open");
    println!("{:?}", o.info);
    qb_remux::pgs_select(&o.playlist_url, Some(track));
    for s in &args[3..] {
        let t: f64 = s.parse().unwrap();
        let ms = (t * 1000.0) as i64;
        // first call kicks off the read of that part of the file, like the app's poll does
        let mut f = None;
        for _ in 0..100 {
            f = qb_remux::pgs_at(&o.playlist_url, ms, -1);
            if f.is_some() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        match f {
            Some(f) => {
                println!("{t}: id={} canvas={}x{} at {},{} size {}x{} bytes={}", f.id, f.canvas_w, f.canvas_h, f.x, f.y, f.w, f.h, f.rgba.len());
                std::fs::write(format!("pgs_{s}.rgba"), &f.rgba).unwrap();
                std::fs::write(format!("pgs_{s}.txt"), format!("{} {} {} {} {} {}", f.canvas_w, f.canvas_h, f.x, f.y, f.w, f.h)).unwrap();
                // same subtitle again: no pixels resent
                let again = qb_remux::pgs_at(&o.playlist_url, ms, f.id).unwrap();
                assert!(again.rgba.is_empty() && again.id == f.id);
            }
            None => println!("{t}: nothing on screen"),
        }
    }
    qb_remux::close(&o.playlist_url);
}
