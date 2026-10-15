//! 红果内置源（官网 SSR 免签轨）。依据 EVIDENCE §21。

pub mod web_ssr;

use serde_json::{Value, json};

use crate::http;
use crate::source::traits::{Caps, SourceError, SourceProvider};

/// 站点根（EVIDENCE §17 / §21.1）。
const BASE: &str = "https://www.hongguoduanju.com";

/// 默认分类路由（`category` 缺省时使用，EVIDENCE §21.1 route 之一）。
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
            // EVIDENCE §21.4：轨① 明文直链已不可得，故 playback 如实声明为 false；
            // `play` op 不实现，被调用时返回 UNSUPPORTED。
            playback: false,
        }
    }

    fn catalog(&self, category: Option<&str>, page: u32) -> Result<Value, SourceError> {
        let route = category
            .filter(|c| !c.is_empty())
            .unwrap_or(DEFAULT_CATEGORY_ROUTE);
        // 站点分页参数未经实测；page>1 时按 `?page=` 拼装（待 W3 联网校准）。
        let url = if page > 1 {
            format!("{BASE}/category/{route}?page={page}")
        } else {
            format!("{BASE}/category/{route}")
        };
        let html = http::fetch_text_throttled(&url)?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_catalog(&data, page)
    }

    fn recommend(&self) -> Result<Value, SourceError> {
        let html = http::fetch_text_throttled(&format!("{BASE}/"))?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_recommend(&data)
    }

    fn ranking(&self, board: Option<&str>) -> Result<Value, SourceError> {
        let board = board.unwrap_or("hot");
        // 先试榜单页（EVIDENCE §21.3：当前 content 恒空，仅为站点修复后保留可能）。
        let rank_url = format!("{BASE}/rank/{}", rank_key_for(board));
        if let Ok(html) = http::fetch_text_throttled(&rank_url)
            && let Ok(data) = web_ssr::extract_router_data(&html)
        {
            let items = web_ssr::parse_rank_items(&data);
            if !items.is_empty() {
                return Ok(json!({ "items": items }));
            }
        }
        // 降级：首页 homeSections（EVIDENCE §21.3 W2 方案）。
        let html = http::fetch_text_throttled(&format!("{BASE}/"))?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_home_ranking(&data, section_index_for(board))
    }

    fn search(&self, keyword: &str) -> Result<Value, SourceError> {
        let url = format!("{BASE}/search/{}", urlencode_path(keyword));
        let html = http::fetch_text_throttled(&url)?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_search(&data)
    }

    fn suggest(&self, keyword: &str) -> Result<Value, SourceError> {
        let url = format!("{BASE}/search/{}", urlencode_path(keyword));
        let html = http::fetch_text_throttled(&url)?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_suggest(&data)
    }

    fn detail(&self, series_id: &str) -> Result<Value, SourceError> {
        let url = format!("{BASE}/detail?series_id={series_id}");
        let html = http::fetch_text_throttled(&url)?;
        let data = web_ssr::extract_router_data(&html)?;
        web_ssr::parse_detail(&data)
    }
}

/// 语义 `board` → 榜单页 key（EVIDENCE §21.1：`hot-drama|hot-real-drama|hot-comic-drama|hot-ai-drama`）。
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
}
