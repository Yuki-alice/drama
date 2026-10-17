//! 追剧与观看进度。
//!
//! ## 按用户隔离
//!
//! 所有键都带用户前缀：`{user}/{drama_key}`。原实现里这条隔离只有一行代码
//! （`profile.<id>.<key>`），但它决定「换个用户会不会看到别人的追剧」，
//! 值得显式建模。
//!
//! ## 进度合并规则
//!
//! - **位置取新**：同一集重看时进度以最后一次上报为准；
//! - **元数据取并**：标题/封面/集数等字段用「已知优先」合并；
//! - **已读集数是高水位**：只看第 3 集不会把「已看到第 10 集」降级；
//! - **完结后新增集数 → 回到连载**：用户需要知道「我追的剧更新了」。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::atomic::{read_json, write_json_atomic};

/// 文件上限。
const MAX_FILE_BYTES: usize = 8 * 1024 * 1024;
/// 历史条数上限（LRU 淘汰）。
const MAX_HISTORY: usize = 300;
/// 追剧条数上限。
const MAX_FOLLOWS: usize = 20_000;

const SNAPSHOT_VERSION: u32 = 1;

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 追剧条目。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Follow {
    /// `{source}:{source_id}`。
    pub drama_key: String,
    pub title: String,
    #[serde(default)]
    pub cover: String,
    /// 已看到的集号（1-based）。
    #[serde(default)]
    pub episode: u32,
    #[serde(default)]
    pub position_secs: u64,
    #[serde(default)]
    pub duration_secs: u64,
    #[serde(default)]
    pub total_episode: u32,
    /// 已知的最大集数（高水位）。
    #[serde(default)]
    pub known_episodes: u32,
    #[serde(default)]
    pub updated_at_ms: i64,
}

impl Follow {
    /// 是否有未看的新集。
    pub fn has_update(&self) -> bool {
        self.known_episodes > self.episode
    }
}

/// 历史条目。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HistoryItem {
    pub drama_key: String,
    pub title: String,
    #[serde(default)]
    pub cover: String,
    pub episode: u32,
    #[serde(default)]
    pub position_secs: u64,
    #[serde(default)]
    pub duration_secs: u64,
    #[serde(default)]
    pub total_episode: u32,
    pub updated_at_ms: i64,
}

impl HistoryItem {
    /// 观看进度比例（0..=1）。
    pub fn progress(&self) -> f64 {
        if self.duration_secs == 0 {
            return 0.0;
        }
        (self.position_secs as f64 / self.duration_secs as f64).clamp(0.0, 1.0)
    }
}

/// 落盘快照。
///
/// `Default` 手写而非 derive：derive 出来的 `version` 是 `0`，
/// 写出去的快照下次加载会被判成「版本不受支持」而整份丢弃——
/// 表现为「重启后追剧列表全空」。让类型自己保证 version 正确。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Snapshot {
    version: u32,
    /// `{user}` → `{drama_key}` → 追剧。
    follows: HashMap<String, HashMap<String, Follow>>,
    /// `{user}` → 历史列表（按 updated_at 降序）。
    history: HashMap<String, Vec<HistoryItem>>,
    /// `{user}` → 搜索历史（按最近使用降序）。
    searches: HashMap<String, Vec<String>>,
}

impl Default for Snapshot {
    fn default() -> Self {
        Snapshot {
            version: SNAPSHOT_VERSION,
            follows: HashMap::new(),
            history: HashMap::new(),
            searches: HashMap::new(),
        }
    }
}

/// 追剧与进度库。
#[derive(Debug)]
pub struct Library {
    inner: Mutex<State>,
}

#[derive(Debug, Default)]
struct State {
    snapshot: Snapshot,
    path: Option<std::path::PathBuf>,
    dirty: bool,
}

static LIBRARY: once_cell::sync::Lazy<Library> =
    once_cell::sync::Lazy::new(|| Library {
        inner: Mutex::new(State::default()),
    });

/// 全局库。
pub fn global() -> &'static Library {
    &LIBRARY
}

pub(crate) fn reset_for_data_dir() {
    LIBRARY.reset();
}

/// 默认用户 id（单用户模式）。
pub const DEFAULT_USER: &str = "default";

impl Library {
    /// 绑定落盘路径并加载。
    pub fn attach(&self, path: std::path::PathBuf) {
        let loaded = read_json::<Snapshot>(&path).ok().flatten();
        let mut state = self.inner.lock().expect("library poisoned");
        state.path = Some(path);
        if let Some(mut snapshot) = loaded
            && snapshot.version == SNAPSHOT_VERSION
        {
            snapshot.version = SNAPSHOT_VERSION;
            state.snapshot = snapshot;
        }
        state.dirty = false;
    }

    /// 复位。
    pub fn reset(&self) {
        let mut state = self.inner.lock().expect("library poisoned");
        state.snapshot = Snapshot::default();
        state.path = None;
        state.dirty = false;
    }

    /// 写入/更新追剧。
    ///
    /// 返回 `true` 表示确实是新增（而非更新）。
    pub fn follow_put(&self, user: &str, follow: Follow) -> Result<bool, String> {
        let mut state = self.inner.lock().expect("library poisoned");
        let bucket = state.snapshot.follows.entry(user.to_owned()).or_default();
        let existed = bucket.contains_key(&follow.drama_key);
        if !existed && bucket.len() >= MAX_FOLLOWS {
            return Err(format!("追剧数量已达上限（{MAX_FOLLOWS}）"));
        }
        let merged = match bucket.get(&follow.drama_key) {
            Some(existing) => merge_follow(existing, &follow),
            None => follow,
        };
        bucket.insert(merged.drama_key.clone(), merged);
        state.dirty = true;
        drop(state);
        self.flush_inner()?;
        Ok(!existed)
    }

    /// 取消追剧。
    pub fn follow_del(&self, user: &str, drama_key: &str) -> Result<bool, String> {
        let mut state = self.inner.lock().expect("library poisoned");
        let removed = state
            .snapshot
            .follows
            .get_mut(user)
            .and_then(|b| b.remove(drama_key))
            .is_some();
        if removed {
            state.dirty = true;
        }
        drop(state);
        if removed {
            self.flush_inner()?;
        }
        Ok(removed)
    }

    /// 追剧列表（按更新时间降序）。
    pub fn follow_list(&self, user: &str) -> Vec<Follow> {
        let state = self.inner.lock().expect("library poisoned");
        let mut items: Vec<Follow> = state
            .snapshot
            .follows
            .get(user)
            .map(|b| b.values().cloned().collect())
            .unwrap_or_default();
        items.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms));
        items
    }

    /// 写入观看进度。
    pub fn history_put(&self, user: &str, item: HistoryItem) -> Result<(), String> {
        let mut state = self.inner.lock().expect("library poisoned");
        let bucket = state.snapshot.history.entry(user.to_owned()).or_default();
        bucket.retain(|h| h.drama_key != item.drama_key);
        bucket.insert(0, item);
        if bucket.len() > MAX_HISTORY {
            bucket.truncate(MAX_HISTORY);
        }
        state.dirty = true;
        drop(state);
        self.flush_inner()
    }

    /// 读某剧的进度。
    pub fn history_get(&self, user: &str, drama_key: &str) -> Option<HistoryItem> {
        let state = self.inner.lock().expect("library poisoned");
        state
            .snapshot
            .history
            .get(user)?
            .iter()
            .find(|h| h.drama_key == drama_key)
            .cloned()
    }

    /// 全部历史（按最近观看降序）。
    pub fn history_list(&self, user: &str) -> Vec<HistoryItem> {
        self.inner
            .lock()
            .expect("library poisoned")
            .snapshot
            .history
            .get(user)
            .cloned()
            .unwrap_or_default()
    }

    /// 清空历史。
    pub fn history_clear(&self, user: &str) -> Result<(), String> {
        let mut state = self.inner.lock().expect("library poisoned");
        let had = state
            .snapshot
            .history
            .get_mut(user)
            .map(|b| {
                let had = !b.is_empty();
                b.clear();
                had
            })
            .unwrap_or(false);
        if had {
            state.dirty = true;
        }
        drop(state);
        if had {
            self.flush_inner()?;
        }
        Ok(())
    }

    /// 写搜索历史（去重、置顶、上限 20）。
    pub fn search_put(&self, user: &str, keyword: &str) -> Result<(), String> {
        let trimmed = keyword.trim();
        if trimmed.is_empty() {
            return Err("搜索词不能为空".to_owned());
        }
        let mut state = self.inner.lock().expect("library poisoned");
        let bucket = state.snapshot.searches.entry(user.to_owned()).or_default();
        bucket.retain(|k| k != trimmed);
        bucket.insert(0, trimmed.to_owned());
        bucket.truncate(20);
        state.dirty = true;
        drop(state);
        self.flush_inner()
    }

    /// 搜索历史列表。
    pub fn search_list(&self, user: &str) -> Vec<String> {
        self.inner
            .lock()
            .expect("library poisoned")
            .snapshot
            .searches
            .get(user)
            .cloned()
            .unwrap_or_default()
    }

    /// 删除一条搜索历史。
    pub fn search_del(&self, user: &str, keyword: &str) -> Result<bool, String> {
        let mut state = self.inner.lock().expect("library poisoned");
        let removed = state
            .snapshot
            .searches
            .get_mut(user)
            .map(|b| {
                let before = b.len();
                b.retain(|k| k != keyword);
                b.len() != before
            })
            .unwrap_or(false);
        if removed {
            state.dirty = true;
        }
        drop(state);
        if removed {
            self.flush_inner()?;
        }
        Ok(removed)
    }

    /// 清空搜索历史。
    pub fn search_clear(&self, user: &str) -> Result<(), String> {
        let mut state = self.inner.lock().expect("library poisoned");
        let had = state
            .snapshot
            .searches
            .get_mut(user)
            .map(|b| {
                let had = !b.is_empty();
                b.clear();
                had
            })
            .unwrap_or(false);
        if had {
            state.dirty = true;
        }
        drop(state);
        if had {
            self.flush_inner()?;
        }
        Ok(())
    }

    /// 立即落盘。
    pub fn flush(&self) -> Result<(), String> {
        self.flush_inner()
    }

    fn flush_inner(&self) -> Result<(), String> {
        let (path, snapshot) = {
            let mut state = self.inner.lock().expect("library poisoned");
            if !state.dirty {
                return Ok(());
            }
            state.dirty = false;
            (state.path.clone(), state.snapshot.clone())
        };
        let Some(path) = path else {
            // 未初始化：纯内存模式，不算失败。
            return Ok(());
        };
        match write_json_atomic(&path, &snapshot, Some(MAX_FILE_BYTES)) {
            Ok(()) => Ok(()),
            Err(e) => {
                // 写失败：标回脏，让下次重试。
                self.inner.lock().expect("library poisoned").dirty = true;
                Err(e.to_string())
            }
        }
    }
}

/// 合并两条追剧记录。
///
/// 规则见模块文档：位置取新、元数据取并、集数取高水位。
fn merge_follow(existing: &Follow, incoming: &Follow) -> Follow {
    let pick = |a: &str, b: &str| {
        if b.is_empty() {
            a.to_owned()
        } else {
            b.to_owned()
        }
    };
    Follow {
        drama_key: existing.drama_key.clone(),
        title: pick(&existing.title, &incoming.title),
        cover: pick(&existing.cover, &incoming.cover),
        // 位置取新：同一集重看时以最后上报为准。
        episode: if incoming.episode > 0 {
            incoming.episode
        } else {
            existing.episode
        },
        position_secs: if incoming.episode >= existing.episode {
            incoming.position_secs
        } else {
            existing.position_secs
        },
        duration_secs: if incoming.duration_secs > 0 {
            incoming.duration_secs
        } else {
            existing.duration_secs
        },
        total_episode: existing.total_episode.max(incoming.total_episode),
        // 高水位：只增不减。
        known_episodes: existing.known_episodes.max(incoming.known_episodes),
        updated_at_ms: now_ms(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    fn follow(key: &str, episode: u32) -> Follow {
        Follow {
            drama_key: key.to_owned(),
            title: format!("剧 {key}"),
            cover: String::new(),
            episode,
            position_secs: 30,
            duration_secs: 120,
            total_episode: 80,
            known_episodes: 80,
            updated_at_ms: now_ms(),
        }
    }

    #[test]
    fn follow_put_and_list() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        assert!(lib.follow_put("u1", follow("hongguo:1", 3)).expect("put"));
        // 第二次是更新，不是新增。
        assert!(!lib.follow_put("u1", follow("hongguo:1", 5)).expect("put"));
        let list = lib.follow_list("u1");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].episode, 5);
    }

    #[test]
    fn users_are_isolated() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        lib.follow_put("alice", follow("hongguo:1", 1)).expect("put");
        lib.follow_put("bob", follow("hongguo:2", 2)).expect("put");
        assert_eq!(lib.follow_list("alice").len(), 1);
        assert_eq!(lib.follow_list("bob").len(), 1);
        assert_eq!(lib.follow_list("alice")[0].drama_key, "hongguo:1");
        assert!(lib.follow_list("carol").is_empty());
    }

    #[test]
    fn known_episodes_is_a_high_water_mark() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        let mut first = follow("hongguo:1", 10);
        first.known_episodes = 80;
        lib.follow_put("u", first).expect("put");

        // 用户回到第 3 集：已知集数不能退。
        let mut second = follow("hongguo:1", 3);
        second.known_episodes = 3;
        lib.follow_put("u", second).expect("put");

        let list = lib.follow_list("u");
        assert_eq!(list[0].episode, 3, "position should follow the latest report");
        assert_eq!(list[0].known_episodes, 80, "known episodes must not regress");
    }

    #[test]
    fn update_detection() {
        let mut f = follow("hongguo:1", 3);
        f.known_episodes = 5;
        assert!(f.has_update());
        f.episode = 5;
        assert!(!f.has_update());
    }

    #[test]
    fn follow_del() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        lib.follow_put("u", follow("hongguo:1", 1)).expect("put");
        assert!(lib.follow_del("u", "hongguo:1").expect("del"));
        assert!(!lib.follow_del("u", "hongguo:1").expect("del"));
        assert!(lib.follow_list("u").is_empty());
    }

    #[test]
    fn history_dedupes_and_orders() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        let make = |key: &str, ep: u32| HistoryItem {
            drama_key: key.to_owned(),
            title: key.to_owned(),
            cover: String::new(),
            episode: ep,
            position_secs: 0,
            duration_secs: 0,
            total_episode: 10,
            updated_at_ms: now_ms(),
        };
        lib.history_put("u", make("a", 1)).expect("put");
        lib.history_put("u", make("b", 1)).expect("put");
        lib.history_put("u", make("a", 2)).expect("put");
        let list = lib.history_list("u");
        assert_eq!(list.len(), 2);
        // 最近看的在最前。
        assert_eq!(list[0].drama_key, "a");
        assert_eq!(list[0].episode, 2);
    }

    #[test]
    fn history_get_and_clear() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        lib.history_put(
            "u",
            HistoryItem {
                drama_key: "a".to_owned(),
                title: "A".to_owned(),
                cover: String::new(),
                episode: 4,
                position_secs: 60,
                duration_secs: 120,
                total_episode: 10,
                updated_at_ms: now_ms(),
            },
        )
        .expect("put");
        let item = lib.history_get("u", "a").expect("found");
        assert_eq!(item.episode, 4);
        assert!((item.progress() - 0.5).abs() < 1e-9);
        lib.history_clear("u").expect("clear");
        assert!(lib.history_get("u", "a").is_none());
    }

    #[test]
    fn search_history_dedupes_and_caps() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        lib.search_put("u", "都市").expect("put");
        lib.search_put("u", "甜宠").expect("put");
        lib.search_put("u", "都市").expect("put");
        let list = lib.search_list("u");
        assert_eq!(list, vec!["都市".to_owned(), "甜宠".to_owned()]);

        for i in 0..30 {
            lib.search_put("u", &format!("k{i}")).expect("put");
        }
        assert_eq!(lib.search_list("u").len(), 20);
    }

    #[test]
    fn search_del_and_clear() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        lib.search_put("u", "a").expect("put");
        assert!(lib.search_del("u", "a").expect("del"));
        assert!(!lib.search_del("u", "a").expect("del"));
        lib.search_put("u", "b").expect("put");
        lib.search_clear("u").expect("clear");
        assert!(lib.search_list("u").is_empty());
    }

    #[test]
    fn persists_across_attach() {
        let dir = TempDir::new("library");
        let path = dir.path().join("library.json");

        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        lib.attach(path.clone());
        lib.follow_put("u", follow("hongguo:1", 7)).expect("put");
        lib.search_put("u", "都市").expect("put");
        lib.flush().expect("flush");

        let reloaded = Library {
            inner: Mutex::new(State::default()),
        };
        reloaded.attach(path);
        assert_eq!(reloaded.follow_list("u").len(), 1);
        assert_eq!(reloaded.follow_list("u")[0].episode, 7);
        assert_eq!(reloaded.search_list("u"), vec!["都市".to_owned()]);
    }

    #[test]
    fn empty_search_keyword_rejected() {
        let lib = Library {
            inner: Mutex::new(State::default()),
        };
        assert!(lib.search_put("u", "   ").is_err());
    }
}
