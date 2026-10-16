//! 黄果 AI 源（R1 规则化试点）：HTML 抓取 + HLS 直链取流。
//!
//! 基线入口 `https://huangguoai.ai/`（内容域名会轮转，入口页 `data-url`
//! 给出当前可用 host；实现见 [`content_base`] + 404 自愈）。
//!
//! 与红果轨的差异（有意为之）：
//! - 取流是 **HLS 直链**（`videoInitialData.epPlaySrcs`），`proxyUrl` 即远端
//!   m3u8（auth 已 baked 进 URL，无需 Referer，实测直取 200）。网关不做
//!   HLS 中转（无 playlist 改写能力），播放器侧 HLS+AES 由 media_kit 原生处理，
//!   故 `encrypted=false`、`quality=0`（单档，无 ladder 可换）。
//! - 取流结果**不做解析缓存**：每次 `play` 重新解析，保证 auth_key 新鲜。
//! - 目录/推荐/榜单走同卡片解析器（分类路由见 `CATEGORIES`）；联想暂不支持。
//!
//! 范围外（有意不做）：`huangguo.video` 子站被 Cloudflare 质询墙挡（纯 HTTP
//! 403），需 TLS 指纹伪装能力，列入 R2，不在本模块处理。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use regex::Regex;
use scraper::{Html, Selector};
use serde_json::{Value, json};

use crate::http;
use crate::source::traits::{Caps, SourceError, SourceProvider};

/// 源 id（与 guaapp 侧 `huangguoai` 同名，避免未来 `huangguo-video` 接入时撞名）。
pub const SOURCE_ID: &str = "huangguoai";

/// 入口页（只做路由发现，不做内容）。
const ENTRY_BASE: &str = "https://huangguoai.ai";

/// 封面代理签名用 referer（当前 [`crate::covers::proxy_url`] 忽略该参数，
/// 传入口根以备将来启用校验）。
const SITE_REFERER: &str = "https://huangguoai.ai/";

/// 内容 host 缓存有效期（域名轮转頻繁，过期即重新发现）。
const ROUTE_TTL: Duration = Duration::from_secs(30 * 60);

/// 入口页内容 host 提取：`data-url="https://..."`。
static RE_ROUTE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?i)data-url\s*=\s*["'](https?://[^"'\s>]+)"#).expect("checked regex")
});

/// 剧集链接：同站 `/video/{sid}/ep-{n}/`（详情页内含别剧推荐，必须按 sid 过滤）。
static RE_EPISODE_HREF: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^/video/([^/]+)/ep-(\d+)/?$").expect("checked regex"));

/// 末尾 `N集` 匹配（`parse_episode_count` 回退用；`全N集` 由专用模式优先处理）。
static RE_EPISODE_COUNT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(\d+)\s*集\s*$").expect("checked regex"));

/// `videoInitialData` 脚本块。
static RE_INITIAL_DATA: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?is)<script\b[^>]*\bid\s*=\s*["']videoInitialData["'][^>]*>(.*?)</script\s*>"#)
        .expect("checked regex")
});

/// `sr-only` 无障碍 span（标题/标签里的污染文本，提取时剔除）。
static RE_SR_ONLY: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?is)<span\b[^>]*\bsr-only\b[^>]*>.*?</span\s*>").expect("checked regex")
});

/// 通用标签剥离（在上一步之后跑，只剩纯文本标签）。
static RE_TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").expect("checked regex"));

/// 搜索卡片详情页 id：`/video/{digits}/`。
static RE_CARD_ID: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^/video/(\d+)/?$").expect("checked regex"));

/// 内容 host 缓存（entry 发现结果；404 自愈时清空）。
static CONTENT_BASE: Lazy<Mutex<(Option<String>, Instant)>> =
    Lazy::new(|| Mutex::new((None, Instant::now() - ROUTE_TTL - Duration::from_secs(1))));

/// 黄果 AI 源：入口发现 + HTML 抓取 + HLS 直链。
pub struct HuangguoProvider;

impl HuangguoProvider {
    pub fn new() -> Self {
        Self
    }
}

impl Default for HuangguoProvider {
    fn default() -> Self {
        Self::new()
    }
}

/// 入口页 HTML → 内容 host 列表（去重保序）。
fn discover_hosts(entry_html: &str) -> Vec<String> {
    let mut out = Vec::new();
    for cap in RE_ROUTE.captures_iter(entry_html) {
        let host = cap[1].trim_end_matches('/');
        if !out.iter().any(|h: &String| h == host) {
            out.push(host.to_owned());
        }
    }
    out
}

/// 当前内容根（缓存 30min； miss 即重新发现）。
fn content_base() -> Result<String, SourceError> {
    {
        let guard = CONTENT_BASE.lock().expect("huangguo route poisoned");
        if let (Some(base), at) = (guard.0.clone(), guard.1)
            && at.elapsed() < ROUTE_TTL
        {
            return Ok(base);
        }
    }
    let entry = fetch(ENTRY_BASE)?;
    let mut guard = CONTENT_BASE.lock().expect("huangguo route poisoned");
    let host = discover_hosts(&entry)
        .into_iter()
        .next()
        .ok_or_else(|| SourceError::Parse("huangguo entry has no content host".to_owned()))?;
    *guard = (Some(host.clone()), Instant::now());
    Ok(host)
}

/// 路由自愈：内容 host 失效（404）时清缓存，下次调用重新发现。
fn clear_content_base() {
    let mut guard = CONTENT_BASE.lock().expect("huangguo route poisoned");
    guard.0 = None;
}

/// 取文本；404 映射为 `NotFound`（详情/选集不存在时前端可区分展示，
/// 而不是当成可重试的传输错误）。
fn fetch(url: &str) -> Result<String, SourceError> {
    http::fetch_text_throttled(url).map_err(map_fetch_error)
}

/// fetch 错误映射（纯函数，便于单测）：仅 404 转 `NotFound`。
fn map_fetch_error(e: http::HttpError) -> SourceError {
    if e.status == Some(404) {
        SourceError::NotFound
    } else {
        SourceError::from(e)
    }
}

/// 带一次路由自愈的取文本（404 → 清 host 缓存 → 用新 host 重试一次）。
///
/// 入参是路径（`/search/...`）；返回实际生效的 base + 正文（自愈后 base
/// 可能已换，调用方拼后续 URL 必须用返回的 base，不能自己缓存）。
fn get(path: &str) -> Result<(String, String), SourceError> {
    let base = content_base()?;
    match fetch(&format!("{base}{path}")) {
        Err(SourceError::NotFound) => {
            clear_content_base();
            let base = content_base()?;
            fetch(&format!("{base}{path}")).map(|body| (base, body))
        }
        Ok(body) => Ok((base, body)),
        Err(e) => Err(e),
    }
}

/// 路径段 URL 编码（`@keyword` 替换用；空格走 `%20`，不是 `+`）。
fn urlencode_segment(raw: &str) -> String {
    const UNRESERVED: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~";
    let mut out = String::with_capacity(raw.len());
    for b in raw.as_bytes() {
        if UNRESERVED.contains(b) {
            out.push(*b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// HTML 片段 → 纯文本：先剔 `sr-only` 污染 span，再剥标签、压空白。
fn clean_text(fragment: &str) -> String {
    let no_sr = RE_SR_ONLY.replace_all(fragment, "");
    let no_tags = RE_TAG.replace_all(&no_sr, "");
    no_tags.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 集数 → 总集数：优先 `全34集` 形态，否则取最后一个 `N集`
/// （徽标 `更新至34集` 即末尾命中；简介里混有“第5集”之类时不受干扰）。
fn parse_episode_count(hint: &str) -> Option<i64> {
    static RE_TOTAL: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"全\s*(\d+)\s*集").expect("checked regex"));
    if let Some(count) = RE_TOTAL
        .captures(hint)
        .and_then(|c| c[1].parse::<i64>().ok())
    {
        return Some(count);
    }
    RE_EPISODE_COUNT
        .captures_iter(hint)
        .filter_map(|c| c[1].parse::<i64>().ok())
        .last()
}

/// 连载中判定：徽标/简介含“更新/连载”即连载，否则完结（与红果轨默认完结一致，
/// 未知不冒充连载）。
fn is_ongoing(hint: &str) -> bool {
    hint.contains("更新") || hint.contains("连载")
}

/// 详情标题：`h1` 优先；回退 `title` 标签去站点后缀。
fn detail_title(document: &Html) -> String {
    let h1 = Selector::parse("h1").expect("checked selector");
    if let Some(el) = document.select(&h1).next() {
        let title = clean_text(&el.inner_html());
        if !title.is_empty() {
            return title;
        }
    }
    let title_tag = Selector::parse("title").expect("checked selector");
    document
        .select(&title_tag)
        .next()
        .map(|el| {
            el.text()
                .collect::<String>()
                .split(['-', '|', '_'])
                .next()
                .unwrap_or("")
                .trim()
                .to_owned()
        })
        .unwrap_or_default()
}

/// meta content 提取（og:image / og:description）。
fn meta_content(document: &Html, property: &str) -> String {
    let selector =
        Selector::parse(&format!("meta[property=\"{property}\"]")).expect("checked selector");
    document
        .select(&selector)
        .next()
        .and_then(|el| el.value().attr("content"))
        .unwrap_or("")
        .trim()
        .to_owned()
}

/// 已知分类路由（实测存在；未知路由报 `NotFound` 而不拼出站请求，
/// 拼错的分类名是调用方 bug，早暴露比抓回 404 再转义更清楚）。
/// 缺省分类 → `ai-duanju`（与红果 `DEFAULT_CATEGORY_ROUTE` 同一思路）。
const CATEGORIES: &[&str] = &["ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai"];
const DEFAULT_CATEGORY: &str = "ai-duanju";

/// 分类路由归一化：空 → 默认；已知 → 原样；未知 → `None`（调用方转 `NotFound`）。
fn category_slug(category: Option<&str>) -> Option<&str> {
    match category.map(str::trim).filter(|c| !c.is_empty()) {
        None => Some(DEFAULT_CATEGORY),
        Some(c) if CATEGORIES.contains(&c) => Some(c),
        _ => None,
    }
}

/// 卡片六元组 → 契约 Drama（搜索与目录共用同一归一化口径）。
fn card_to_drama(
    id: String,
    title: String,
    cover: String,
    summary: String,
    tags: Vec<String>,
    badge: String,
) -> Value {
    let count = parse_episode_count(&badge).unwrap_or(0);
    json!({
        "id": id,
        "title": title,
        "cover": cover,
        "categoryId": "",
        "categoryName": "短剧",
        "episodeCount": count,
        "accessibleEpisodes": count,
        "summary": summary,
        "tags": tags,
        "status": if is_ongoing(&badge) { "ongoing" } else { "finished" },
        "vip": false,
    })
}

/// 列表页是否有下一页：`rel="next"` 链接存在即有（分类/推荐/榜单同规则）。
fn has_next_page(document: &Html) -> bool {
    static SEL_NEXT: Lazy<Selector> = Lazy::new(|| {
        Selector::parse("link[rel=\"next\"], a[rel=\"next\"]").expect("checked selector")
    });
    document.select(&SEL_NEXT).next().is_some()
}

/// 搜索卡片 → `(id, 标题, 封面, 简介, 标签, 集数徽标)`。
fn parse_search_cards(
    document: &Html,
) -> Vec<(String, String, String, String, Vec<String>, String)> {
    let card = Selector::parse("div.hg-drama-card").expect("checked selector");
    let link = Selector::parse("a[href]").expect("checked selector");
    let title_link =
        Selector::parse("div.hg-drama-card__title a, h3 a, h4 a").expect("checked selector");
    let img = Selector::parse("img").expect("checked selector");
    let desc = Selector::parse("p.hg-drama-card__desc").expect("checked selector");
    let tag = Selector::parse("a.hg-tag").expect("checked selector");
    let badge = Selector::parse("[data-ep-base]").expect("checked selector");
    let mut out = Vec::new();
    for card in document.select(&card) {
        let Some(href) = card
            .select(&link)
            .filter_map(|a| a.value().attr("href"))
            .find(|h| RE_CARD_ID.is_match(h))
        else {
            continue;
        };
        let id = RE_CARD_ID
            .captures(href)
            .map(|c| c[1].to_owned())
            .unwrap_or_default();
        if id.is_empty() {
            continue;
        }
        let title = card
            .select(&title_link)
            .next()
            .map(|a| clean_text(&a.inner_html()))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let cover = card
            .select(&img)
            .next()
            .map(|img| {
                let el = img.value();
                let data_src = el.attr("data-src").unwrap_or("").trim();
                let src = el.attr("src").unwrap_or("").trim();
                let picked = if !data_src.is_empty() { data_src } else { src };
                // 懒加载占位图无业务价值，直接置空走 Dart 占位。
                if picked.contains("cover-placeholder") {
                    String::new()
                } else {
                    picked.to_owned()
                }
            })
            .unwrap_or_default();
        let summary = card
            .select(&desc)
            .next()
            .map(|d| clean_text(&d.inner_html()))
            .unwrap_or_default();
        let tags: Vec<String> = card
            .select(&tag)
            .map(|t| clean_text(&t.inner_html()))
            .filter(|t| !t.is_empty())
            .collect();
        let badge = card
            .select(&badge)
            .next()
            .and_then(|b| b.value().attr("data-ep-base"))
            .unwrap_or("")
            .to_owned();
        out.push((id, title, cover, summary, tags, badge));
    }
    out
}

/// 详情页选集：同站 `/video/{sid}/ep-{n}/` 链接（别剧推荐链接一律过滤），按集号排序。
fn parse_episode_links(document: &Html, series_id: &str) -> Vec<(i64, String)> {
    let link = Selector::parse("a[href]").expect("checked selector");

    let mut episodes: Vec<(i64, String)> = document
        .select(&link)
        .filter_map(|a| a.value().attr("href"))
        .filter_map(|href| {
            let caps = RE_EPISODE_HREF.captures(href)?;
            if caps[1] != *series_id {
                return None;
            }
            let n: i64 = caps[2].parse().ok()?;
            (n > 0).then_some((n, href.to_owned()))
        })
        .collect();
    episodes.sort();
    episodes.dedup();
    episodes
}

/// 播放页 `videoInitialData` JSON → 指定集媒体地址（`epPlaySrcs[ep]` 优先，
/// `videoSrc` 兜底；`&amp;` 反转义；相对地址按页补全）。
fn parse_play_url(page_html: &str, page_url: &str, episode: i64) -> String {
    let raw = RE_INITIAL_DATA
        .captures(page_html)
        .map(|c| c[1].to_owned())
        .unwrap_or_default();
    if raw.trim().is_empty() {
        return String::new();
    }
    let Ok(data) = serde_json::from_str::<Value>(&raw) else {
        return String::new();
    };
    let key = episode.to_string();
    let mut candidates = Vec::new();
    if let Some(eps) = data.get("epPlaySrcs").and_then(Value::as_object)
        && let Some(url) = eps.get(&key).and_then(Value::as_str)
    {
        candidates.push(url.to_owned());
    }
    for fallback in ["videoSrc", "videoUrl", "playUrl"] {
        if let Some(url) = data.get(fallback).and_then(Value::as_str) {
            candidates.push(url.to_owned());
        }
    }
    candidates
        .into_iter()
        .map(|u| u.replace("&amp;", "&"))
        .filter_map(|u| join_url(page_url, &u))
        .find(|u| u.starts_with("http://") || u.starts_with("https://"))
        .unwrap_or_default()
}

/// 相对地址按页补全；绝对地址原样返回（非 http(s)  scheme 拒绝）。
fn join_url(page_url: &str, href: &str) -> Option<String> {
    let href = href.trim();
    if href.starts_with("http://") || href.starts_with("https://") {
        return Some(href.to_owned());
    }
    if href.starts_with("//") {
        return Some(format!("https:{href}"));
    }
    url::Url::parse(page_url)
        .and_then(|base| base.join(href))
        .map(|u| u.to_string())
        .ok()
        .filter(|u| u.starts_with("http://") || u.starts_with("https://"))
}

impl SourceProvider for HuangguoProvider {
    fn id(&self) -> &'static str {
        SOURCE_ID
    }

    fn caps(&self) -> Caps {
        Caps {
            catalog: true,
            search: true,
            suggest: false,
            recommend: true,
            ranking: true,
            detail: true,
            playback: true,
        }
    }

    fn catalog(&self, category: Option<&str>, page: u32) -> Result<Value, SourceError> {
        let Some(slug) = category_slug(category) else {
            return Err(SourceError::NotFound);
        };
        // 0 起页号 → 站内 1 起：0 页走裸 slug 地址，其余 `/{slug}/{N}/`。
        let path = if page == 0 {
            format!("/{slug}/")
        } else {
            format!("/{slug}/{}/", page + 1)
        };
        let (_, html) = get(&path)?;
        let document = Html::parse_document(&html);
        let items: Vec<Value> = parse_search_cards(&document)
            .into_iter()
            .map(|(id, title, cover, summary, tags, badge)| {
                card_to_drama(id, title, cover, summary, tags, badge)
            })
            .collect();
        let has_more = has_next_page(&document);
        Ok(crate::covers::proxy_covers(
            json!({ "items": items, "hasMore": has_more, "page": page }),
            SITE_REFERER,
        ))
    }

    fn recommend(&self) -> Result<Value, SourceError> {
        let (_, html) = get("/recommend")?;
        let document = Html::parse_document(&html);
        let items: Vec<Value> = parse_search_cards(&document)
            .into_iter()
            .map(|(id, title, cover, summary, tags, badge)| {
                card_to_drama(id, title, cover, summary, tags, badge)
            })
            .collect();
        Ok(crate::covers::proxy_covers(
            json!({ "items": items }),
            SITE_REFERER,
        ))
    }

    fn ranking(&self, _board: Option<&str>) -> Result<Value, SourceError> {
        // 单榜源：只有热榜。board 忽略（与红果未知板回退热榜同一降级哲学，
        // 只有一个榜可给时给榜不断流）。
        let (_, html) = get("/ranks/hot/")?;
        let document = Html::parse_document(&html);
        let items: Vec<Value> = parse_search_cards(&document)
            .into_iter()
            .map(|(id, title, cover, summary, tags, badge)| {
                card_to_drama(id, title, cover, summary, tags, badge)
            })
            .collect();
        Ok(crate::covers::proxy_covers(
            json!({ "items": items }),
            SITE_REFERER,
        ))
    }

    fn search(&self, keyword: &str) -> Result<Value, SourceError> {
        let (_, html) = get(&format!("/search/video/{}/", urlencode_segment(keyword)))?;
        let document = Html::parse_document(&html);
        let items: Vec<Value> = parse_search_cards(&document)
            .into_iter()
            .map(|(id, title, cover, summary, tags, badge)| {
                card_to_drama(id, title, cover, summary, tags, badge)
            })
            .collect();
        let total = items.len() as i64;
        Ok(crate::covers::proxy_covers(
            json!({ "items": items, "total": total }),
            SITE_REFERER,
        ))
    }

    fn suggest(&self, _keyword: &str) -> Result<Value, SourceError> {
        Err(SourceError::Unsupported)
    }

    fn detail(&self, series_id: &str) -> Result<Value, SourceError> {
        let (_, html) = get(&format!("/video/{series_id}/"))?;
        let document = Html::parse_document(&html);
        let title = detail_title(&document);
        if title.is_empty() {
            return Err(SourceError::Parse(
                "huangguo detail has no title".to_owned(),
            ));
        }
        let cover = meta_content(&document, "og:image");
        let summary = meta_content(&document, "og:description");
        let count = parse_episode_count(&summary).unwrap_or(0);
        let episodes: Vec<Value> = parse_episode_links(&document, series_id)
            .into_iter()
            .map(|(index, _)| {
                json!({
                    "index": index,
                    "vid": index.to_string(),
                    "title": format!("第 {index} 集"),
                    "locked": false,
                    "durationSeconds": 0,
                })
            })
            .collect();
        let episode_count = count.max(episodes.len() as i64);
        let drama = json!({
            "id": series_id,
            "title": title,
            "cover": cover,
            "categoryId": "",
            "categoryName": "短剧",
            "episodeCount": episode_count,
            "accessibleEpisodes": episode_count,
            "summary": summary,
            "tags": [],
            "status": if is_ongoing(&summary) { "ongoing" } else { "finished" },
            "vip": false,
        });
        Ok(crate::covers::proxy_covers(
            json!({ "drama": drama, "episodes": episodes }),
            SITE_REFERER,
        ))
    }

    fn play(
        &self,
        series_id: &str,
        episode: u32,
        vid: Option<String>,
        _quality: i64,
    ) -> Result<Value, SourceError> {
        // 单清晰度档：`quality` 偏好无 ladder 可换，直接取对应集直链。
        // 取流结果不做解析缓存：m3u8 的 `auth_key` 会过期，每次现解现用。
        let ep = vid
            .as_deref()
            .unwrap_or("")
            .parse::<i64>()
            .unwrap_or(episode.max(1) as i64)
            .max(1);
        let (base, html) = get(&format!("/video/{series_id}/ep-{ep}/"))?;
        let page_url = format!("{base}/video/{series_id}/ep-{ep}/");
        let media = parse_play_url(&html, &page_url, ep);
        if media.is_empty() {
            return Err(SourceError::Parse(
                "huangguo play has no playable url".to_owned(),
            ));
        }
        Ok(json!({
            "proxyUrl": media.clone(),
            "url": media.clone(),
            "vid": ep.to_string(),
            "encrypted": false,
            "quality": 0,
            "durationSecs": 0,
            "keyHex": "",
            "variants": [{ "url": media, "quality": 0 }],
            "qualityOptions": [],
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::HttpErrorKind;

    #[test]
    fn provider_id_and_caps() {
        let p = HuangguoProvider::new();
        assert_eq!(p.id(), "huangguoai");
        let caps = p.caps();
        assert!(caps.catalog && caps.search && caps.detail && caps.playback);
        assert!(caps.recommend && caps.ranking);
        assert!(!caps.suggest);
    }

    #[test]
    fn unsupported_ops_stay_unsupported() {
        let p = HuangguoProvider::new();
        assert!(matches!(p.suggest("x"), Err(SourceError::Unsupported)));
    }

    #[test]
    fn category_slug_maps_known_default_and_rejects_unknown() {
        assert_eq!(category_slug(None), Some(DEFAULT_CATEGORY));
        assert_eq!(category_slug(Some("")), Some(DEFAULT_CATEGORY));
        assert_eq!(category_slug(Some("ai-manju")), Some("ai-manju"));
        assert_eq!(category_slug(Some("nope")), None);
    }

    #[test]
    fn has_next_page_follows_rel_next() {
        let with_next = Html::parse_document(
            "<html><body><link rel=\"next\" href=\"/ai-duanju/2/\"></body></html>",
        );
        assert!(has_next_page(&with_next));
        let last = Html::parse_document("<html><body><div>末页</div></body></html>");
        assert!(!has_next_page(&last));
    }

    #[test]
    fn fetch_404_maps_to_not_found() {
        let not_found = map_fetch_error(crate::http::HttpError {
            kind: HttpErrorKind::Transport,
            status: Some(404),
            retryable: false,
            msg: "status 404".to_owned(),
        });
        assert!(matches!(not_found, SourceError::NotFound));
        let other = map_fetch_error(crate::http::HttpError {
            kind: HttpErrorKind::Transport,
            status: Some(500),
            retryable: true,
            msg: "status 500".to_owned(),
        });
        assert!(matches!(other, SourceError::Http(_)));
        assert!(other.retry());
    }

    #[test]
    fn discover_hosts_reads_data_url() {
        let html = r#"<html><body>
            <article data-url="https://a.example.cc"></article>
            <a href="https://old.example.com">旧域名</a>
            <div data-url='https://b.example.cc/'></div>
            <div data-url="https://a.example.cc"></div>
        </body></html>"#;
        assert_eq!(
            discover_hosts(html),
            vec!["https://a.example.cc", "https://b.example.cc"]
        );
        assert!(discover_hosts("<html></html>").is_empty());
    }

    #[test]
    fn urlencode_segment_encodes_path_segment() {
        assert_eq!(urlencode_segment("abc-1_~.x"), "abc-1_~.x");
        assert_eq!(urlencode_segment("替嫁"), "%E6%9B%BF%E5%AB%81");
        assert_eq!(urlencode_segment("a b"), "a%20b");
    }

    #[test]
    fn clean_text_drops_sr_only_spans() {
        assert_eq!(
            clean_text("弱点<span class=\"sr-only\">全集在线观看</span>"),
            "弱点"
        );
        assert_eq!(
            clean_text(
                "<a class=\"hg-tag\" href=\"/tag/x/\">现代<span class=\"sr-only\">题材</span></a>"
            ),
            "现代"
        );
    }

    const SEARCH_FIXTURE: &str = r#"<section><div class="hg-card-grid">
<div class="hg-drama-card">
  <div class="hg-drama-card__cover"><a class="hg-drama-card__cover-link" href="/video/2902/"><img src="/static/cover-placeholder.png" data-src="https://pic.example.cn/u/2902.jpg?auth_key=1-0-0-abc" alt="弱点"><span class="hg-drama-card__episode" data-ep-base="更新至34集">更新至34集</span></a></div>
  <div class="hg-drama-card__body"><div class="hg-drama-card__title"><a href="/video/2902/">弱点<span class="sr-only">全集在线观看</span></a></div>
  <p class="hg-drama-card__desc">律所逆袭。</p><div class="hg-drama-card__tags"><a class="hg-tag" href="/tag/x/">现代</a></div></div>
</div>
<div class="hg-drama-card">
  <div class="hg-drama-card__cover"><a class="hg-drama-card__cover-link" href="/video/17/"><img src="https://pic.example.cn/u/17.jpg" alt="短片"></a></div>
  <div class="hg-drama-card__body"><div class="hg-drama-card__title"><a href="/video/17/">短片</a></div></div>
</div>
<div class="hg-drama-card">
  <div class="hg-drama-card__body"><div class="hg-drama-card__title"><a href="/other/x/">无id卡</a></div></div>
</div>
</div></section>"#;

    #[test]
    fn search_cards_parse_and_skip_id_less() {
        let cards = parse_search_cards(&Html::parse_document(SEARCH_FIXTURE));
        assert_eq!(cards.len(), 2);
        let (id, title, cover, summary, tags, badge) = &cards[0];
        assert_eq!(id, "2902");
        assert_eq!(title, "弱点");
        assert!(cover.contains("2902.jpg"), "cover: {cover}");
        assert_eq!(summary, "律所逆袭。");
        assert_eq!(tags, &vec!["现代".to_owned()]);
        assert_eq!(parse_episode_count(badge), Some(34));
        assert!(is_ongoing(badge));
        // 无 data-src 回退 src；无徽标 → 集数未知、默认完结。
        let (_, _, cover2, _, _, badge2) = &cards[1];
        assert!(cover2.contains("17.jpg"));
        assert_eq!(parse_episode_count(badge2), None);
        assert!(!is_ongoing(badge2));
        // 简介混有单集表述时以“全N集”为准。
        assert_eq!(parse_episode_count("第5集开始反转，全34集。"), Some(34));
    }

    const DETAIL_FIXTURE: &str = r#"<html><head>
<title>弱点 - 短剧视频在线观看 | 黄果短剧</title>
<meta property="og:image" content="https://pic.example.cn/u/2902.jpg">
<meta property="og:description" content="弱点全34集，10月16日更新。简介。">
</head><body>
<h1 class="hg-web-play__title">弱点</h1>
<div class="hg-web-play__episode-scroll">
<a href="/video/2902/ep-2/">第2集</a><a href="/video/2902/ep-10/">第10集</a>
<a href="/video/2902/ep-1/">第1集</a><a href="/video/117/">别剧推荐</a>
<a href="/video/2902/">本剧主页</a>
</div></body></html>"#;

    #[test]
    fn detail_title_cover_episodes() {
        let document = Html::parse_document(DETAIL_FIXTURE);
        assert_eq!(detail_title(&document), "弱点");
        assert!(meta_content(&document, "og:image").contains("2902.jpg"));
        let summary = meta_content(&document, "og:description");
        assert_eq!(parse_episode_count(&summary), Some(34));
        // 别剧链接与主页链接被过滤，只剩本站 3 集并按集号排序。
        let eps = parse_episode_links(&document, "2902");
        assert_eq!(
            eps,
            vec![
                (1, "/video/2902/ep-1/".to_owned()),
                (2, "/video/2902/ep-2/".to_owned()),
                (10, "/video/2902/ep-10/".to_owned()),
            ]
        );
    }

    #[test]
    fn detail_title_falls_back_to_title_tag() {
        let document = Html::parse_document(
            "<html><head><title>某剧 - 短剧视频在线观看 | 黄果短剧</title></head></html>",
        );
        assert_eq!(detail_title(&document), "某剧");
        let empty = Html::parse_document("<html></html>");
        assert_eq!(detail_title(&empty), "");
    }

    const PLAY_FIXTURE: &str = r#"<html><body>
<script id="videoInitialData" type="application/json">{"ep": 10, "videoSrc": "https://cdn.example/fallback.m3u8?a=1&amp;b=2", "epPlaySrcs": {"9": "https://cdn.example/ep9.m3u8", "10": "https://cdn.example/ep10.m3u8", "11": "https://cdn.example/ep11.m3u8"}}</script>
</body></html>"#;

    #[test]
    fn play_url_prefers_episode_entry_then_falls_back() {
        let page = "https://h.example.cc/video/2902/ep-10/";
        assert_eq!(
            parse_play_url(PLAY_FIXTURE, page, 10),
            "https://cdn.example/ep10.m3u8"
        );
        // epPlaySrcs 无对应集 → videoSrc 兜底（并反转义 &amp;）。
        assert_eq!(
            parse_play_url(PLAY_FIXTURE, page, 99),
            "https://cdn.example/fallback.m3u8?a=1&b=2"
        );
        assert_eq!(parse_play_url("<html></html>", page, 10), "");
        assert_eq!(
            parse_play_url(
                "<script id=\"videoInitialData\">not json</script>",
                page,
                10
            ),
            ""
        );
    }

    #[test]
    fn join_url_resolves_and_rejects() {
        assert_eq!(
            join_url("https://h.example/cc/v/1/", "/x/y.m3u8").as_deref(),
            Some("https://h.example/x/y.m3u8")
        );
        assert_eq!(
            join_url("https://h.example/cc/v/1/", "https://cdn.example/a.m3u8").as_deref(),
            Some("https://cdn.example/a.m3u8")
        );
        assert_eq!(join_url("https://h.example/", "javascript:alert(1)"), None);
    }
}
