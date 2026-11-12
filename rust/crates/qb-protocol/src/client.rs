//! الطلبات نفسها: كل دالة ترجع نتيجة إضافة وحدة، وخطأها ما يخرب الباقي.
use crate::*;
use qb_net::Client;

#[derive(Clone)]
pub struct AddonClient {
    pub net: Client,
}

impl AddonClient {
    pub fn new(net: Client) -> Self {
        AddonClient { net }
    }

    pub async fn fetch_manifest(&self, url: &str) -> Result<Manifest, CoreError> {
        let normalized = normalize_manifest_url(url)?;
        let v = self.net.get_json(&normalized).await?;
        parse_manifest(&v, &normalized)
    }

    pub async fn catalog(&self, m: &Manifest, kind: &str, catalog_id: &str, extra: &[(String, String)]) -> Result<Vec<MetaPreview>, CoreError> {
        let url = resource_url(&m.transport_url, "catalog", kind, catalog_id, extra);
        let v = self.net.get_json(&url).await?;
        Ok(parse_metas(&v, &m.name, MediaKind::parse(kind).unwrap_or(MediaKind::Movie)))
    }

    pub async fn meta(&self, m: &Manifest, kind: MediaKind, id: &str) -> Result<Option<MetaDetail>, CoreError> {
        let url = resource_url(&m.transport_url, "meta", kind.as_str(), id, &[]);
        let v = self.net.get_json(&url).await?;
        Ok(parse_meta_detail(&v, &m.name, kind))
    }

    pub async fn streams(&self, m: &Manifest, kind: MediaKind, id: &str) -> Result<Vec<RawStream>, CoreError> {
        let url = resource_url(&m.transport_url, "stream", kind.as_str(), id, &[]);
        let v = self.net.get_json(&url).await?;
        Ok(parse_streams(&v, &m.name))
    }

    pub async fn subtitles(&self, m: &Manifest, kind: MediaKind, id: &str) -> Result<Vec<SubtitleTrack>, CoreError> {
        let url = resource_url(&m.transport_url, "subtitles", kind.as_str(), id, &[]);
        let v = self.net.get_json(&url).await?;
        Ok(parse_subtitles(&v, &m.name))
    }
}
