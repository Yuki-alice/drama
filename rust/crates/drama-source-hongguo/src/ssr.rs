//! 官网 SSR 解析：`_ROUTER_DATA` 提取 + 各页面负载解析。
//!
//! 官网是 Next.js/React Router 的 SSR，数据塞在 `window._ROUTER_DATA = {...}`
//! 里。这个 JSON 的结构**不稳定**：`loaderData` 的键名会随路由变化
//! （实测有 `category_$`、`search_(keyword)/page`、`rank_hot-drama/page`）。
//!
//! 因此这里**不硬编码键名**，而是按「签名字段」定位负载：找哪个值里有
//! `recommendList` / `searchList` / `seriesDetail` / `homeSections`，
//! 那就是我们要的那一块。这比记键名稳，也不会因为站点改键名就整页空。

use std::collections::HashSet;

use serde_json::Value;

use drama_types::{Drama, DramaId, DramaStatus, Episode, SourceId, VipState};

/// 解析错误。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SsrError {
    #[error("页面中没有找到 _ROUTER_DATA")]
    NoRouterData,
    #[error("_ROUTER_DATA 不是完整的 JSON 对象")]
    UnbalancedRouterData,
    #[error("_ROUTER_DATA 解析失败: {0}")]
    InvalidRouterData(String),
    #[error("页面缺少 {0} 字段")]
    MissingPayload(&'static str),
    #[error("站点返回 isSuccess=false")]
    NotSuccessful,
    #[error("响应中没有可识别的剧集")]
    NoItems,
}

/// 从 HTML 提取 `_ROUTER_DATA` 顶层对象。
pub fn extract_router_data(html: &str) -> Result<Value, SsrError> {
    let marker = "_ROUTER_DATA";
    let start = html.find(marker).ok_or(SsrError::NoRouterData)?;
    let tail = &html[start + marker.len()..];
    let slice = slice_top_object(tail).ok_or(SsrError::UnbalancedRouterData)?;
    serde_json::from_str(slice).map_err(|e| SsrError::InvalidRouterData(e.to_string()))
}

/// 手写括号匹配：从首个 `{` 起配对到匹配的 `}`。
///
/// 必须正确处理字符串内的 `"`、`\` 转义——字符串里的花括号不计入深度。
/// 用正则做这件事会在「简介里含 `}`」时崩掉。
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

/// 在 `loaderData` 的所有值中按签名字段定位负载。
///
/// 先看值自身，再看其一层子对象（部分路由把负载包了一层）。
pub fn find_payload<'a>(data: &'a Value, signature: &str) -> Option<&'a Value> {
    let loader = data.get("loaderData")?.as_object()?;
    for value in loader.values() {
        if value.get(signature).is_some() {
            return Some(value);
        }
        if let Some(obj) = value.as_object() {
            for inner in obj.values() {
                if inner.get(signature).is_some() {
                    return Some(inner);
                }
            }
        }
    }
    None
}

/// 按前缀定位负载（榜单用：键名形如 `rank_hot-drama/page`）。
pub fn find_payload_by_prefix<'a>(data: &'a Value, prefix: &str) -> Option<&'a Value> {
    let loader = data.get("loaderData")?.as_object()?;
    loader
        .iter()
        .find(|(k, _)| k.starts_with(prefix))
        .map(|(_, v)| v)
}

fn str_of(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(|x| match x {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        })
        .unwrap_or_default()
}

fn first_str(v: &Value, keys: &[&str]) -> String {
    for key in keys {
        let s = str_of(v, key);
        if !s.is_empty() {
            return s;
        }
    }
    String::new()
}

fn int_of(v: &Value, key: &str) -> Option<i64> {
    match v.get(key)? {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

/// 标签提取：兼容字符串项与含 `name`/`tag_name` 的对象项。
fn tags_of(v: &Value) -> Vec<String> {
    let Some(arr) = v.get("tags").and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|t| match t {
            Value::String(s) => Some(s.clone()),
            Value::Object(o) => o
                .get("name")
                .or_else(|| o.get("tag_name"))
                .and_then(Value::as_str)
                .map(str::to_owned),
            _ => None,
        })
        .filter(|s| !s.is_empty())
        .collect()
}

/// 分类 `(id, name)`：取 `category_list`/`genre` 的第一项。
fn category_of(v: &Value) -> (String, String) {
    for key in ["category_list", "genre"] {
        let Some(entry) = v.get(key) else { continue };
        if let Some(arr) = entry.as_array() {
            let Some(first) = arr.first() else { continue };
            if let Some(s) = first.as_str() {
                return (String::new(), s.to_owned());
            }
            if let Some(o) = first.as_object() {
                let id = o
                    .get("category_id")
                    .or_else(|| o.get("id"))
                    .map(|x| match x {
                        Value::String(s) => s.clone(),
                        Value::Number(n) => n.to_string(),
                        _ => String::new(),
                    })
                    .unwrap_or_default();
                let name = o
                    .get("category_name")
                    .or_else(|| o.get("name"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                return (id, name);
            }
        } else if let Some(s) = entry.as_str() {
            return (String::new(), s.to_owned());
        }
    }
    (String::new(), String::new())
}

/// 剧卡归一化。
///
/// `status` 口径：`series_status == 1` 为连载中，其余完结。
/// `vip` 用 `pay_type`：**字段缺失时是 `Unknown` 而不是 `Free`**——
/// 这是三态存在的意义（缺失不等于免费）。
pub fn normalize_drama(value: &Value) -> Option<Drama> {
    let source_id = str_of(value, "series_id");
    if source_id.is_empty() {
        return None;
    }
    let episode_info = value.get("series_episode_info");
    let episode_count = int_of(value, "episode_cnt")
        .or_else(|| episode_info.and_then(|e| int_of(e, "episode_cnt")))
        .unwrap_or(0);
    let accessible = int_of(value, "accessible_episode_cnt").unwrap_or(0);
    let status_raw = episode_info
        .and_then(|e| int_of(e, "series_status"))
        .or_else(|| int_of(value, "series_status"));
    let (category_id, category_name) = category_of(value);

    Some(Drama {
        id: DramaId::new(SourceId::new(crate::SOURCE_ID), source_id),
        title: first_str(value, &["series_name", "series_title"]),
        cover: str_of(value, "series_cover"),
        category_id,
        category_name,
        episode_count: episode_count.max(0) as u32,
        accessible_episodes: accessible.max(0) as u32,
        summary: str_of(value, "series_intro"),
        tags: tags_of(value),
        status: DramaStatus::from_series_status(status_raw),
        // 缺失 → Unknown（不冒充满费）。
        vip: VipState::from_pay_type(int_of(value, "pay_type")),
        metric: String::new(),
    })
}

fn normalize_list(list: &[Value]) -> Vec<Drama> {
    list.iter().filter_map(normalize_drama).collect()
}

/// 分类目录解析结果。
#[derive(Debug, Clone)]
pub struct CatalogParsed {
    pub items: Vec<Drama>,
    pub has_more: bool,
}

/// 解析分类目录页。
pub fn parse_catalog(data: &Value) -> Result<CatalogParsed, SsrError> {
    let page =
        find_payload(data, "recommendList").ok_or(SsrError::MissingPayload("recommendList"))?;
    // 站点在拿不到数据时会返回 isSuccess=false，此时不能当空列表。
    if page.get("isSuccess").and_then(Value::as_bool) == Some(false) {
        return Err(SsrError::NotSuccessful);
    }
    let list = page
        .get("recommendList")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let items = normalize_list(list);
    let pagination = page.get("pagination");
    let page_num = pagination.and_then(|p| int_of(p, "pageNum")).unwrap_or(1);
    let has_more = pagination
        .and_then(|p| int_of(p, "totalPages"))
        .is_some_and(|total| page_num < total);
    Ok(CatalogParsed { items, has_more })
}

/// 搜索结果。
#[derive(Debug, Clone)]
pub struct SearchParsed {
    pub items: Vec<Drama>,
    pub total: usize,
    /// 页面回显的查询词（用于校验「返回的确实是这次搜索」）。
    pub query: String,
}

/// 解析搜索页。
pub fn parse_search(data: &Value, keyword: &str) -> Result<SearchParsed, SsrError> {
    let page = find_payload(data, "searchList").ok_or(SsrError::MissingPayload("searchList"))?;
    if page.get("isSuccess").and_then(Value::as_bool) == Some(false) {
        return Err(SsrError::NotSuccessful);
    }
    let query = str_of(page, "query");
    // 站点回显了查询词但不一致：说明拿到的是别的搜索的结果，不能冒充。
    if !query.is_empty() && query != keyword {
        return Err(SsrError::NotSuccessful);
    }
    let list = page
        .get("searchList")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let items: Vec<Drama> = list
        .iter()
        .filter_map(|entry| entry.get("video_data"))
        .filter_map(normalize_drama)
        .collect();
    let total = int_of(page, "totalCount")
        .unwrap_or(items.len() as i64)
        .max(0) as usize;
    Ok(SearchParsed {
        items,
        total,
        query,
    })
}

/// 详情解析结果。
#[derive(Debug, Clone)]
pub struct DetailParsed {
    pub drama: Drama,
    pub episodes: Vec<Episode>,
}

/// 解析详情页。
pub fn parse_detail(data: &Value, series_id: &str) -> Result<DetailParsed, SsrError> {
    let page = find_payload(data, "seriesDetail")
        .or_else(|| find_payload_by_prefix(data, "detail_"))
        .ok_or(SsrError::MissingPayload("seriesDetail"))?;
    let detail = page
        .get("seriesDetail")
        .ok_or(SsrError::MissingPayload("seriesDetail"))?;

    // 身份校验：站点在拿不到目标时会返回「默认推荐」，不校验就会把别的剧当成用户的。
    let returned = first_str(detail, &["series_id", "series_id_str"]);
    if !returned.is_empty() && returned != series_id {
        return Err(SsrError::NotSuccessful);
    }

    let mut drama = normalize_drama(detail).ok_or(SsrError::NoItems)?;
    if drama.title.is_empty() {
        drama.title = series_id.to_owned();
    }
    let accessible = int_of(detail, "accessible_episode_cnt")
        .unwrap_or(0)
        .max(0) as u32;
    let episodes = detail
        .get("vid_list")
        .and_then(Value::as_array)
        .map(|vids| {
            vids.iter()
                .filter_map(|v| v.as_str())
                .filter(|s| !s.is_empty() && *s != "<nil>")
                .enumerate()
                .map(|(i, vid)| {
                    let index = i as u32 + 1;
                    Episode {
                        index,
                        title: format!("第{index}集"),
                        vid: Some(vid.to_owned()),
                        duration_seconds: 0,
                        // 试看集之外标锁：UI 必须明示「需授权」而不是静默失败。
                        locked: accessible > 0 && index > accessible,
                        url: String::new(),
                    }
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if episodes.is_empty() {
        return Err(SsrError::NoItems);
    }
    Ok(DetailParsed { drama, episodes })
}

/// 解析首页推荐：取 `homeSections` 各段的 `video_list` 合并去重。
pub fn parse_recommend(data: &Value) -> Result<Vec<Drama>, SsrError> {
    let page = find_payload(data, "homeSections").ok_or(SsrError::MissingPayload("homeSections"))?;
    let sections = page
        .get("homeSections")
        .and_then(Value::as_array)
        .ok_or(SsrError::MissingPayload("homeSections"))?;
    let mut seen = HashSet::new();
    let mut items = Vec::new();
    for section in sections {
        let Some(list) = section.get("video_list").and_then(Value::as_array) else {
            continue;
        };
        for drama in normalize_list(list) {
            if seen.insert(drama.id.to_key()) {
                items.push(drama);
            }
        }
    }
    if items.is_empty() {
        return Err(SsrError::NoItems);
    }
    Ok(items)
}

/// 解析搜索联想（`suggest_list`）。
pub fn parse_suggest(body: &Value, limit: usize) -> Vec<String> {
    let list = body
        .get("suggest_list")
        .and_then(Value::as_array)
        .or_else(|| {
            body.get("data")
                .and_then(|d| d.get("suggest_list"))
                .and_then(Value::as_array)
        });
    let Some(list) = list else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for entry in list {
        let name = str_of(entry, "name").trim().to_owned();
        if name.is_empty() {
            continue;
        }
        // 去重按小写：`都市` 与 `都市 ` 归一后相同。
        if !seen.insert(name.to_lowercase()) {
            continue;
        }
        out.push(name);
        if out.len() == limit {
            break;
        }
    }
    out
}

/// 榜单条目（解析中间结果）。
#[derive(Debug, Clone)]
pub struct RankingRow {
    pub series_id: String,
    pub title: String,
    pub cover: String,
    pub heat: String,
    pub score: String,
    pub description: String,
    pub tags: Vec<String>,
    pub rank: u32,
}

/// 解析榜单页的 `content.rankList`。
///
/// 榜单的 loader 键名带路由（`rank_hot-drama/page`），故按前缀找。
pub fn parse_ranking(
    data: &Value,
    board_route: &str,
    page: u32,
) -> Result<Vec<RankingRow>, SsrError> {
    let key = format!("rank_{board_route}");
    let loader =
        find_payload_by_prefix(data, &key).ok_or(SsrError::MissingPayload("rankList"))?;

    // 自识别：loader 若带 `pageNum`，必须与请求页一致。
    if let Some(page_num) = loader.get("pageNum").and_then(Value::as_str)
        && !page_num.is_empty()
        && page_num.parse::<u32>().ok() != Some(page)
    {
        return Err(SsrError::NotSuccessful);
    }

    let content = loader
        .get("content")
        .filter(|c| c.is_object())
        .ok_or(SsrError::MissingPayload("content"))?;
    if content.get("isSuccess").and_then(Value::as_bool) == Some(false) {
        return Err(SsrError::NotSuccessful);
    }
    let rows = content
        .get("rankList")
        .and_then(Value::as_array)
        .ok_or(SsrError::MissingPayload("rankList"))?;

    let mut out = Vec::with_capacity(rows.len());
    let mut seen = HashSet::new();
    for row in rows {
        let series_id = first_str(row, &["seriesId", "id"]);
        if series_id.is_empty() || !crate::is_numeric_id(&series_id) {
            continue;
        }
        if !seen.insert(series_id.clone()) {
            continue;
        }
        let title = str_of(row, "title");
        if title.trim().is_empty() {
            continue;
        }
        let rank = int_of(row, "rank").unwrap_or(0).max(0) as u32;
        let tags: Vec<String> = row
            .get("tags")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        out.push(RankingRow {
            series_id,
            title,
            cover: cover_path_of(row.get("cover").unwrap_or(&Value::Null)),
            heat: str_of(row, "heatText"),
            score: str_of(row, "scoreText")
                .trim_start_matches("评分")
                .to_owned(),
            description: str_of(row, "description"),
            tags,
            rank,
        });
    }
    if out.is_empty() {
        return Err(SsrError::NoItems);
    }
    Ok(out)
}

/// 从**渲染后的 HTML** 解析榜单。
///
/// ## 为什么需要这条路
///
/// 榜单页的 `loaderData["rank_xxx/page"].content` 实测是**空对象**——
/// 条目由客户端 hydration 后插入。但服务端同时把完整条目渲染进了 DOM：
///
/// ```html
/// <ol aria-label="红果热播榜">
///   <li><article aria-labelledby="rank-title-{seriesId}">
///     <a aria-label="查看{标题}" href="/detail?series_id={id}">
///       <img src="{封面}">
///     </a>
///     ... {rank} {标题} {热度} {标签}
/// </article></li>
/// ```
///
/// 所以「content 为空」不等于「没有榜单」，必须再试一次 DOM。
pub fn parse_ranking_html(html: &str, page: u32) -> Result<Vec<RankingRow>, SsrError> {
    let document = scraper::Html::parse_document(html);
    // 每条是一个带 `rank-title-` 标注的 article。
    let article_selector =
        scraper::Selector::parse("article[aria-labelledby^='rank-title-']")
            .map_err(|_| SsrError::MissingPayload("article"))?;
    let mut rows = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for article in document.select(&article_selector) {
        let label = article.value().attr("aria-labelledby").unwrap_or("");
        let series_id = match label.strip_prefix("rank-title-") {
            Some(id) if crate::is_numeric_id(id) => id.to_owned(),
            _ => continue,
        };
        if !seen.insert(series_id.clone()) {
            continue;
        }
        let text = article.text().collect::<Vec<_>>().join(" ");
        let text = text.split_whitespace().collect::<Vec<_>>().join(" ");

        // 标题与封面来自「查看 X」链接。
        let link_selector = scraper::Selector::parse("a[aria-label^='查看']")
            .map_err(|_| SsrError::MissingPayload("link"))?;
        let (title, cover) = article
            .select(&link_selector)
            .next()
            .map(|link| {
                let title = link
                    .value()
                    .attr("aria-label")
                    .unwrap_or("")
                    .trim_start_matches("查看")
                    .trim()
                    .to_owned();
                let img_selector = scraper::Selector::parse("img").expect("static selector");
                let cover = link
                    .select(&img_selector)
                    .next()
                    .and_then(|img| img.value().attr("src"))
                    .unwrap_or("")
                    .to_owned();
                (title, cover)
            })
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }

        // 名次：区块开头的那串纯数字。
        let rank = text
            .split_whitespace()
            .find_map(|token| token.parse::<u32>().ok())
            .unwrap_or(0);

        let tags = extract_tags(article, &title);
        rows.push(RankingRow {
            series_id,
            title,
            cover,
            heat: extract_heat(&text),
            score: String::new(),
            description: String::new(),
            tags,
            rank,
        });
    }
    if rows.is_empty() {
        return Err(SsrError::NoItems);
    }
    // 名次缺失时按出现顺序补。
    for (index, row) in rows.iter_mut().enumerate() {
        if row.rank == 0 {
            row.rank = (index + 1) as u32 + (page.saturating_sub(1)) * 20;
        }
    }
    Ok(rows)
}

/// 从文本里提取 `9200万热度` 这类指标。
fn extract_heat(text: &str) -> String {
    static PATTERN: once_cell::sync::Lazy<regex::Regex> = once_cell::sync::Lazy::new(|| {
        regex::Regex::new(r"([0-9]+(?:\.[0-9]+)?[万亿]?\s*热度)").expect("valid")
    });
    PATTERN
        .captures(text)
        .and_then(|caps| caps.get(1))
        .map(|m| m.as_str().split_whitespace().collect::<String>())
        .unwrap_or_default()
}

/// 从 article 里提取标签（短文本 span，**排除标题**）。
///
/// 标题本身也常裹在 `<span>` 里，只按文本长度过滤会把它误收成标签——
/// 故先收集标题文本，命中即跳过。
fn extract_tags(article: scraper::ElementRef<'_>, title: &str) -> Vec<String> {
    let Ok(selector) = scraper::Selector::parse("span") else {
        return Vec::new();
    };
    let mut tags = Vec::new();
    for span in article.select(&selector) {
        let text = span.text().collect::<String>();
        let trimmed = text.trim();
        // 标签是 2~8 字的中文短语；标题/热度/名次/集数都不算。
        if trimmed.is_empty()
            || trimmed == title
            || trimmed.chars().count() > 8
            || trimmed.chars().any(|c| c.is_ascii_digit())
            || trimmed.contains("热度")
            || trimmed.contains('集')
        {
            continue;
        }
        if !tags.iter().any(|t: &String| t == trimmed) {
            tags.push(trimmed.to_owned());
        }
        if tags.len() == 4 {
            break;
        }
    }
    tags
}

/// 封面字段可能是字符串、对象或数组，统一取出路径。
fn cover_path_of(value: &Value) -> String {
    match value {
        Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() || trimmed.len() > 8192 {
                return String::new();
            }
            if let Some(rest) = trimmed.strip_prefix("//") {
                return format!("https:{rest}");
            }
            trimmed.to_owned()
        }
        Value::Object(map) => {
            for key in [
                "url",
                "src",
                "path",
                "cover",
                "coverUrl",
                "cover_url",
                "image",
                "poster",
            ] {
                if let Some(inner) = map.get(key) {
                    let found = cover_path_of(inner);
                    if !found.is_empty() {
                        return found;
                    }
                }
            }
            String::new()
        }
        Value::Array(items) => items
            .iter()
            .map(cover_path_of)
            .find(|s| !s.is_empty())
            .unwrap_or_default(),
        _ => String::new(),
    }
}

/// 把相对封面路径补成绝对 URL。
pub fn absolutize_cover(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return trimmed.to_owned();
    }
    if trimmed.starts_with("//") {
        return format!("https:{trimmed}");
    }
    format!(
        "{}/{}",
        crate::WEB_BASE,
        trimmed.trim_start_matches('/')
    )
}

/// 榜单行 → 领域模型。
pub fn ranking_row_to_drama(row: &RankingRow) -> Drama {
    Drama {
        id: DramaId::new(SourceId::new(crate::SOURCE_ID), row.series_id.clone()),
        title: row.title.clone(),
        cover: absolutize_cover(&row.cover),
        category_id: String::new(),
        category_name: row.tags.first().cloned().unwrap_or_default(),
        episode_count: 0,
        accessible_episodes: 0,
        summary: row.description.clone(),
        tags: row.tags.clone(),
        status: DramaStatus::Finished,
        vip: VipState::Unknown,
        metric: row.heat.clone(),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use serde_json::json;

    fn wrap(loader: Value) -> Value {
        json!({ "loaderData": loader })
    }

    #[test]
    fn extracts_router_data_with_nested_braces() {
        // 简介里含 `}`，括号匹配必须跳过字符串内容。
        let html = r#"<html><script>window._ROUTER_DATA = {"a":"x}y{z","b":{"c":1}}</script></html>"#;
        let data = extract_router_data(html).expect("extract");
        assert_eq!(data["a"], "x}y{z");
        assert_eq!(data["b"]["c"], 1);
    }

    #[test]
    fn extracts_router_data_with_escaped_quotes() {
        let html = r#"<script>_ROUTER_DATA = {"a":"say \"hi\"","b":2}</script>"#;
        let data = extract_router_data(html).expect("extract");
        assert_eq!(data["b"], 2);
    }

    #[test]
    fn missing_router_data_is_an_error() {
        assert_eq!(
            extract_router_data("<html>nothing</html>").unwrap_err(),
            SsrError::NoRouterData
        );
    }

    #[test]
    fn unbalanced_router_data_is_an_error() {
        assert_eq!(
            extract_router_data(r#"_ROUTER_DATA = {"a":1"#).unwrap_err(),
            SsrError::UnbalancedRouterData
        );
    }

    #[test]
    fn finds_payload_by_signature_not_key_name() {
        // 键名故意用站点实际会变的形态。
        let data = wrap(json!({
            "category_$": { "recommendList": [] },
            "other": { "x": 1 }
        }));
        assert!(find_payload(&data, "recommendList").is_some());
        assert!(find_payload(&data, "nope").is_none());
    }

    #[test]
    fn finds_payload_nested_one_level() {
        let data = wrap(json!({
            "route": { "inner": { "searchList": [] } }
        }));
        assert!(find_payload(&data, "searchList").is_some());
    }

    #[test]
    fn parses_catalog() {
        let data = wrap(json!({
            "category_$": {
                "recommendList": [
                    {
                        "series_id": "800001",
                        "series_name": "剧一",
                        "series_cover": "https://cdn/x.jpg",
                        "episode_cnt": 80,
                        "accessible_episode_cnt": 3,
                        "series_status": 1,
                        "pay_type": 0,
                        "tags": ["都市", {"name": "甜宠"}],
                        "category_list": [{"category_id": "7", "name": "真人剧"}]
                    },
                    { "series_id": "" }
                ],
                "pagination": { "pageNum": 1, "totalPages": 5 }
            }
        }));
        let parsed = parse_catalog(&data).expect("parse");
        assert_eq!(parsed.items.len(), 1, "empty id must be dropped");
        let drama = &parsed.items[0];
        assert_eq!(drama.title, "剧一");
        assert_eq!(drama.episode_count, 80);
        assert_eq!(drama.accessible_episodes, 3);
        assert_eq!(drama.status, DramaStatus::Ongoing);
        assert_eq!(drama.vip, VipState::Free);
        assert_eq!(drama.tags, vec!["都市", "甜宠"]);
        assert_eq!(drama.category_name, "真人剧");
        assert!(parsed.has_more);
    }

    #[test]
    fn missing_pay_type_is_unknown_vip_not_free() {
        let data = wrap(json!({
            "p": { "recommendList": [{ "series_id": "1", "series_name": "x" }],
                   "pagination": { "pageNum": 1, "totalPages": 1 } }
        }));
        let parsed = parse_catalog(&data).expect("parse");
        // 关键：缺失 ≠ 免费。
        assert_eq!(parsed.items[0].vip, VipState::Unknown);
    }

    #[test]
    fn catalog_is_success_false_is_an_error() {
        let data = wrap(json!({ "p": { "recommendList": [], "isSuccess": false } }));
        assert_eq!(parse_catalog(&data).unwrap_err(), SsrError::NotSuccessful);
    }

    #[test]
    fn last_page_has_no_more() {
        let data = wrap(json!({
            "p": { "recommendList": [{ "series_id": "1", "series_name": "x" }],
                   "pagination": { "pageNum": 5, "totalPages": 5 } }
        }));
        assert!(!parse_catalog(&data).expect("parse").has_more);
    }

    #[test]
    fn parses_search_and_checks_query_echo() {
        let data = wrap(json!({
            "search_(keyword)/page": {
                "isSuccess": true,
                "query": "都市",
                "searchList": [
                    { "video_data": { "series_id": "1", "series_name": "都市剧" } },
                    { "video_data": { "series_id": "2", "series_name": "甜宠剧" } }
                ],
                "totalCount": 2
            }
        }));
        let parsed = parse_search(&data, "都市").expect("parse");
        assert_eq!(parsed.items.len(), 2);
        assert_eq!(parsed.total, 2);

        // 回显不一致 → 不能冒充。
        assert_eq!(
            parse_search(&data, "甜宠").unwrap_err(),
            SsrError::NotSuccessful
        );
    }

    #[test]
    fn parses_detail_with_episodes() {
        let data = wrap(json!({
            "detail_page": {
                "seriesDetail": {
                    "series_id": "800001",
                    "series_name": "剧一",
                    "vid_list": ["9001", "9002", "9003"],
                    "accessible_episode_cnt": 2
                }
            }
        }));
        let parsed = parse_detail(&data, "800001").expect("parse");
        assert_eq!(parsed.episodes.len(), 3);
        assert_eq!(parsed.episodes[0].vid.as_deref(), Some("9001"));
        assert_eq!(parsed.episodes[0].title, "第1集");
        // 前两集可播，第三集锁定。
        assert!(!parsed.episodes[0].locked);
        assert!(!parsed.episodes[1].locked);
        assert!(parsed.episodes[2].locked);
    }

    #[test]
    fn detail_identity_mismatch_is_rejected() {
        let data = wrap(json!({
            "detail_page": { "seriesDetail": { "series_id": "999", "series_name": "别的剧",
                                              "vid_list": ["1"] } }
        }));
        // 请求 800001 却返回 999：必须报错而不是把 999 当成用户的剧。
        assert_eq!(
            parse_detail(&data, "800001").unwrap_err(),
            SsrError::NotSuccessful
        );
    }

    #[test]
    fn detail_without_episodes_is_an_error() {
        let data = wrap(json!({
            "detail_page": { "seriesDetail": { "series_id": "1", "series_name": "x", "vid_list": [] } }
        }));
        assert_eq!(parse_detail(&data, "1").unwrap_err(), SsrError::NoItems);
    }

    #[test]
    fn parses_recommend_deduped() {
        let data = wrap(json!({
            "home": {
                "homeSections": [
                    { "video_list": [{ "series_id": "1", "series_name": "a" },
                                     { "series_id": "2", "series_name": "b" }] },
                    { "video_list": [{ "series_id": "1", "series_name": "a" }] }
                ]
            }
        }));
        let items = parse_recommend(&data).expect("parse");
        assert_eq!(items.len(), 2, "duplicates must be dropped");
    }

    #[test]
    fn parses_suggest_deduped_and_capped() {
        let body = json!({
            "suggest_list": [
                { "name": "都市" },
                { "name": "都市" },
                { "name": "甜宠" },
                { "name": "  " }
            ]
        });
        assert_eq!(parse_suggest(&body, 10), vec!["都市", "甜宠"]);
        assert_eq!(parse_suggest(&body, 1), vec!["都市"]);
    }

    #[test]
    fn suggest_reads_nested_data() {
        let body = json!({ "data": { "suggest_list": [{ "name": "x" }] } });
        assert_eq!(parse_suggest(&body, 10), vec!["x"]);
    }

    #[test]
    fn parses_ranking() {
        let data = wrap(json!({
            "rank_hot-drama/page": {
                "pageNum": "1",
                "content": {
                    "isSuccess": true,
                    "rankList": [
                        { "seriesId": "1", "title": "第一名", "rank": 1, "heatText": "12.3万热度",
                          "scoreText": "评分9.1", "tags": ["都市"], "cover": "upload/x.jpg" },
                        { "seriesId": "1", "title": "重复", "rank": 2 },
                        { "seriesId": "2", "title": "第二名", "rank": 2 }
                    ],
                    "pagination": { "pageNum": 1, "totalPages": 3 }
                }
            }
        }));
        let rows = parse_ranking(&data, "hot-drama", 1).expect("parse");
        assert_eq!(rows.len(), 2, "duplicate seriesId dropped");
        assert_eq!(rows[0].title, "第一名");
        assert_eq!(rows[0].heat, "12.3万热度");
        assert_eq!(rows[0].score, "9.1", "评分 prefix stripped");
        assert_eq!(rows[0].cover, "upload/x.jpg");

        let drama = ranking_row_to_drama(&rows[0]);
        assert_eq!(drama.cover, format!("{}/upload/x.jpg", crate::WEB_BASE));
    }

    #[test]
    fn ranking_page_mismatch_is_rejected() {
        let data = wrap(json!({
            "rank_hot-drama/page": {
                "pageNum": "3",
                "content": { "isSuccess": true, "rankList": [] }
            }
        }));
        assert_eq!(
            parse_ranking(&data, "hot-drama", 1).unwrap_err(),
            SsrError::NotSuccessful
        );
    }

    #[test]
    fn parses_ranking_from_rendered_html() {
        // 实测页面的结构缩影：content 为空，条目只在 DOM 里。
        let html = r#"
        <ol aria-label="红果热播榜">
          <li><article aria-labelledby="rank-title-111">
            <a aria-label="查看甲剧" href="/detail?series_id=111">
              <picture><img src="https://cdn/a.jpg"></picture>
            </a>
            <span>1</span><span>甲剧</span><span>9200万热度</span><span>都市</span>
          </article></li>
          <li><article aria-labelledby="rank-title-222">
            <a aria-label="查看乙剧" href="/detail?series_id=222">
              <img src="https://cdn/b.jpg">
            </a>
            <span>2</span><span>乙剧</span><span>7287万热度</span><span>甜宠</span>
          </article></li>
        </ol>"#;
        let rows = parse_ranking_html(html, 1).expect("parse");
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].series_id, "111");
        assert_eq!(rows[0].title, "甲剧");
        assert_eq!(rows[0].cover, "https://cdn/a.jpg");
        assert_eq!(rows[0].rank, 1);
        assert_eq!(rows[0].heat, "9200万热度");
        assert_eq!(rows[0].tags, vec!["都市"]);
        assert_eq!(rows[1].rank, 2);
    }

    #[test]
    fn ranking_html_rejects_non_numeric_ids() {
        let html = r#"<article aria-labelledby="rank-title-notanid">
            <a aria-label="查看X"><img src="c.jpg"></a><span>1</span>
        </article>"#;
        assert_eq!(
            parse_ranking_html(html, 1).unwrap_err(),
            SsrError::NoItems
        );
    }

    #[test]
    fn ranking_html_fills_missing_rank_by_order() {
        // 页面没有名次数字时按顺序补，且第二页要偏移 20。
        let html = r#"
        <article aria-labelledby="rank-title-1"><a aria-label="查看A"><img src="a.jpg"></a></article>
        <article aria-labelledby="rank-title-2"><a aria-label="查看B"><img src="b.jpg"></a></article>"#;
        let rows = parse_ranking_html(html, 2).expect("parse");
        assert_eq!(rows[0].rank, 21);
        assert_eq!(rows[1].rank, 22);
    }

    #[test]
    fn cover_absolutization() {
        assert_eq!(
            absolutize_cover("upload/a.jpg"),
            format!("{}/upload/a.jpg", crate::WEB_BASE)
        );
        assert_eq!(absolutize_cover("//cdn/x.jpg"), "https://cdn/x.jpg");
        assert_eq!(absolutize_cover("https://x/y.jpg"), "https://x/y.jpg");
        assert_eq!(absolutize_cover("  "), "");
    }

    #[test]
    fn cover_path_from_object_and_array() {
        assert_eq!(cover_path_of(&json!({"url": "a.jpg"})), "a.jpg");
        assert_eq!(cover_path_of(&json!(["", "b.jpg"])), "b.jpg");
        assert_eq!(cover_path_of(&json!(42)), "");
    }
}
