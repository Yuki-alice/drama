//! 弹幕：取数、解析、表情展开。
//!
//! ## 分段模型
//!
//! 弹幕按时间窗取：`[start, next)` 左闭右开，`next` 由上游
//! `extra.next_query_danmaku_list_time` 给出。前端拿一页播一页，
//! 播完再用 `nextMs` 发起下一次请求。
//!
//! ## 解析纪律
//!
//! - `status` 必须是**字符串** `"1"`——上游数字与字符串混用，按数字判会漏；
//! - 窗口半开：`position < start` 或 `position >= next` 都丢弃；
//! - 文本上限 180 **字符**（不按字节），且不拆开 emoji 序列；
//! - 单页上限 90 条。
//!
//! ## 表情
//!
//! `[笑哭]` 这类短码在服务端不下发图片，客户端自己展开成 emoji。
//! 截断时必须**避让** `\uFE0F`（变体选择符）与 `\u200D`（零宽连接符），
//! 否则会把 `👍🏻` 截成半个字符。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::Value;

use drama_types::{DanmakuItem, DanmakuPage};

/// 弹幕最大时间跨度（毫秒）。
pub const DANMAKU_MAX_DURATION_MS: i64 = 24 * 60 * 60 * 1000;
/// 单页条数上限。
pub const PAGE_LIMIT: usize = 90;
/// 文本长度上限（字符）。
pub const TEXT_LIMIT: usize = 180;

/// 缓存 TTL：成功 5 分钟，失败 15 秒。
const CACHE_TTL_OK: Duration = Duration::from_secs(5 * 60);
const CACHE_TTL_ERR: Duration = Duration::from_secs(15);
/// 缓存条目上限。
const CACHE_MAX: usize = 128;

/// 弹幕解析错误。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DanmakuError {
    #[error("弹幕请求参数无效")]
    InvalidParams,
    #[error("弹幕时间范围无效")]
    InvalidRange,
    #[error("红果弹幕时间段格式无效")]
    BadEnvelope,
}

/// 校验请求参数。
pub fn validate(series_id: &str, vid: &str, start_ms: i64, end_ms: i64) -> Result<(), DanmakuError> {
    if !crate::is_numeric_id(series_id) || !crate::is_numeric_id(vid) {
        return Err(DanmakuError::InvalidParams);
    }
    if start_ms < 0 || end_ms <= start_ms || end_ms > DANMAKU_MAX_DURATION_MS {
        return Err(DanmakuError::InvalidRange);
    }
    Ok(())
}

/// 缓存条目（错误也缓存：失败请求 15 秒内不重试，避免打爆接口）。
#[derive(Debug, Clone)]
pub struct CacheEntry {
    page: Option<DanmakuPage>,
    err: Option<String>,
    expires: Instant,
}

impl CacheEntry {
    /// 缓存的成功页。
    pub fn cached_page(&self) -> Option<DanmakuPage> {
        self.page.clone()
    }

    /// 缓存的错误信息。
    pub fn cached_error(&self) -> Option<String> {
        self.err.clone()
    }
}

static CACHE: once_cell::sync::Lazy<Mutex<HashMap<String, CacheEntry>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(HashMap::new()));

fn cache_key(series_id: &str, vid: &str, start_ms: i64, end_ms: i64) -> String {
    format!("{series_id}:{vid}:{start_ms}:{end_ms}")
}

/// 读缓存。
pub fn cache_get(series_id: &str, vid: &str, start_ms: i64, end_ms: i64) -> Option<CacheEntry> {
    let key = cache_key(series_id, vid, start_ms, end_ms);
    let mut guard = CACHE.lock().expect("danmaku cache poisoned");
    match guard.get(&key) {
        Some(entry) if entry.expires > Instant::now() => Some(entry.clone()),
        Some(_) => {
            guard.remove(&key);
            None
        }
        None => None,
    }
}

/// 写缓存。
pub fn cache_put(
    series_id: &str,
    vid: &str,
    start_ms: i64,
    end_ms: i64,
    result: &Result<DanmakuPage, String>,
) {
    let key = cache_key(series_id, vid, start_ms, end_ms);
    let mut guard = CACHE.lock().expect("danmaku cache poisoned");
    if guard.len() >= CACHE_MAX && !guard.contains_key(&key) {
        // 满了整表清空（128 条的重建成本远低于维护 LRU）。
        guard.clear();
    }
    let (page, err, ttl) = match result {
        Ok(page) => (Some(page.clone()), None, CACHE_TTL_OK),
        Err(e) => (None, Some(e.clone()), CACHE_TTL_ERR),
    };
    guard.insert(
        key,
        CacheEntry {
            page,
            err,
            expires: Instant::now() + ttl,
        },
    );
}

/// 清空缓存（测试与设置变更用）。
pub fn cache_clear() {
    CACHE.lock().expect("danmaku cache poisoned").clear();
}

/// 构造弹幕请求体。
///
/// 字段名与值逐字对齐参照实现；`group_type: 30` 与 `comment_type: 20`
/// 是弹幕频道的标识，改了就拿不到数据。
pub fn request_body(series_id: &str, vid: &str, start_ms: i64, end_ms: i64) -> Value {
    serde_json::json!({
        "comment_source": 601,
        "server_channel": 1000,
        "group_id": vid,
        "group_type": 30,
        "comment_type": 20,
        "sort": 1,
        "count": PAGE_LIMIT,
        "cursor": "",
        "aid": 8662,
        "compliance_status": 0,
        "business_param": {
            "book_id": series_id,
            "start_offset_time": start_ms,
            "playlet_item_duration": end_ms,
            "need_danmaku_guide_type": [1, 3, 4, 2],
        },
    })
}

/// 解析弹幕响应。
pub fn parse(
    result: &Value,
    vid: &str,
    start_ms: i64,
    end_ms: i64,
) -> Result<DanmakuPage, DanmakuError> {
    let data = result.get("data").ok_or(DanmakuError::BadEnvelope)?;
    let rows = data
        .get("data_list")
        .and_then(Value::as_array)
        .ok_or(DanmakuError::BadEnvelope)?;

    // `next` 必须存在且落在 (start, MAX] 内；`<= start` 说明上游没推进游标。
    let extra = data.get("extra").ok_or(DanmakuError::BadEnvelope)?;
    let next_raw = extra
        .get("next_query_danmaku_list_time")
        .and_then(|v| match v {
            Value::String(s) => s.parse::<i64>().ok(),
            Value::Number(n) => n.as_i64(),
            _ => None,
        })
        .ok_or(DanmakuError::BadEnvelope)?;
    if next_raw <= start_ms || next_raw > DANMAKU_MAX_DURATION_MS {
        return Err(DanmakuError::BadEnvelope);
    }
    let next = next_raw.min(end_ms);

    // 总数是**全片**弹幕数（在 `common_list_info.cursor` 的 JSON 字符串里）。
    let total = data
        .get("common_list_info")
        .and_then(|c| c.get("cursor"))
        .and_then(Value::as_str)
        .filter(|s| s.len() <= 8192)
        .and_then(|s| serde_json::from_str::<Value>(s).ok())
        .and_then(|c| c.get("danmaku_count").and_then(Value::as_i64))
        .filter(|t| *t >= 0)
        .unwrap_or(0);

    let mut items: Vec<DanmakuItem> = Vec::with_capacity(rows.len().min(PAGE_LIMIT));
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let Some(comment) = row.get("comment") else {
            continue;
        };
        let common = comment.get("common").unwrap_or(&Value::Null);
        // group_id 必须匹配本集；status 必须是字符串 "1"。
        if common.get("group_id").and_then(Value::as_str) != Some(vid)
            || common.get("status").and_then(Value::as_str) != Some("1")
        {
            continue;
        }
        let position = comment
            .get("expand")
            .and_then(|e| e.get("offset_time"))
            .and_then(|v| match v {
                Value::String(s) => s.parse::<i64>().ok(),
                Value::Number(n) => n.as_i64(),
                _ => None,
            });
        let Some(position) = position else {
            continue;
        };
        let raw_text = common
            .get("content")
            .and_then(|c| c.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let text = sanitize_text(raw_text);
        let id = comment
            .get("comment_id")
            .and_then(Value::as_str)
            .unwrap_or("");
        if position < start_ms
            || position >= next
            || text.is_empty()
            || id.is_empty()
            || id.len() > 120
            || !seen.insert(id.to_owned())
        {
            continue;
        }
        items.push(DanmakuItem {
            id: id.to_owned(),
            text,
            time_ms: position,
        });
        if items.len() == PAGE_LIMIT {
            break;
        }
    }
    items.sort_by_key(|item| item.time_ms);

    Ok(DanmakuPage {
        episode_id: vid.to_owned(),
        items,
        start_ms,
        next_ms: next,
        total,
    })
}

/// 清洗文本：控制字符与 `\u2028`/`\u2029` 换成空格，展开表情短码，超长截断。
fn sanitize_text(raw: &str) -> String {
    let mapped: String = raw
        .chars()
        .map(|c| {
            if c.is_control() || c == '\u{2028}' || c == '\u{2029}' {
                ' '
            } else {
                c
            }
        })
        .collect();
    let expanded = expand_emoji(mapped.trim());
    truncate_text(&expanded, TEXT_LIMIT)
}

/// 把 `[笑哭]` 这类短码展开成 emoji；查不到的原样保留。
///
/// 短码是 `[` + 1..=10 个非 `[`/`]`/空白 字符 + `]`。查找按小写匹配。
pub fn expand_emoji(text: &str) -> String {
    if !text.contains('[') {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('[') {
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        match short_code_end(tail) {
            Some(end) => {
                let token = &tail[..end];
                let key = token.to_lowercase();
                out.push_str(emoji_table().get(&key).copied().unwrap_or(token));
                rest = &tail[end..];
            }
            None => {
                out.push('[');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// 找短码的结束位置（含 `]`，字节偏移）；不构成短码返回 `None`。
fn short_code_end(tail: &str) -> Option<usize> {
    for (len, (index, c)) in tail.char_indices().skip(1).enumerate() {
        if c == ']' {
            return if len == 0 || len > 10 {
                None
            } else {
                Some(index + c.len_utf8())
            };
        }
        if c.is_whitespace() || c == '[' {
            return None;
        }
    }
    None
}

/// 截断文本到 `limit` 字符，不拆开 emoji 序列。
///
/// emoji 由「基础字符 + 变体选择符（\uFE0F/\uFE0E）+ 零宽连接符（\u200D）」组成，
/// 硬截会切在序列中间，渲染出豆腐块。
pub fn truncate_text(text: &str, limit: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= limit {
        return text.to_owned();
    }
    let mut cut = limit;
    loop {
        let mut retreated = false;
        // 变体选择符跟着前一个字符走。
        if cut < chars.len() && (chars[cut] == '\u{FE0F}' || chars[cut] == '\u{FE0E}') {
            cut -= 1;
            retreated = true;
        }
        // 零宽连接符连接前后两个字符，不能成为边界。
        if cut > 0 && chars[cut - 1] == '\u{200D}' {
            cut -= 1;
            retreated = true;
        }
        if !retreated || cut == 0 {
            break;
        }
    }
    let mut out: String = chars[..cut].iter().collect();
    out.push('…');
    out
}

/// 表情表（54 项，逐字对齐参照实现）。
///
/// `OnceLock` + 惰性构建：只在第一次用到时建表。
fn emoji_table() -> &'static HashMap<String, &'static str> {
    static TABLE: std::sync::OnceLock<HashMap<String, &'static str>> =
        std::sync::OnceLock::new();
    TABLE.get_or_init(|| {
        HashMap::from([
            ("[笑哭]", "😂"),
            ("[大笑]", "😆"),
            ("[微笑]", "🙂"),
            ("[呲牙]", "😁"),
            ("[偷笑]", "🤭"),
            ("[捂脸]", "🤦"),
            ("[害羞]", "😊"),
            ("[调皮]", "😜"),
            ("[爱慕]", "😍"),
            ("[色]", "😍"),
            ("[酷]", "😎"),
            ("[白眼]", "🙄"),
            ("[抠鼻]", "🤨"),
            ("[鄙视]", "😒"),
            ("[思考]", "🤔"),
            ("[什么]", "🤔"),
            ("[惊讶]", "😲"),
            ("[尴尬]", "😅"),
            ("[汗]", "😅"),
            ("[闭嘴]", "🤐"),
            ("[嘘]", "🤫"),
            ("[困]", "😴"),
            ("[睡]", "😴"),
            ("[哈欠]", "🥱"),
            ("[流泪]", "😢"),
            ("[大哭]", "😭"),
            ("[委屈]", "🥺"),
            ("[可怜]", "🥺"),
            ("[没看够]", "🥺"),
            ("[抓狂]", "😫"),
            ("[发怒]", "😡"),
            ("[吐]", "🤮"),
            ("[打脸]", "🤦"),
            ("[灵光一闪]", "💡"),
            ("[赞]", "👍"),
            ("[强]", "👍"),
            ("[给力]", "👍"),
            ("[弱]", "👎"),
            ("[鼓掌]", "👏"),
            ("[ok]", "👌"),
            ("[胜利]", "✌️"),
            ("[耶]", "✌️"),
            ("[奋斗]", "💪"),
            ("[加油]", "💪"),
            ("[威武]", "💪"),
            ("[抱抱]", "🤗"),
            ("[比心]", "🫰"),
            ("[心]", "❤️"),
            ("[爱心]", "❤️"),
            ("[送花]", "🌹"),
            ("[玫瑰]", "🌹"),
            ("[鲜花]", "💐"),
            ("[钱]", "💰"),
            ("[狗头]", "🐶"),
            ("[doge]", "🐶"),
        ])
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v))
        .collect()
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use serde_json::json;

    fn envelope(rows: Value, next: i64, total: i64) -> Value {
        json!({
            "data": {
                "data_list": rows,
                "extra": { "next_query_danmaku_list_time": next.to_string() },
                "common_list_info": {
                    "cursor": format!("{{\"danmaku_count\":{total}}}")
                }
            }
        })
    }

    fn row(id: &str, text: &str, offset: i64) -> Value {
        json!({
            "comment": {
                "comment_id": id,
                "common": { "group_id": "9001", "status": "1", "content": { "text": text } },
                "expand": { "offset_time": offset.to_string() }
            }
        })
    }

    #[test]
    fn validate_rejects_bad_params() {
        assert!(validate("800001", "9001", 0, 30_000).is_ok());
        assert_eq!(
            validate("", "9001", 0, 30_000).unwrap_err(),
            DanmakuError::InvalidParams
        );
        assert_eq!(
            validate("abc", "9001", 0, 30_000).unwrap_err(),
            DanmakuError::InvalidParams
        );
        // 范围：start < end 且 end <= 24h。
        assert_eq!(
            validate("1", "9001", 30_000, 30_000).unwrap_err(),
            DanmakuError::InvalidRange
        );
        assert_eq!(
            validate("1", "9001", 30_000, 20_000).unwrap_err(),
            DanmakuError::InvalidRange
        );
        assert_eq!(
            validate("1", "9001", 0, DANMAKU_MAX_DURATION_MS + 1).unwrap_err(),
            DanmakuError::InvalidRange
        );
    }

    #[test]
    fn parse_extracts_items_sorted() {
        let result = envelope(
            json!([row("b", "第二条", 20_000), row("a", "第一条", 10_000)]),
            30_000,
            250,
        );
        let page = parse(&result, "9001", 0, 30_000).expect("parse");
        assert_eq!(page.items.len(), 2);
        // 按时间排序。
        assert_eq!(page.items[0].text, "第一条");
        assert_eq!(page.items[1].text, "第二条");
        assert_eq!(page.next_ms, 30_000);
        assert_eq!(page.total, 250);
        assert_eq!(page.episode_id, "9001");
    }

    #[test]
    fn parse_filters_out_of_window() {
        let result = envelope(
            json!([
                row("1", "早于窗口", 5_000),
                row("2", "正好在窗口", 0),
                row("3", "等于 next 应丢弃", 30_000),
                row("4", "晚于窗口", 40_000),
            ]),
            30_000,
            0,
        );
        let page = parse(&result, "9001", 0, 30_000).expect("parse");
        // [0, 30) 半开：offset 0 保留，30 000 丢弃。
        assert_eq!(page.items.len(), 2);
        assert!(page.items.iter().any(|i| i.text == "正好在窗口"));
    }

    #[test]
    fn parse_requires_status_string_one() {
        // status 用数字 1（而非字符串）的行必须被丢弃。
        let numeric = json!({
            "comment": {
                "comment_id": "1",
                "common": { "group_id": "9001", "status": 1, "content": { "text": "x" } },
                "expand": { "offset_time": "1000" }
            }
        });
        let result = envelope(json!([numeric]), 30_000, 0);
        assert!(parse(&result, "9001", 0, 30_000)
            .expect("parse")
            .items
            .is_empty());
    }

    #[test]
    fn parse_requires_matching_group_id() {
        let other = json!({
            "comment": {
                "comment_id": "1",
                "common": { "group_id": "9999", "status": "1", "content": { "text": "x" } },
                "expand": { "offset_time": "1000" }
            }
        });
        let result = envelope(json!([other]), 30_000, 0);
        assert!(parse(&result, "9001", 0, 30_000)
            .expect("parse")
            .items
            .is_empty());
    }

    #[test]
    fn parse_dedupes_by_id() {
        let result = envelope(
            json!([row("1", "第一条", 1_000), row("1", "重复", 2_000)]),
            30_000,
            0,
        );
        let page = parse(&result, "9001", 0, 30_000).expect("parse");
        assert_eq!(page.items.len(), 1);
    }

    #[test]
    fn parse_caps_page_size() {
        let rows: Vec<Value> = (0..120)
            .map(|i| row(&format!("id{i}"), &format!("弹幕{i}"), i * 100))
            .collect();
        let result = envelope(json!(rows), 30_000, 0);
        assert_eq!(
            parse(&result, "9001", 0, 30_000).expect("parse").items.len(),
            PAGE_LIMIT
        );
    }

    #[test]
    fn parse_rejects_bad_envelope() {
        assert_eq!(
            parse(&json!({}), "9001", 0, 30_000).unwrap_err(),
            DanmakuError::BadEnvelope
        );
        // next 未前进（<= start）才是非法。
        assert_eq!(
            parse(&envelope(json!([]), 0, 0), "9001", 0, 30_000).unwrap_err(),
            DanmakuError::BadEnvelope
        );
        assert_eq!(
            parse(&envelope(json!([]), 5_000, 0), "9001", 5_000, 30_000).unwrap_err(),
            DanmakuError::BadEnvelope
        );
        // next 缺失。
        assert_eq!(
            parse(&json!({"data": {"data_list": []}}), "9001", 0, 30_000).unwrap_err(),
            DanmakuError::BadEnvelope
        );
        // next 超过 24h 上限。
        assert_eq!(
            parse(&envelope(json!([]), DANMAKU_MAX_DURATION_MS + 1, 0), "9001", 0, 30_000)
                .unwrap_err(),
            DanmakuError::BadEnvelope
        );
    }

    #[test]
    fn next_is_clamped_to_window_end() {
        // 上游给的 next 超过本集时长时被夹住。
        let result = envelope(json!([]), 100_000, 0);
        let page = parse(&result, "9001", 0, 30_000).expect("parse");
        assert_eq!(page.next_ms, 30_000);
    }

    #[test]
    fn expand_emoji_replaces_known_codes() {
        assert_eq!(expand_emoji("前[笑哭]后"), "前😂后");
        assert_eq!(expand_emoji("[ok]"), "👌");
        // 大小写不敏感。
        assert_eq!(expand_emoji("[OK]"), "👌");
        assert_eq!(expand_emoji("[Doge]"), "🐶");
        // 未知短码原样保留。
        assert_eq!(expand_emoji("[未知]"), "[未知]");
        // 没有短码的文本原样返回。
        assert_eq!(expand_emoji("普通文本"), "普通文本");
    }

    #[test]
    fn expand_emoji_rejects_malformed() {
        // 空短码、超长短码、含空白、未闭合。
        assert_eq!(expand_emoji("[]"), "[]");
        assert_eq!(
            expand_emoji(&format!("[{}]", "a".repeat(11))),
            format!("[{}]", "a".repeat(11))
        );
        assert_eq!(expand_emoji("[a b]"), "[a b]");
        assert_eq!(expand_emoji("未闭合[a"), "未闭合[a");
    }

    #[test]
    fn expand_emoji_handles_multiple() {
        assert_eq!(expand_emoji("[赞][赞]"), "👍👍");
        assert_eq!(expand_emoji("a[心]b[钱]c"), "a❤️b💰c");
    }

    #[test]
    fn expand_emoji_treats_multibyte_content() {
        // 中文短码是参照实现的主场景。
        assert_eq!(expand_emoji("[灵光一闪]"), "💡");
    }

    #[test]
    fn truncate_preserves_emoji_sequences() {
        // ❤️ = U+2764 U+FE0F（2 个 char）。
        let text: String = "❤️".repeat(100);
        // limit 是偶数时边界落在基础字符上，不会拆开。
        let truncated = truncate_text(&text, 4);
        assert!(truncated.ends_with('…'));
        assert_eq!(truncated.trim_end_matches('…').chars().count(), 4);
        // 前缀必须是完整的表情对（U+2764 + U+FE0F）。
        for pair in truncated.trim_end_matches('…').chars().collect::<Vec<_>>().chunks(2) {
            assert_eq!(pair.len(), 2, "emoji pair split: {pair:?}");
            assert_eq!(pair[0], '\u{2764}');
            assert_eq!(pair[1], '\u{FE0F}');
        }
    }

    #[test]
    fn truncate_respects_zero_width_joiner() {
        // 👨‍👩‍👧 = 👨 U+200D 👩 U+200D 👧
        let family = "👨\u{200D}👩\u{200D}👧";
        // limit=1：边界在 👨 之后（chars[0] 非 ZWJ），保留 👨。
        assert_eq!(truncate_text(family, 1), "👨…");
        // limit=2：chars[1] 是 ZWJ → 回退一次，只保留 👨。
        // 参照实现回退一次即停（!retreated 即 break），不会继续检查新边界。
        assert_eq!(truncate_text(family, 2), "👨…");
        // limit=3：chars[3] 是 ZWJ 但它**在窗口内**（被保留），
        // chars[2] 是 👩 非 ZWJ，不触发回退——前缀含完整的 👨ZWJ👩 组合。
        assert_eq!(truncate_text(family, 3), "👨\u{200D}👩…");
        // 足够长时保留整个家庭组合。
        assert_eq!(truncate_text(family, 5), family);
    }

    #[test]
    fn truncate_short_text_is_identity() {
        assert_eq!(truncate_text("短文本", 10), "短文本");
    }

    #[test]
    fn sanitize_replaces_control_chars() {
        let result = envelope(json!([row("1", "a\u{2028}b\u{0}c", 1_000)]), 30_000, 0);
        let page = parse(&result, "9001", 0, 30_000).expect("parse");
        assert_eq!(page.items[0].text, "a b c");
    }

    #[test]
    fn cache_roundtrip() {
        cache_clear();
        let page = DanmakuPage::default();
        cache_put("s", "v", 0, 1, &Ok(page.clone()));
        let hit = cache_get("s", "v", 0, 1).expect("hit");
        assert_eq!(hit.page.as_ref().map(|p| p.episode_id.clone()), Some(page.episode_id));
        // 不同参数是不同 key。
        assert!(cache_get("s", "v", 0, 2).is_none());
    }

    #[test]
    fn cache_stores_errors_briefly() {
        cache_clear();
        cache_put("s2", "v", 0, 1, &Err("失败".to_owned()));
        let hit = cache_get("s2", "v", 0, 1).expect("hit");
        assert_eq!(hit.err.as_deref(), Some("失败"));
        assert!(hit.page.is_none());
    }

    #[test]
    fn request_body_shape() {
        let body = request_body("800001", "9001", 1_000, 31_000);
        assert_eq!(body["group_id"], "9001");
        assert_eq!(body["group_type"], 30);
        assert_eq!(body["comment_type"], 20);
        assert_eq!(body["count"], PAGE_LIMIT);
        assert_eq!(body["business_param"]["book_id"], "800001");
        assert_eq!(body["business_param"]["start_offset_time"], 1_000);
        assert_eq!(body["business_param"]["playlet_item_duration"], 31_000);
    }
}
