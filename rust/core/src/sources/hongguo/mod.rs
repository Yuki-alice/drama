//! 红果内置源：浏览面免签 SSR，详情与取流面走签名 App 接口（失败逐级降级）。

pub mod web_ssr;

use serde_json::{Value, json};

use crate::http;
use crate::source::traits::{Caps, SourceError, SourceProvider};
use crate::{app_api, gateway};

/// 站点根。
const BASE: &str = "https://www.hongguoduanju.com";

/// 封面/详情图的 Referer（源站 CDN 对此宽容，但带上更稳）。
const SITE_REFERER: &str = "https://www.hongguoduanju.com/";

/// 默认分类路由（`category` 缺省时使用， route 之一）。
const DEFAULT_CATEGORY_ROUTE: &str = "real-drama";

/// 红果源：轨① 免签元数据（目录/推荐/榜单/搜索/建议/详情）。
pub struct HongguoProvider;

impl HongguoProvider {
    /// 构造。
    pub fn new() -> Self {
        Self
    }
}

impl Default for HongguoProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl SourceProvider for HongguoProvider {
    fn id(&self) -> &'static str {
        "hongguo"
    }

    fn caps(&self) -> Caps {
        Caps {
            catalog: true,
            search: true,
            suggest: true,
            recommend: true,
            ranking: true,
            detail: true,
            playback: true,
        }
    }

    fn catalog(&self, category: Option<&str>, page: u32) -> Result<Value, SourceError> {
        let route = category
            .filter(|c| !c.is_empty())
            .unwrap_or(DEFAULT_CATEGORY_ROUTE);
        // `page` 为 0 起页号；站点是 1 起 `?page=N`，裸 URL 即第 1 页
        //（联网实测：裸 URL 与 `?page=1` 同内容，`?page=2` 为第 2 页）。
        let url = if page == 0 {
            format!("{BASE}/category/{route}")
        } else {
            format!("{BASE}/category/{route}?page={}", page + 1)
        };
        let html = http::fetch_text_throttled(&url)?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_catalog(&data, page).map(proxy_covers)
    }

    fn recommend(&self) -> Result<Value, SourceError> {
        let html = http::fetch_text_throttled(&format!("{BASE}/"))?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_recommend(&data).map(proxy_covers)
    }

    fn ranking(&self, board: Option<&str>) -> Result<Value, SourceError> {
        let board = board.unwrap_or("hot");
        // 先试榜单页（当前 content 恒空，仅为站点修复后保留可能）。
        let rank_url = format!("{BASE}/rank/{}", rank_key_for(board));
        if let Ok(html) = http::fetch_text_throttled(&rank_url)
            && let Ok(data) = web_ssr::extract_router_data(&html)
        {
            let items = web_ssr::parse_rank_items(&data);
            if !items.is_empty() {
                return Ok(proxy_covers(json!({ "items": items })));
            }
        }
        // 降级：首页 homeSections（W2 方案）。
        let html = http::fetch_text_throttled(&format!("{BASE}/"))?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_home_ranking(&data, section_index_for(board)).map(proxy_covers)
    }

    fn search(&self, keyword: &str) -> Result<Value, SourceError> {
        let url = format!("{BASE}/search/{}", urlencode_path(keyword));
        let html = http::fetch_text_throttled(&url)?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_search(&data).map(proxy_covers)
    }

    fn suggest(&self, keyword: &str) -> Result<Value, SourceError> {
        let url = format!("{BASE}/search/{}", urlencode_path(keyword));
        let html = http::fetch_text_throttled(&url)?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_suggest(&data)
    }

    fn detail(&self, series_id: &str) -> Result<Value, SourceError> {
        // App 主链 → SSR 降级：取消/超时直接返回，其余错误才降级。
        let out = match crate::app_api::app_detail(series_id) {
            Ok(v) => v,
            Err(e @ (SourceError::Canceled | SourceError::Timeout)) => return Err(e),
            Err(_) => {
                let url = format!("{BASE}/detail?series_id={series_id}");
                let html = http::fetch_text_throttled(&url)?;
                let data = web_ssr::extract_router_data(&html)?;
                web_ssr::parse_detail(&data)?
            }
        };
        Ok(proxy_covers(out))
    }

    fn play(
        &self,
        series_id: &str,
        episode: u32,
        vid: Option<String>,
        quality: i64,
    ) -> Result<Value, SourceError> {
        let vid = match vid.filter(|v| !v.is_empty()) {
            Some(v) => v,
            None => {
                let detail = self.detail(series_id)?;
                let index = episode.max(1) as usize - 1;
                detail
                    .get("episodes")
                    .and_then(Value::as_array)
                    .and_then(|eps| eps.get(index))
                    .and_then(|ep| ep.get("vid"))
                    .and_then(Value::as_str)
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| SourceError::Parse("episode has no vid".to_owned()))?
                    .to_owned()
            }
        };
        let media = app_api::resolve_media(series_id, &vid, quality)?;
        let (proxy_url, _) = register_and_warm(&media, false)?;
        let mut out = media.to_json();
        out["proxyUrl"] = json!(proxy_url);
        out["vid"] = json!(vid);
        Ok(out)
    }

    fn play_variant(
        &self,
        series_id: &str,
        video_id: &str,
        quality: i64,
    ) -> Result<Value, SourceError> {
        // 换档的快路径：`switch_quality` 只在**已解析出的候选**里重挑，
        // 不走签名链（用户在播放中点「1080P」应当是瞬时的）。
        // 旁路没有这一集（首次取流前换档 / TTL 已过）才回落到完整解析。
        let media = match app_api::switch_quality(video_id, quality) {
            Some(m) => m,
            None => app_api::resolve_media(series_id, video_id, quality)?,
        };
        // 换档不预热：预热要解密首 64KiB，换档追求的是「立刻接着播」。
        let (proxy_url, _) = register_and_warm(&media, false)?;
        let mut out = media.to_json();
        out["proxyUrl"] = json!(proxy_url);
        out["vid"] = json!(video_id);
        Ok(out)
    }

    fn preload(
        &self,
        series_id: &str,
        episode: u32,
        vid: Option<String>,
        quality: i64,
    ) -> Result<Value, SourceError> {
        let vid = match vid.filter(|v| !v.is_empty()) {
            Some(v) => v,
            None => {
                let detail = self.detail(series_id)?;
                let index = episode.max(1) as usize - 1;
                detail
                    .get("episodes")
                    .and_then(Value::as_array)
                    .and_then(|eps| eps.get(index))
                    .and_then(|ep| ep.get("vid"))
                    .and_then(Value::as_str)
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| SourceError::Parse("episode has no vid".to_owned()))?
                    .to_owned()
            }
        };
        let media = app_api::resolve_media(series_id, &vid, quality)?;
        let (proxy_url, warmed_bytes) = register_and_warm(&media, true)?;
        Ok(json!({
            "ready": true,
            "proxyUrl": proxy_url,
            "vid": vid,
            "warmedBytes": warmed_bytes,
        }))
    }
}

/// 解析结果注册网关会话；`warm` 时额外解密首个 64KiB（验证链路，
/// 把 moov 解析与 CDN 首字节提前做完，播放器打开即播）。
fn register_and_warm(
    media: &app_api::ResolvedMedia,
    warm: bool,
) -> Result<(String, u64), SourceError> {
    let key = if media.encrypted {
        Some(hex_to_key(&media.key_hex)?)
    } else {
        None
    };
    let proxy_url = gateway::register(
        &media.url,
        media.referer,
        http::USER_AGENT_VALUE.to_owned(),
        key,
    )
    .map_err(SourceError::Parse)?;
    if !warm {
        return Ok((proxy_url, 0));
    }
    let warmed = gateway::warm_first_window(&proxy_url, 65536).map_err(SourceError::Parse)?;
    Ok((proxy_url, warmed))
}

/// 把结果里所有 `cover` 字段从源站 CDN 换成本机代理 URL。
///
/// **为什么在这一层做**：本函数位于 provider 返回值的**唯一出口**（每个 op 都
/// 过一遍），因此不会漏掉某条新加的链路；且 Dart 侧永远只看到 `127.0.0.1`，
/// 遵守「Dart 禁直连源站」的纪律（见 `covers` 模块头注释）。
///
/// 递归处理 `items` / `drama` / 任意嵌套数组与对象；空白 cover 原样保留
/// （Dart 侧据此回落到渐变占位）。`covers::proxy_url` 在端口未绑定或
/// 未 `init` 时返回空串，此时同样回落占位，不影响主流程。
fn proxy_covers(value: Value) -> Value {
    crate::covers::proxy_covers(value, SITE_REFERER)
}

/// `keyHex` → 16 字节（网关解密用；非法即报错，不静默降级为透传）。
fn hex_to_key(hex: &str) -> Result<[u8; 16], SourceError> {
    if hex.len() != 32 {
        return Err(SourceError::Parse("bad key length".to_owned()));
    }
    let mut out = [0u8; 16];
    for (i, chunk) in out.iter_mut().enumerate() {
        *chunk = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
            .map_err(|_| SourceError::Parse("bad key hex".to_owned()))?;
    }
    Ok(out)
}

/// 语义 `board` → 榜单页 key（`hot-drama|hot-real-drama|hot-comic-drama|hot-ai-drama`）。
///
/// 未知板**故意**回退热榜而非报错：榜单是内容位，降级不断流
///（与熔断回退旧值、分栏越界回退第 1 段同一哲学）；前端只发三板，
/// 未知值只可能来自手工构造，此时返回热榜比抛错更可用。
fn rank_key_for(board: &str) -> &str {
    match board {
        "hot-drama" | "hot-real-drama" | "hot-comic-drama" | "hot-ai-drama" => board,
        "rising" => "hot-real-drama",
        "finished" => "hot-comic-drama",
        _ => "hot-drama",
    }
}

/// 语义 `board` → 首页分栏序号（hot→第1、rising→第2、finished→第3；越界回退第1）。
fn section_index_for(board: &str) -> usize {
    match board {
        "rising" => 1,
        "finished" => 2,
        _ => 0,
    }
}

/// 关键词路径段百分号编码（`/search/{kw}` 为路径段，非 query）。
fn urlencode_path(keyword: &str) -> String {
    let mut out = String::new();
    for b in keyword.as_bytes() {
        match *b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char);
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source;

    #[test]
    fn board_maps_to_rank_key() {
        assert_eq!(rank_key_for("hot"), "hot-drama");
        assert_eq!(rank_key_for("rising"), "hot-real-drama");
        assert_eq!(rank_key_for("finished"), "hot-comic-drama");
        assert_eq!(rank_key_for("hot-ai-drama"), "hot-ai-drama");
    }

    #[test]
    fn board_maps_to_section_index() {
        assert_eq!(section_index_for("hot"), 0);
        assert_eq!(section_index_for("rising"), 1);
        assert_eq!(section_index_for("finished"), 2);
        assert_eq!(section_index_for("whatever"), 0);
    }

    #[test]
    fn path_encode_keeps_unreserved_and_escapes_others() {
        assert_eq!(urlencode_path("abc123"), "abc123");
        assert_eq!(urlencode_path("a b"), "a%20b");
        assert_eq!(urlencode_path("剧"), "%E5%89%A7");
    }

    #[test]
    fn proxy_covers_never_rewrites_blank_or_relative() {
        // 空白与相对路径**永远**不得被改写（否则 Dart 侧会拿到一个
        // 指向代理但上游无效的地址，比直接留空更糟）。
        // 注意：绝对 URL 是否被改写取决于本进程内网关端口能否绑定
        // （OnceLock 全局），故那部分单独测，且不依赖测试执行顺序。
        let out = proxy_covers(json!({
            "items": [
                {"id": "a", "cover": "", "title": "A"},
                {"id": "b", "cover": "   ", "title": "B"},
                {"id": "c", "cover": "/rel.png", "title": "C"},
                {"id": "d", "cover": "ftp://cdn/x.png", "title": "D"},
            ]
        }));
        assert_eq!(out["items"][0]["cover"], json!(""));
        assert_eq!(out["items"][1]["cover"], json!("   "));
        assert_eq!(out["items"][2]["cover"], json!("/rel.png"));
        assert_eq!(out["items"][3]["cover"], json!("ftp://cdn/x.png"));
    }

    #[test]
    fn proxy_covers_rewrites_absolute_url_to_loopback_when_port_available() {
        let out = proxy_covers(json!({
            "items": [{"id": "a", "cover": "https://p11-novel-seo.byteimg.com/x.png"}]
        }));
        let cover = out["items"][0]["cover"].as_str().unwrap();
        if crate::gateway::ensure_port().is_ok() {
            // 端口可用 → 必须换成本机地址，绝不把源站地址漏给 Dart。
            assert!(
                cover.starts_with("http://127.0.0.1:"),
                "expected loopback proxy, got {cover}"
            );
            assert!(cover.contains("/img/"), "expected /img/ path, got {cover}");
        } else {
            // 端口不可用（极少数沙箱环境）→ 保持原值，Dart 侧回落占位。
            assert_eq!(cover, "https://p11-novel-seo.byteimg.com/x.png");
        }
    }

    #[test]
    fn proxy_covers_recurses_nested_objects_and_keeps_other_fields() {
        let out = proxy_covers(json!({
            "drama": {"id": "d1", "cover": "", "episodeCount": 12},
            "episodes": [{"index": 1, "vid": "v1"}]
        }));
        // 结构与非 cover 字段原样保留。
        assert_eq!(out["drama"]["episodeCount"], json!(12));
        assert_eq!(out["episodes"][0]["vid"], json!("v1"));
        assert_eq!(out["drama"]["cover"], json!(""));
    }

    /// 联网测试（默认跳过）：验证封面代理端到端可服务真实图片。
    #[test]
    #[ignore = "联网：需访问 hongguoduanju.com 与其 CDN"]
    fn network_cover_proxy_serves_real_image() {
        // 先把 dataDir 指到临时目录（封面磁盘缓存要落盘）。
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let dir = std::env::temp_dir().join("drama-cover-probe");
        let _ = std::fs::create_dir_all(&dir);
        crate::device::set_data_dir(dir.clone());

        let p = source::provider(Some("hongguo")).unwrap();
        let cat = p.catalog(Some("real-drama"), 1).unwrap();
        let cover = cat["items"][0]["cover"].as_str().unwrap_or("").to_owned();
        eprintln!("cover field = {cover}");
        assert!(
            cover.starts_with("http://127.0.0.1:"),
            "cover must be loopback, got {cover}"
        );
        assert!(cover.contains("/img/"), "cover must use /img/: {cover}");

        // 真的把它取下来（走本机代理 → 回源 → 缓存）。
        let bytes = crate::http::runtime_handle()
            .block_on(async { reqwest::get(&cover).await.unwrap().bytes().await.unwrap() });
        eprintln!("proxied cover bytes = {}", bytes.len());
        assert!(bytes.len() > 1000, "cover too small: {}", bytes.len());
        // PNG/JPEG 魔数校验：确认拿到的是图片而不是错误页。
        let is_png = bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]);
        let is_jpg = bytes.starts_with(&[0xFF, 0xD8, 0xFF]);
        let is_webp = bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP";
        assert!(
            is_png || is_jpg || is_webp,
            "not an image: {:?}",
            &bytes[..8.min(bytes.len())]
        );

        crate::device::clear_data_dir();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 联网测试（默认跳过）：`cargo test -- --ignored` 才跑。
    #[test]
    #[ignore = "联网：需访问 hongguoduanju.com"]
    fn network_catalog_has_items() {
        let p = source::provider(Some("hongguo")).unwrap();
        let out = p.catalog(Some("real-drama"), 1).unwrap();
        assert!(!out["items"].as_array().unwrap().is_empty());
    }

    /// 联网测试（默认跳过）：详情。
    #[test]
    #[ignore = "联网：需访问 hongguoduanju.com"]
    fn network_detail_has_drama() {
        let p = source::provider(Some("hongguo")).unwrap();
        // 取目录首个 series_id，再查详情。
        let cat = p.catalog(Some("real-drama"), 1).unwrap();
        let id = cat["items"][0]["id"].as_str().unwrap().to_owned();
        let out = p.detail(&id).unwrap();
        assert!(!out["drama"]["id"].as_str().unwrap().is_empty());
        assert!(!out["episodes"].as_array().unwrap().is_empty());
    }

    /// 联网测试（默认跳过）：搜索。
    #[test]
    #[ignore = "联网：需访问 hongguoduanju.com"]
    fn network_search_has_items() {
        let p = source::provider(Some("hongguo")).unwrap();
        let out = p.search("总裁").unwrap();
        assert!(!out["items"].as_array().unwrap().is_empty());
    }

    /// 联网测试（默认跳过）：端到端取流。
    /// 目录 → 详情（App 主链）→ 第 1 集取流，打印关键字段供人工核对。
    #[test]
    #[ignore = "联网：需访问 hongguoduanju.com 与 App 接口"]
    fn network_play_resolves_first_episode() {
        let p = source::provider(Some("hongguo")).unwrap();
        let cat = p.catalog(Some("real-drama"), 1).unwrap();
        let id = cat["items"][0]["id"].as_str().unwrap().to_owned();
        let out = p.play(&id, 1, None, 0).unwrap();
        let proxy = out["proxyUrl"].as_str().unwrap_or("");
        let url = out["url"].as_str().unwrap_or("");
        eprintln!(
            "series={id} encrypted={} quality={} url={url} proxy={proxy}",
            out["encrypted"], out["quality"]
        );
        assert!(!url.is_empty());
        assert!(proxy.starts_with("http://127.0.0.1:"));
        assert!(!out["variants"].as_array().unwrap().is_empty());
        // 预取下集不断流。
        let pre = p.preload(&id, 2, None, 0).unwrap();
        assert_eq!(pre["ready"], json!(true));
        assert!(
            pre["proxyUrl"]
                .as_str()
                .unwrap()
                .starts_with("http://127.0.0.1:")
        );
    }
}
