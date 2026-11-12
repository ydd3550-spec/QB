//! cargo run -p qb-remux --example serve -- file.mkv|URL   -> prints the playlist URL, serves until killed
use std::collections::HashMap;

#[tokio::main]
async fn main() {
    let arg = std::env::args().nth(1).expect("path or url");
    let r = if arg.starts_with("http") {
        qb_remux::open_url(arg, HashMap::new()).await
    } else {
        qb_remux::open_file(arg.into()).await
    };
    match r {
        Ok(o) => {
            println!("{}", o.playlist_url);
            println!("{:?}", o.info);
            use std::io::Write;
            std::io::stdout().flush().unwrap();
            tokio::time::sleep(std::time::Duration::from_secs(600)).await;
        }
        Err(e) => {
            println!("ERR {e}");
            std::process::exit(2);
        }
    }
}
