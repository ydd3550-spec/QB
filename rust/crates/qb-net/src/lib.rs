//! عميل HTTP واحد: مهلات، إعادة محاولة، User-Agent.
use qb_model::CoreError;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, CONTENT_TYPE, RANGE};
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub const USER_AGENT: &str = "QB/1.0 (iOS; Stremio-compatible)";

/// الخطأ مع كل أسبابه (reqwest يخبّي السبب الحقيقي داخل source)
pub fn error_chain(e: &dyn std::error::Error) -> String {
    let mut s = e.to_string();
    let mut cur = e.source();
    while let Some(c) = cur {
        s.push_str(": ");
        s.push_str(&c.to_string());
        cur = c.source();
    }
    s
}

/// نص الـ panic لو كان نص
pub fn panic_text(p: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = p.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    retries: u32,
}

#[derive(Debug, Clone)]
pub struct ProbeResponse {
    pub status: u16,
    pub content_type: Option<String>,
    pub first_bytes: Vec<u8>,
    pub latency_ms: u32,
    pub final_url: String,
}

impl Client {
    /// يبني عميل HTTP. لو فشل الإعداد الكامل (مثلاً TLS على جهاز معيّن) يجرّب إعداد أبسط،
    /// ولو فشل الاثنين يرجّع الخطأين كاملين عشان يبانون في شاشة الخطأ.
    pub fn new() -> Result<Self, CoreError> {
        let full = std::panic::catch_unwind(|| {
            reqwest::Client::builder()
                .user_agent(USER_AGENT)
                .connect_timeout(Duration::from_secs(8))
                .timeout(Duration::from_secs(20))
                .pool_idle_timeout(Duration::from_secs(60))
                .build()
                .map_err(|e| error_chain(&e))
        })
        .unwrap_or_else(|p| Err(format!("panic: {}", panic_text(&*p))));
        let first = match full {
            Ok(http) => return Ok(Client { http, retries: 2 }),
            Err(e) => e,
        };
        tracing::warn!("http client (full) failed: {first}; trying minimal");
        let minimal = std::panic::catch_unwind(|| {
            reqwest::Client::builder()
                .user_agent(USER_AGENT)
                .http1_only()
                .timeout(Duration::from_secs(20))
                .build()
                .map_err(|e| error_chain(&e))
        })
        .unwrap_or_else(|p| Err(format!("panic: {}", panic_text(&*p))));
        match minimal {
            Ok(http) => Ok(Client { http, retries: 2 }),
            Err(second) => Err(CoreError::network(format!("http client: {first} | fallback: {second}"))),
        }
    }

    /// GET يرجّع JSON، مع محاولتين إضافيتين بتأخير متزايد لأخطاء الشبكة والـ 5xx
    pub async fn get_json(&self, url: &str) -> Result<serde_json::Value, CoreError> {
        let text = self.get_text(url).await?;
        serde_json::from_str(&text).map_err(|e| CoreError::addon(format!("bad json from {url}: {e}")))
    }

    pub async fn get_text(&self, url: &str) -> Result<String, CoreError> {
        let bytes = self.get_bytes(url).await?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    pub async fn get_bytes(&self, url: &str) -> Result<Vec<u8>, CoreError> {
        let mut attempt = 0u32;
        loop {
            let res = self.http.get(url).send().await;
            match res {
                Ok(r) if r.status().is_success() => {
                    return r.bytes().await.map(|b| b.to_vec()).map_err(CoreError::network);
                }
                Ok(r) if r.status().is_server_error() && attempt < self.retries => {}
                Ok(r) => return Err(CoreError::network(format!("HTTP {} for {url}", r.status().as_u16()))),
                Err(e) if attempt < self.retries && (e.is_timeout() || e.is_connect() || e.is_request()) => {}
                Err(e) => return Err(CoreError::network(e)),
            }
            attempt += 1;
            tokio::time::sleep(backoff(attempt)).await;
        }
    }

    /// HEAD بمهلة محددة
    pub async fn head(&self, url: &str, headers: &HashMap<String, String>, timeout: Duration) -> Result<ProbeResponse, CoreError> {
        let start = Instant::now();
        let r = self
            .http
            .head(url)
            .headers(header_map(headers))
            .timeout(timeout)
            .send()
            .await
            .map_err(CoreError::network)?;
        Ok(ProbeResponse {
            status: r.status().as_u16(),
            content_type: content_type(r.headers()),
            first_bytes: vec![],
            latency_ms: start.elapsed().as_millis().min(u32::MAX as u128) as u32,
            final_url: r.url().to_string(),
        })
    }

    /// GET مع Range: bytes=0-(n-1)، ويقرا أول n بايت بس
    pub async fn range_get(&self, url: &str, headers: &HashMap<String, String>, n: usize, timeout: Duration) -> Result<ProbeResponse, CoreError> {
        let start = Instant::now();
        let mut map = header_map(headers);
        if let Ok(v) = HeaderValue::from_str(&format!("bytes=0-{}", n.saturating_sub(1))) {
            map.insert(RANGE, v);
        }
        let mut r = self.http.get(url).headers(map).timeout(timeout).send().await.map_err(CoreError::network)?;
        let status = r.status().as_u16();
        let ct = content_type(r.headers());
        let final_url = r.url().to_string();
        let mut buf: Vec<u8> = Vec::with_capacity(n);
        while buf.len() < n {
            match r.chunk().await {
                Ok(Some(chunk)) => buf.extend_from_slice(&chunk),
                Ok(None) => break,
                Err(e) => {
                    if buf.is_empty() {
                        return Err(CoreError::network(e));
                    }
                    break;
                }
            }
        }
        buf.truncate(n);
        Ok(ProbeResponse {
            status,
            content_type: ct,
            first_bytes: buf,
            latency_ms: start.elapsed().as_millis().min(u32::MAX as u128) as u32,
            final_url,
        })
    }
}

pub fn backoff(attempt: u32) -> Duration {
    Duration::from_millis(300u64 * 2u64.pow(attempt.min(5)))
}

fn content_type(h: &HeaderMap) -> Option<String> {
    h.get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.split(';').next().unwrap_or(s).trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
}

fn header_map(headers: &HashMap<String, String>) -> HeaderMap {
    let mut map = HeaderMap::new();
    for (k, v) in headers {
        if let (Ok(name), Ok(value)) = (HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(v)) {
            map.insert(name, value);
        }
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows() {
        assert!(backoff(2) > backoff(1));
        assert_eq!(backoff(1), Duration::from_millis(600));
    }

    #[test]
    fn bad_headers_are_skipped() {
        let mut h = HashMap::new();
        h.insert("Referer".to_string(), "https://a.b".to_string());
        h.insert("bad header".to_string(), "x".to_string());
        let m = header_map(&h);
        assert_eq!(m.len(), 1);
    }
}
