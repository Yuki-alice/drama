//! 红果官网 SSR（`_ROUTER_DATA`）解析：轨① 免签元数据（EVIDENCE §21）。
//!
//! 关键纪律：
//! - **不硬编码 loaderData 键名**（实测含 `category_$`、`search_(keyword)/page`、`rank_hot-drama/page`），
//!   改为遍历所有值、按"签名字段"（`searchList`/`seriesDetail`/`recommendList`/`bannerList`/`homeSections`）定位负载。
//! - 归一化后的 `Drama`/`Episode` 字段名是 **Dart 侧契约**，必须逐字一致。

use std::collections::HashSet;

use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::{Value, json};

use crate::source::traits::SourceError;

/// `_ROUTER_DATA` 定位正则（EVIDENCE §17.5）。
static ROUTER_DATA_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)(?:window\.)?_ROUTER_DATA\s*=\s*").expect("valid regex"));

/// 从 HTML 提取 `_ROUTER_DATA` 顶层对象。
pub fn extract_router_data(html: &str) -> Result<Value, SourceError> {
    let m = ROUTER_DATA_RE
        .find(html)
        .ok_or_else(|| SourceError::Parse("_ROUTER_DATA not found".to_owned()))?;
    let tail = &html[m.end()..];
    let slice = slice_top_object(tail)
        .ok_or_else(|| SourceError::Parse("unbalanced _ROUTER_DATA".to_owned()))?;
    serde_json::from_str(slice)
        .map_err(|e| SourceError::Parse(format!("invalid _ROUTER_DATA json: {e}")))
}

/// 手写括号匹配：跳过前导空白后从首个 `{` 起配对到匹配的 `}`。
///
/// 正确处理字符串内的 `"`、`\` 转义——字符串内的花括号不计入深度。
fn slice_top_object(s: &str) -> Option<&str> {
    let bytes = s.as_bytes();
    let start = s.find('{')?;
    let mut depth: i32 = 0;
    let mut in_str = false;
    let mut escaped = false;
    for (i, &b) in bytes.iter().enumerate().skip(start) {
        if in_str {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else {
            match b {
                b'"' => in_str = true,
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(&s[start..=i]);
                    }
                }
                _ => {}
            }
        }
    }
    None
}

/// 在 `loaderData` 的所有值中按签名字段定位负载（不依赖键名）：先看值自身，再看其一层子对象。
fn find_payload<'a>(data: &'a Value, signature: &str) -> Option<&'a Value> {
    let loader = data.get("loaderData")?.as_object()?;
    for v in loader.values() {
        if v.get(signature).is_some() {
            return Some(v);
        }
        if let Some(obj) = v.as_object() {
            for vv in obj.values() {
                if vv.get(signature).is_some() {
                    return Some(vv);
                }
            }
        }
    }
    None
}

/// 取字符串字段（缺失/非字符串 → `""`）。
fn str_field(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("").to_owned()
}

/// 取首个非空字符串字段。
fn first_str(v: &Value, keys: &[&str]) -> String {
    for k in keys {
        if let Some(s) = v.get(*k).and_then(Value::as_str)
            && !s.is_empty()
        {
            return s.to_owned();
        }
    }
    String::new()
}

/// 取整型字段。
fn int_field(v: &Value, key: &str) -> Option<i64> {
    v.get(key).and_then(Value::as_i64)
}

/// `tags` → `[string]`（兼容字符串项与含 `name`/`tag_name` 的对象项）。
fn tags_of(v: &Value) -> Vec<Value> {
    let Some(arr) = v.get("tags").and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|t| match t {
            Value::String(s) => Some(Value::String(s.clone())),
            Value::Object(o) => o
                .get("name")
                .or_else(|| o.get("tag_name"))
                .and_then(Value::as_str)
                .map(|s| Value::String(s.to_owned())),
            _ => None,
        })
        .collect()
}

/// 分类 `(id, name)`：从 `category_list`/`genre` 取第一个可用项；取不到返回 `("","")`。
fn category_of(v: &Value) -> (String, String) {
    for key in ["category_list", "genre"] {
        let Some(entry) = v.get(key) else {
            continue;
        };
        if let Some(arr) = entry.as_array() {
            if let Some(first) = arr.first() {
                if let Some(s) = first.as_str() {
                    return (String::new(), s.to_owned());
                }
                if let Some(o) = first.as_object() {
                    let id = o
                        .get("category_id")
                        .or_else(|| o.get("id"))
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    let name = o
                        .get("category_name")
                        .or_else(|| o.get("name"))
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    return (id, name);
                }
            }
        } else if let Some(s) = entry.as_str() {
            return (String::new(), s.to_owned());
        }
    }
    (String::new(), String::new())
}

/// 剧卡归一化（字段名为 Dart 契约，勿改）。
///
/// ⚠️ `status`：`series_episode_info.series_status` 的整数字典**未实测确证**（EVIDENCE §21 未留字典）。
/// 按常识取 `1 = 连载(ongoing)`，其余一律 `finished`——**该判定不确定，待 W3 联网校准**。
fn normalize_drama(v: &Value) -> Value {
    let episode_info = v.get("series_episode_info");
    let episode_count = int_field(v, "episode_cnt")
        .or_else(|| episode_info.and_then(|e| int_field(e, "episode_cnt")))
        .unwrap_or(0);
    let accessible = int_field(v, "accessible_episode_cnt").unwrap_or(0);
    let status_raw = episode_info
        .and_then(|e| int_field(e, "series_status"))
        .or_else(|| int_field(v, "series_status"));
    let status = if status_raw == Some(1) {
        "ongoing"
    } else {
        "finished"
    };
    let (category_id, category_name) = category_of(v);
    let pay_type = int_field(v, "pay_type").unwrap_or(0);
    json!({
        "id": str_field(v, "series_id"),
        "title": first_str(v, &["series_name", "series_title"]),
        "cover": str_field(v, "series_cover"),
        "categoryId": category_id,
        "categoryName": category_name,
        "episodeCount": episode_count,
        "accessibleEpisodes": accessible,
        "summary": str_field(v, "series_intro"),
        "tags": tags_of(v),
        "status": status,
        "vip": pay_type != 0,
    })
}

/// 选集归一化：`vid_list`（纯 vid 字符串数组）+ `accessible_episode_cnt`。
fn normalize_episodes(v: &Value) -> Vec<Value> {
    let Some(vids) = v.get("vid_list").and_then(Value::as_array) else {
        return Vec::new();
    };
    let accessible = int_field(v, "accessible_episode_cnt").unwrap_or(0);
    vids.iter()
        .enumerate()
        .map(|(i, vid)| {
            let index = i as i64 + 1;
            json!({
                "index": index,
                "vid": vid.as_str().unwrap_or(""),
                "title": format!("第 {index} 集"),
                "locked": index > accessible,
                // SSR 无时长字段，置 0（Dart 侧显示"—"）。
                "durationSeconds": 0,
            })
        })
        .collect()
}

/// 剧卡列表归一化：过滤掉无 `id` 的噪声项。
fn normalize_drama_list(list: &[Value]) -> Vec<Value> {
    list.iter()
        .map(normalize_drama)
        .filter(|d| {
            d.get("id")
                .and_then(Value::as_str)
                .is_some_and(|s| !s.is_empty())
        })
        .collect()
}

/// 取分栏的 `video_list`。
fn section_video_list(section: &Value) -> Option<&[Value]> {
    section
        .get("video_list")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
}

/// 取首页分栏首段 `video_list`。
fn first_section_items(page: &Value) -> Vec<Value> {
    page.get("homeSections")
        .and_then(Value::as_array)
        .and_then(|s| s.first())
        .and_then(section_video_list)
        .map(normalize_drama_list)
        .unwrap_or_default()
}

/// 分类目录 → `{items:[Drama], hasMore:bool, page:int}`。
pub fn parse_catalog(data: &Value, requested_page: u32) -> Result<Value, SourceError> {
    let page = find_payload(data, "recommendList")
        .ok_or_else(|| SourceError::Parse("missing recommendList".to_owned()))?;
    let list = page
        .get("recommendList")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let items = normalize_drama_list(&list);
    let pagination = page.get("pagination");
    let page_num = pagination
        .and_then(|p| int_field(p, "pageNum"))
        .unwrap_or(requested_page as i64);
    let has_more = pagination
        .and_then(|p| int_field(p, "totalPages"))
        .is_some_and(|total| page_num < total);
    Ok(json!({ "items": items, "hasMore": has_more, "page": page_num }))
}

/// 搜索 → `{items:[Drama], total:int}`（`searchList[].video_data`）。
pub fn parse_search(data: &Value) -> Result<Value, SourceError> {
    let page = find_payload(data, "searchList")
        .ok_or_else(|| SourceError::Parse("missing searchList".to_owned()))?;
    let items: Vec<Value> = page
        .get("searchList")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|e| e.get("video_data"))
                .map(normalize_drama)
                .filter(|d| {
                    d.get("id")
                        .and_then(Value::as_str)
                        .is_some_and(|s| !s.is_empty())
                })
                .collect()
        })
        .unwrap_or_default();
    let total = int_field(page, "totalCount").unwrap_or(items.len() as i64);
    Ok(json!({ "items": items, "total": total }))
}

/// 搜索建议 → `{items:[string]}`：`searchList[].name` 或 `video_data.series_name`，去重取前 8 条。
pub fn parse_suggest(data: &Value) -> Result<Value, SourceError> {
    let page = find_payload(data, "searchList")
        .ok_or_else(|| SourceError::Parse("missing searchList".to_owned()))?;
    let mut seen = HashSet::new();
    let mut items = Vec::new();
    if let Some(list) = page.get("searchList").and_then(Value::as_array) {
        for entry in list {
            let mut name = str_field(entry, "name");
            if name.is_empty()
                && let Some(vd) = entry.get("video_data")
            {
                name = first_str(vd, &["series_name", "series_title"]);
            }
            if !name.is_empty() && seen.insert(name.clone()) {
                items.push(Value::String(name));
                if items.len() >= 8 {
                    break;
                }
            }
        }
    }
    Ok(json!({ "items": items }))
}

/// 详情 + 选集 → `{drama:Drama, episodes:[Episode]}`。
pub fn parse_detail(data: &Value) -> Result<Value, SourceError> {
    let page = find_payload(data, "seriesDetail")
        .ok_or_else(|| SourceError::Parse("missing seriesDetail".to_owned()))?;
    let series = page.get("seriesDetail").unwrap_or(page);
    let drama = normalize_drama(series);
    let episodes = normalize_episodes(series);
    Ok(json!({ "drama": drama, "episodes": episodes }))
}

/// 首页推荐 → `{items:[Drama]}`：**优先 `homeSections[0].video_list`**，为空才回退 `bannerList`。
///
/// 为什么不是 banner 优先：实测 `bannerList` 项**没有 `episode_cnt`**，归一化后
/// `episodeCount = 0`，UI 会显示"共 0 集"并被误判为坏数据（W2 实机验收发现）。
/// `homeSections[].video_list` 项带 `episode_cnt`，是真实的"推荐卡"。
pub fn parse_recommend(data: &Value) -> Result<Value, SourceError> {
    let page = find_payload(data, "homeSections")
        .or_else(|| find_payload(data, "bannerList"))
        .ok_or_else(|| SourceError::Parse("missing homeSections/bannerList".to_owned()))?;
    let mut items = first_section_items(page);
    if items.is_empty()
        && let Some(banner) = page.get("bannerList").and_then(Value::as_array)
    {
        items = normalize_drama_list(banner);
    }
    Ok(json!({ "items": items }))
}

/// 榜单降级 → `{items:[Drama]}`：首页 `homeSections[section_index]`（越界回退第 1 段）。
/// 依据 EVIDENCE §21.3：榜单页 SSR 已无数据，改用官网首页分栏。
pub fn parse_home_ranking(data: &Value, section_index: usize) -> Result<Value, SourceError> {
    let page = find_payload(data, "homeSections")
        .ok_or_else(|| SourceError::Parse("missing homeSections".to_owned()))?;
    let items = page
        .get("homeSections")
        .and_then(Value::as_array)
        .and_then(|s| s.get(section_index).or_else(|| s.first()))
        .and_then(section_video_list)
        .map(normalize_drama_list)
        .unwrap_or_default();
    Ok(json!({ "items": items }))
}

/// 榜单页 `content` 解析（EVIDENCE §21.3：当前 `content` 恒为空 `{}`）。
///
/// 站点结构未实测，故仅在 `content` 为**数组**时尝试归一化；否则返回空，
/// 由调用方降级到首页分栏。保留站点修复后优先走榜单页的可能。
pub fn parse_rank_items(data: &Value) -> Vec<Value> {
    let Some(loader) = data.get("loaderData").and_then(Value::as_object) else {
        return Vec::new();
    };
    for (key, page) in loader {
        if !key.starts_with("rank_") {
            continue;
        }
        if let Some(arr) = page.get("content").and_then(Value::as_array) {
            return normalize_drama_list(arr);
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    // 提取：含前后噪声 + 字符串内的花括号 / 转义引号 / 反斜杠。
    const HTML_EXTRACT: &str = r#"<!doctype html><html><body><div>noise { not json }</div>
<script>var zz = {"ignored":true};window._ROUTER_DATA = {"loaderData":{"page":{"bannerList":[{"series_id":"A","series_name":"剧{甲[乙]}","series_cover":"c","tags":["a\"b","c\\d"]}]}},"errors":{}};</script>
<noscript>tail { noise }</noscript></body></html>"#;

    // 怪键名 + 三类签名负载同处一份 loaderData。
    const HTML_LOADER_KEYS: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{
"category_$":{"recommendList":[{"series_id":"c1","series_name":"分类剧"}],"pagination":{"total":40,"pageNum":1,"pageSize":20,"totalPages":2}},
"search_(keyword)/page":{"searchList":[{"name":"搜索名","video_data":{"series_id":"s1","series_name":"搜索剧"}}],"totalCount":57},
"rank_hot-drama/page":{"content":{}}
},"errors":{}};</script>"#;

    const HTML_HOME: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{"page":{
"bannerList":[{"series_id":"b1","series_name":"Banner剧","series_cover":"cov","series_intro":"简介","tags":["都市"],"episode_cnt":80,"accessible_episode_cnt":30,"pay_type":1,"series_episode_info":{"series_status":1}}],
"homeSections":[
{"tab_type":"hot","tab_name":"热播","video_list":[{"series_id":"h1","series_name":"第1部"}]},
{"tab_type":"ris","tab_name":"上升","video_list":[{"series_id":"h2","series_name":"第2部"}]},
{"tab_type":"fin","tab_name":"完结","video_list":[{"series_id":"h3","series_name":"第3部"}]}
]}},"errors":{}};</script>"#;

    const HTML_DETAIL: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{
"series_id":"d1","series_name":"详情剧","series_cover":"cov","series_intro":"int","tags":["a","b"],
"episode_cnt":3,"accessible_episode_cnt":2,"pay_type":0,
"series_episode_info":{"series_status":2},
"vid_list":["vid1","vid2","vid3"]
}}},"errors":{}};</script>"#;

    const HTML_SEARCH: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{"search_(关键词)/page":{
"searchList":[
{"name":"名A","video_data":{"series_id":"s1","series_name":"搜剧1","vid_list":["v1"]}},
{"name":"名A","video_data":{"series_id":"s2","series_name":"搜剧2"}},
{"name":"名B","video_data":{"series_id":"s3","series_name":"搜剧3"}}
],"totalCount":57}},"errors":{}};</script>"#;

    #[test]
    fn extracts_router_data_with_noise_and_strings() {
        let data = extract_router_data(HTML_EXTRACT).unwrap();
        let card = &data["loaderData"]["page"]["bannerList"][0];
        assert_eq!(card["series_id"], json!("A"));
        assert_eq!(card["series_name"], json!("剧{甲[乙]}"));
        assert_eq!(card["tags"][0], json!("a\"b"));
        assert_eq!(card["tags"][1], json!("c\\d"));
    }

    #[test]
    fn missing_router_data_is_parse_error() {
        let e = extract_router_data("<html>nothing here</html>").unwrap_err();
        assert_eq!(e.code(), "PARSE");
    }

    #[test]
    fn locates_payload_by_signature_not_key_name() {
        let data = extract_router_data(HTML_LOADER_KEYS).unwrap();
        let cat = parse_catalog(&data, 1).unwrap();
        assert_eq!(cat["items"][0]["id"], json!("c1"));
        assert_eq!(cat["hasMore"], json!(true));
        assert_eq!(cat["page"], json!(1));

        let search = parse_search(&data).unwrap();
        assert_eq!(search["items"][0]["id"], json!("s1"));
        assert_eq!(search["total"], json!(57));

        let sug = parse_suggest(&data).unwrap();
        assert_eq!(sug["items"], json!(["搜索名"]));

        // 榜单页 content 恒空 → 返回空（由调用方降级首页分栏）。
        assert!(parse_rank_items(&data).is_empty());
    }

    #[test]
    fn recommend_uses_first_home_section() {
        let data = extract_router_data(HTML_HOME).unwrap();
        let out = parse_recommend(&data).unwrap();
        // homeSections[0] 优先（带集数），不是 banner。
        assert_eq!(out["items"][0]["id"], json!("h1"));
    }

    #[test]
    fn recommend_falls_back_to_banner_without_home_sections() {
        // 无 homeSections 时回退 bannerList；banner 项确实没有 episode_cnt。
        const HTML_BANNER_ONLY: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{"page":{"bannerList":[{"series_id":"b1","series_name":"Banner剧","series_cover":"cov","series_intro":"简介","tags":["都市"],"episode_cnt":80,"accessible_episode_cnt":30,"pay_type":1,"series_episode_info":{"series_status":1}}]}},"errors":{}};</script>"#;
        let data = extract_router_data(HTML_BANNER_ONLY).unwrap();
        let out = parse_recommend(&data).unwrap();
        let d = &out["items"][0];
        assert_eq!(d["id"], json!("b1"));
        assert_eq!(d["title"], json!("Banner剧"));
        assert_eq!(d["cover"], json!("cov"));
        assert_eq!(d["summary"], json!("简介"));
        assert_eq!(d["tags"], json!(["都市"]));
        assert_eq!(d["episodeCount"], json!(80));
        assert_eq!(d["accessibleEpisodes"], json!(30));
        assert_eq!(d["vip"], json!(true));
        // series_status==1 → ongoing（语义未确证，见 normalize_drama 注释）。
        assert_eq!(d["status"], json!("ongoing"));
        assert_eq!(d["categoryName"], json!(""));
    }

    #[test]
    fn ranking_uses_home_sections_by_index_with_fallback() {
        let data = extract_router_data(HTML_HOME).unwrap();
        assert_eq!(
            parse_home_ranking(&data, 0).unwrap()["items"][0]["id"],
            json!("h1")
        );
        assert_eq!(
            parse_home_ranking(&data, 1).unwrap()["items"][0]["id"],
            json!("h2")
        );
        assert_eq!(
            parse_home_ranking(&data, 2).unwrap()["items"][0]["id"],
            json!("h3")
        );
        // 越界回退第 1 段。
        assert_eq!(
            parse_home_ranking(&data, 9).unwrap()["items"][0]["id"],
            json!("h1")
        );
    }

    #[test]
    fn detail_normalizes_drama_and_episodes() {
        let data = extract_router_data(HTML_DETAIL).unwrap();
        let out = parse_detail(&data).unwrap();
        let d = &out["drama"];
        assert_eq!(d["id"], json!("d1"));
        assert_eq!(d["title"], json!("详情剧"));
        assert_eq!(d["episodeCount"], json!(3));
        assert_eq!(d["accessibleEpisodes"], json!(2));
        assert_eq!(d["status"], json!("finished"));
        assert_eq!(d["vip"], json!(false));
        assert_eq!(d["tags"], json!(["a", "b"]));

        let eps = out["episodes"].as_array().unwrap();
        assert_eq!(eps.len(), 3);
        assert_eq!(eps[0]["index"], json!(1));
        assert_eq!(eps[0]["vid"], json!("vid1"));
        assert_eq!(eps[0]["title"], json!("第 1 集"));
        assert_eq!(eps[0]["durationSeconds"], json!(0));
        // locked 阈值 = accessible_episode_cnt = 2。
        assert_eq!(eps[0]["locked"], json!(false));
        assert_eq!(eps[1]["locked"], json!(false));
        assert_eq!(eps[2]["locked"], json!(true));
        assert_eq!(eps[2]["vid"], json!("vid3"));
        assert_eq!(eps[2]["title"], json!("第 3 集"));
    }

    #[test]
    fn search_and_suggest_from_search_list() {
        let data = extract_router_data(HTML_SEARCH).unwrap();
        let s = parse_search(&data).unwrap();
        assert_eq!(s["total"], json!(57));
        let items = s["items"].as_array().unwrap();
        assert_eq!(items.len(), 3);
        assert_eq!(items[0]["id"], json!("s1"));
        assert_eq!(items[0]["title"], json!("搜剧1"));

        // name 去重，"名A" 只取一次。
        let sug = parse_suggest(&data).unwrap();
        assert_eq!(sug["items"], json!(["名A", "名B"]));
    }

    #[test]
    fn rank_items_parsed_when_content_is_array() {
        const HTML: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{"rank_hot-drama/page":{"content":[{"series_id":"r1","series_name":"榜剧"}]}},"errors":{}};</script>"#;
        let data = extract_router_data(HTML).unwrap();
        let items = parse_rank_items(&data);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], json!("r1"));
    }
}
