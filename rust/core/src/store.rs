//! 追剧与观看进度存储（持久化面）。
//!
//! 单文件 JSON（`progress.json`，上限 256 KiB，超限拒绝写入并报错）：
//! 追剧表 + 观看历史（上限 200 条，LRU 淘汰）。Dart 侧只做渲染，
//! 所有读写走本模块；`init` 未调用时退化为纯内存（重启丢失）。

use std::collections::HashMap;
use std::sync::Mutex;

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::source::traits::SourceError;

const MAX_FILE_BYTES: usize = 256 * 1024;
const MAX_HISTORY: usize = 200;

/// 追剧条目。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Follow {
    title: String,
    cover: String,
    episode: u32,
    position_secs: u64,
    duration_secs: u64,
    updated_at_ms: i64,
    /// 总集数（`0` = 未知）。`serde(default)` 保证旧 progress.json 仍可读。
    #[serde(default)]
    total_episode: u32,
}

/// 历史条目。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct HistoryItem {
    id: String,
    episode: u32,
    position_secs: u64,
    duration_secs: u64,
    updated_at_ms: i64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Store {
    follows: HashMap<String, Follow>,
    history: Vec<HistoryItem>,
}

static STORE: Lazy<Mutex<Store>> = Lazy::new(|| Mutex::new(Store::default()));
static LOADED: Lazy<Mutex<bool>> = Lazy::new(|| Mutex::new(false));

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn path() -> Option<std::path::PathBuf> {
    crate::device::data_dir().map(|d| d.join("progress.json"))
}

/// 延迟加载：首次写/读时从文件载入（失败即用空表）。
fn ensure_loaded() {
    if *LOADED.lock().expect("store flag poisoned") {
        return;
    }
    *LOADED.lock().expect("store flag poisoned") = true;
    let Some(path) = path() else { return };
    let Ok(raw) = std::fs::read(&path) else {
        return;
    };
    if raw.len() > MAX_FILE_BYTES {
        return;
    }
    if let Ok(store) = serde_json::from_slice::<Store>(&raw) {
        *STORE.lock().expect("store poisoned") = store;
    }
}

fn persist() -> Result<(), SourceError> {
    let Some(path) = path() else {
        return Ok(());
    };
    let raw = serde_json::to_vec(&*STORE.lock().expect("store poisoned"))
        .map_err(|e| SourceError::Parse(format!("encode store: {e}")))?;
    if raw.len() > MAX_FILE_BYTES {
        return Err(SourceError::Parse("store too large".to_owned()));
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, raw).map_err(|e| SourceError::Parse(format!("write store: {e}")))?;
    Ok(())
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128
}

/// 追剧：新增或更新（缺省标题时保留旧值）。
pub fn follow_put(params: &Value) -> Result<Value, SourceError> {
    let id = params
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if !valid_id(&id) {
        return Err(SourceError::Parse("missing id".to_owned()));
    }
    ensure_loaded();
    let mut store = STORE.lock().expect("store poisoned");
    let entry = store.follows.entry(id.clone()).or_insert(Follow {
        title: String::new(),
        cover: String::new(),
        episode: 1,
        position_secs: 0,
        duration_secs: 0,
        updated_at_ms: 0,
        total_episode: 0,
    });
    if let Some(title) = params.get("title").and_then(Value::as_str)
        && !title.is_empty()
    {
        entry.title = title.chars().take(128).collect();
    }
    if let Some(cover) = params.get("cover").and_then(Value::as_str) {
        entry.cover = cover.chars().take(512).collect();
    }
    if let Some(episode) = params.get("episode").and_then(Value::as_u64) {
        entry.episode = episode.min(100_000) as u32;
    }
    if let Some(position) = params.get("positionSecs").and_then(Value::as_u64) {
        entry.position_secs = position.min(1_000_000);
    }
    if let Some(duration) = params.get("durationSecs").and_then(Value::as_u64) {
        entry.duration_secs = duration.min(1_000_000);
    }
    if let Some(total) = params.get("totalEpisode").and_then(Value::as_u64) {
        entry.total_episode = total.min(100_000) as u32;
    }
    entry.updated_at_ms = now_ms();
    drop(store);
    persist()?;
    Ok(json!({ "id": id }))
}

/// 取消追剧（不存在也算成功，幂等）。
pub fn follow_del(params: &Value) -> Result<Value, SourceError> {
    let id = params.get("id").and_then(Value::as_str).unwrap_or("");
    if !valid_id(id) {
        return Err(SourceError::Parse("missing id".to_owned()));
    }
    ensure_loaded();
    STORE.lock().expect("store poisoned").follows.remove(id);
    persist()?;
    Ok(json!({ "id": id }))
}

/// 追剧列表（按更新时间倒序）。
pub fn follow_list() -> Result<Value, SourceError> {
    ensure_loaded();
    let store = STORE.lock().expect("store poisoned");
    let mut items: Vec<(&String, &Follow)> = store.follows.iter().collect();
    items.sort_by_key(|(_, f)| -f.updated_at_ms);
    Ok(json!({
        "items": items.iter().map(|(id, f)| json!({
            "id": id,
            "title": f.title,
            // 封面地址是**持久化**的，里面记的是上次会话的代理端口；
            // 端口跨会话会变，故读出时改写，让旧记录自愈
            // （Dart 侧因此不必在渲染时逐条解析 URI 改写端口）。
            "cover": crate::covers::rewrite_to_current_port(&f.cover)
                .unwrap_or_else(|| f.cover.clone()),
            "episode": f.episode,
            "positionSecs": f.position_secs,
            "durationSecs": f.duration_secs,
            "totalEpisode": f.total_episode,
            "updatedAtMs": f.updated_at_ms,
        })).collect::<Vec<_>>(),
    }))
}

/// 观看进度上报（同时刷新追剧条目与历史）。
pub fn history_put(params: &Value) -> Result<Value, SourceError> {
    let id = params
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if !valid_id(&id) {
        return Err(SourceError::Parse("missing id".to_owned()));
    }
    let episode = params
        .get("episode")
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .min(100_000) as u32;
    let position = params
        .get("positionSecs")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .min(1_000_000);
    let duration = params
        .get("durationSecs")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .min(1_000_000);
    ensure_loaded();
    let mut store = STORE.lock().expect("store poisoned");
    if let Some(follow) = store.follows.get_mut(&id) {
        follow.episode = episode;
        follow.position_secs = position;
        follow.duration_secs = duration;
        follow.updated_at_ms = now_ms();
    }
    store.history.retain(|h| h.id != id);
    store.history.insert(
        0,
        HistoryItem {
            id: id.clone(),
            episode,
            position_secs: position,
            duration_secs: duration,
            updated_at_ms: now_ms(),
        },
    );
    store.history.truncate(MAX_HISTORY);
    drop(store);
    persist()?;
    Ok(json!({ "id": id }))
}

/// 历史列表（最近在前；传 `id` 则只返回该条）。
pub fn history_get(params: &Value) -> Result<Value, SourceError> {
    ensure_loaded();
    let store = STORE.lock().expect("store poisoned");
    if let Some(id) = params.get("id").and_then(Value::as_str) {
        let item = store.history.iter().find(|h| h.id == id);
        return Ok(json!({
            "item": item.map(|h| json!({
                "id": h.id,
                "episode": h.episode,
                "positionSecs": h.position_secs,
                "durationSecs": h.duration_secs,
                "updatedAtMs": h.updated_at_ms,
            })),
        }));
    }
    Ok(json!({
        "items": store.history.iter().map(|h| json!({
            "id": h.id,
            "episode": h.episode,
            "positionSecs": h.position_secs,
            "durationSecs": h.duration_secs,
            "updatedAtMs": h.updated_at_ms,
        })).collect::<Vec<_>>(),
    }))
}

/// 清空历史（追剧表不动）。
pub fn history_clear() -> Result<Value, SourceError> {
    ensure_loaded();
    STORE.lock().expect("store poisoned").history.clear();
    persist()?;
    Ok(json!({ "cleared": true }))
}

// ── 搜索历史 ─────────────────────────────────────────────────────────────
//
// 独立文件 `search_history.json`（与 `progress.json` 分开：两者生命周期与
// 容量模型都不同，混在一起会让上限互相挤占）。Dart 侧不再用内存列表——
// 重启后最近搜索不该消失。

/// 搜索历史上限（LRU：超出淘汰最旧）。
const MAX_SEARCH_HISTORY: usize = 20;
/// 单词最大长度（防御：超长输入不该进持久化）。
const MAX_KEYWORD_LEN: usize = 64;
/// 搜索历史文件上限。
const MAX_SEARCH_FILE_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SearchTerm {
    keyword: String,
    updated_at_ms: i64,
}

static SEARCH_HISTORY: Lazy<Mutex<Vec<SearchTerm>>> = Lazy::new(|| Mutex::new(Vec::new()));
static SEARCH_LOADED: Lazy<Mutex<bool>> = Lazy::new(|| Mutex::new(false));

fn search_path() -> Option<std::path::PathBuf> {
    crate::device::data_dir().map(|d| d.join("search_history.json"))
}

/// 延迟载入（损坏即用空表）。
fn search_ensure_loaded() {
    if *SEARCH_LOADED.lock().expect("search flag poisoned") {
        return;
    }
    *SEARCH_LOADED.lock().expect("search flag poisoned") = true;
    let Some(path) = search_path() else { return };
    let Ok(raw) = std::fs::read(&path) else {
        return;
    };
    if raw.len() > MAX_SEARCH_FILE_BYTES {
        return;
    }
    if let Ok(terms) = serde_json::from_slice::<Vec<SearchTerm>>(&raw) {
        *SEARCH_HISTORY.lock().expect("search poisoned") = terms;
    }
}

fn search_persist() -> Result<(), SourceError> {
    let Some(path) = search_path() else {
        return Ok(());
    };
    let raw = serde_json::to_vec(&*SEARCH_HISTORY.lock().expect("search poisoned"))
        .map_err(|e| SourceError::Parse(format!("encode search history: {e}")))?;
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, raw)
        .map_err(|e| SourceError::Parse(format!("write search history: {e}")))?;
    Ok(())
}

/// 取参数里的搜索词（trim + 长度裁剪）；空词返回 `None`。
fn search_keyword(params: &Value) -> Option<String> {
    let raw = params.get("keyword").and_then(Value::as_str)?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.chars().take(MAX_KEYWORD_LEN).collect())
}

/// 记录一次搜索：置顶 + 去重 + 截断（LRU）。
pub fn search_history_put(params: &Value) -> Result<Value, SourceError> {
    let Some(keyword) = search_keyword(params) else {
        return Err(SourceError::Parse("missing keyword".to_owned()));
    };
    search_ensure_loaded();
    {
        let mut terms = SEARCH_HISTORY.lock().expect("search poisoned");
        terms.retain(|t| t.keyword != keyword);
        terms.insert(
            0,
            SearchTerm {
                keyword: keyword.clone(),
                updated_at_ms: now_ms(),
            },
        );
        terms.truncate(MAX_SEARCH_HISTORY);
    }
    search_persist()?;
    Ok(json!({ "keyword": keyword }))
}

/// 搜索历史列表（最近的在前）。
pub fn search_history_list() -> Result<Value, SourceError> {
    search_ensure_loaded();
    let terms = SEARCH_HISTORY.lock().expect("search poisoned");
    Ok(json!({
        "items": terms.iter().map(|t| json!({
            "keyword": t.keyword,
            "updatedAtMs": t.updated_at_ms,
        })).collect::<Vec<_>>(),
    }))
}

/// 删除单个搜索词（不存在也算成功，幂等）。
pub fn search_history_del(params: &Value) -> Result<Value, SourceError> {
    let Some(keyword) = search_keyword(params) else {
        return Err(SourceError::Parse("missing keyword".to_owned()));
    };
    search_ensure_loaded();
    SEARCH_HISTORY
        .lock()
        .expect("search poisoned")
        .retain(|t| t.keyword != keyword);
    search_persist()?;
    Ok(json!({ "keyword": keyword }))
}

/// 清空搜索历史。
pub fn search_history_clear() -> Result<Value, SourceError> {
    search_ensure_loaded();
    SEARCH_HISTORY.lock().expect("search poisoned").clear();
    search_persist()?;
    Ok(json!({ "cleared": true }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// store 测试串行化：STORE/LOADED/SEARCH_* 为进程静态，并行跑会互踩。
    fn reset() {
        *STORE.lock().unwrap() = Store::default();
        *LOADED.lock().unwrap() = true;
        *SEARCH_HISTORY.lock().unwrap() = Vec::new();
        *SEARCH_LOADED.lock().unwrap() = true;
    }

    #[test]
    fn follow_crud_and_order() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        follow_put(&json!({"id": "a", "title": "A"})).unwrap();
        follow_put(&json!({"id": "b", "title": "B"})).unwrap();
        let list = follow_list().unwrap();
        let ids: Vec<&str> = list["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&"a") && ids.contains(&"b"));
        follow_del(&json!({"id": "b"})).unwrap();
        let list = follow_list().unwrap();
        assert_eq!(list["items"].as_array().unwrap().len(), 1);
        assert_eq!(list["items"][0]["id"], json!("a"));
        // 幂等删除。
        follow_del(&json!({"id": "nope"})).unwrap();
        reset();
    }

    #[test]
    fn history_put_updates_follow_and_caps_length() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        follow_put(&json!({"id": "a", "title": "A"})).unwrap();
        history_put(&json!({"id": "a", "episode": 3, "positionSecs": 12})).unwrap();
        let list = follow_list().unwrap();
        assert_eq!(list["items"][0]["episode"], json!(3));
        let one = history_get(&json!({"id": "a"})).unwrap();
        assert_eq!(one["item"]["positionSecs"], json!(12));
        assert!(
            history_get(&json!({})).unwrap()["items"]
                .as_array()
                .unwrap()
                .len()
                == 1
        );
        assert!(follow_put(&json!({})).is_err());
        reset();
    }

    #[test]
    fn follow_put_roundtrips_total_episode_and_defaults_to_zero() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        // 显式给总集数 → 原样回读（追剧页据此算进度与「还有未看」）。
        follow_put(&json!({"id": "a", "title": "A", "totalEpisode": 80})).unwrap();
        let list = follow_list().unwrap();
        assert_eq!(list["items"][0]["totalEpisode"], json!(80));

        // 未给总集数 → 0（未知），不臆造。
        follow_put(&json!({"id": "b", "title": "B"})).unwrap();
        let list = follow_list().unwrap();
        let b = list["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["id"] == json!("b"))
            .unwrap();
        assert_eq!(b["totalEpisode"], json!(0));

        // 后续更新未携带该字段时保留旧值（不被重置为 0）。
        follow_put(&json!({"id": "a", "episode": 5})).unwrap();
        let list = follow_list().unwrap();
        let a = list["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["id"] == json!("a"))
            .unwrap();
        assert_eq!(a["totalEpisode"], json!(80));
        assert_eq!(a["episode"], json!(5));
        reset();
    }

    #[test]
    fn search_history_is_lru_deduped_and_bounded() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        search_history_put(&json!({"keyword": "  a  "})).unwrap();
        search_history_put(&json!({"keyword": "b"})).unwrap();
        // 重复搜索置顶（去重），且 trim 后的词才入库。
        search_history_put(&json!({"keyword": "a"})).unwrap();
        let items = search_history_list().unwrap()["items"].clone();
        let words: Vec<&str> = items
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["keyword"].as_str().unwrap())
            .collect();
        assert_eq!(words, vec!["a", "b"], "最近搜索的应置顶且去重：{words:?}");

        // 上限：超出淘汰最旧，只留最新的 MAX_SEARCH_HISTORY 条。
        for i in 0..MAX_SEARCH_HISTORY + 5 {
            search_history_put(&json!({"keyword": format!("k{i}")})).unwrap();
        }
        let count = search_history_list().unwrap()["items"]
            .as_array()
            .unwrap()
            .len();
        assert_eq!(count, MAX_SEARCH_HISTORY, "必须截断到上限，实际 {count}");

        // 删除单个（幂等）。
        search_history_del(&json!({"keyword": "k0"})).unwrap();
        assert!(search_history_del(&json!({"keyword": "nope"})).is_ok());

        // 空词拒绝入库（否则搜索页会出现空白条目）。
        assert!(search_history_put(&json!({"keyword": "   "})).is_err());

        search_history_clear().unwrap();
        assert_eq!(
            search_history_list().unwrap()["items"]
                .as_array()
                .unwrap()
                .len(),
            0
        );
        reset();
    }

    #[test]
    fn total_episode_missing_in_legacy_json_still_loads() {
        // 旧 progress.json 无 totalEpisode 字段：serde(default) 必须兜住，
        // 否则用户升级后追剧表整体反序列化失败。
        let legacy = r#"{"follows":{"a":{"title":"A","cover":"","episode":2,
            "position_secs":5,"duration_secs":0,"updated_at_ms":1}},"history":[]}"#;
        let parsed: Store = serde_json::from_str(legacy).unwrap();
        assert_eq!(parsed.follows["a"].total_episode, 0);
        assert_eq!(parsed.follows["a"].episode, 2);
    }
}
