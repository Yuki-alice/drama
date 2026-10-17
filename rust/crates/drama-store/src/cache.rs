//! 目录缓存：TTL + 旧值兜底 + 熔断 + 并发去重。
//!
//! ## 四条语义
//!
//! 1. **新鲜命中**（TTL 内）→ 直接返回，不打网络；
//! 2. **未命中** → 打网络 → 成功写缓存；
//! 3. **网络失败** → 回退 ≤24h 的旧值并置 `stale=true`；无旧值则**原样抛错**
//!    （不能拿「空列表」冒充「查过了」）；
//! 4. **熔断**：某 key 在 18 s 内失败 3 次 → 打开 60 s，期间直接回退旧值，
//!    不再打网络。
//!
//! ## 并发去重
//!
//! 同 key 并发只打一次网络：后来的线程等在途者结束后**重读缓存**。
//! 首页会并发打 `catalog`/`recommend`/`ranking`，重复请求是常态。
//!
//! ## 为什么缓存 key 带源前缀
//!
//! `{source}:{kind}:{args}`。跨源同 id 是不同剧目，不带前缀会串库。

use std::collections::HashMap;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::atomic::{read_json, write_json_atomic};

/// 目录/推荐/详情/搜索/联想的新鲜窗口。
pub const TTL_CATALOG: Duration = Duration::from_secs(15 * 60);
/// 榜单新鲜窗口（比目录短，越新越反映热度变化）。
pub const TTL_RANKING: Duration = Duration::from_secs(5 * 60);
/// 弱网兜底允许的最大年龄。
pub const TTL_FALLBACK: Duration = Duration::from_secs(24 * 60 * 60);

/// 熔断：窗口内失败次数阈值 / 窗口 / 冷却。
const BREAKER_THRESHOLD: usize = 3;
const BREAKER_WINDOW: Duration = Duration::from_secs(18);
const BREAKER_COOLDOWN: Duration = Duration::from_secs(60);

/// 缓存文件上限。
const MAX_FILE_BYTES: usize = 32 * 1024 * 1024;
/// 条数上限（超出按 `fetched_at` 淘汰最旧）。
const MAX_ENTRIES: usize = 800;
/// 落盘防抖窗口：连续翻页时合并成一次写。
const FLUSH_DEBOUNCE: Duration = Duration::from_millis(500);
/// 等待在途者的上限（超时则自己继续，绝不无限等）。
const INFLIGHT_WAIT: Duration = Duration::from_secs(60);

/// 一条缓存值。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheEntry {
    pub value: Value,
    pub fetched_at_ms: i64,
    /// 该条目对应的源（便于诊断与按源清理）。
    #[serde(default)]
    pub source: String,
}

/// 缓存命中结果。
#[derive(Debug, Clone)]
pub struct CachedValue {
    pub value: Value,
    /// 是否来自过期兜底（网络失败）。
    pub stale: bool,
    /// 数据年龄（秒）。
    pub age_secs: i64,
}

/// 熔断器状态。
#[derive(Debug, Default)]
struct Breaker {
    failures: Vec<Instant>,
    open_until: Option<Instant>,
}

impl Breaker {
    fn is_open(&self, now: Instant) -> bool {
        self.open_until.is_some_and(|until| now < until)
    }

    fn record_failure(&mut self, now: Instant) {
        self.failures
            .retain(|t| now.duration_since(*t) < BREAKER_WINDOW);
        self.failures.push(now);
        if self.failures.len() >= BREAKER_THRESHOLD {
            self.open_until = Some(now + BREAKER_COOLDOWN);
            self.failures.clear();
        }
    }

    fn record_success(&mut self) {
        self.failures.clear();
        self.open_until = None;
    }
}

/// 落盘快照。
#[derive(Debug, Serialize, Deserialize)]
struct DiskSnapshot {
    version: u32,
    entries: HashMap<String, CacheEntry>,
    /// 分页水位：`{source}:{category}` → 已取页数。
    #[serde(default)]
    depths: HashMap<String, u32>,
}

const SNAPSHOT_VERSION: u32 = 3;

/// 目录缓存。
#[derive(Debug)]
pub struct CatalogCache {
    inner: Mutex<State>,
    cv: Condvar,
}

#[derive(Debug, Default)]
struct State {
    entries: HashMap<String, CacheEntry>,
    depths: HashMap<String, u32>,
    breakers: HashMap<String, Breaker>,
    /// 正在拉取的 key → 开始时刻。
    inflight: HashMap<String, Instant>,
    dirty: bool,
    last_flush: Option<Instant>,
    path: Option<std::path::PathBuf>,
}

static CACHE: once_cell::sync::Lazy<CatalogCache> = once_cell::sync::Lazy::new(CatalogCache::default);

/// 全局缓存。
pub fn global() -> &'static CatalogCache {
    &CACHE
}

/// 数据目录切换时复位内存表。
pub(crate) fn reset_for_data_dir() {
    CACHE.reset();
}

impl Default for CatalogCache {
    fn default() -> Self {
        CatalogCache {
            inner: Mutex::new(State::default()),
            cv: Condvar::new(),
        }
    }
}

impl CatalogCache {
    fn now_ms() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    /// 绑定落盘路径并加载。
    pub fn attach(&self, path: std::path::PathBuf) {
        let mut state = self.inner.lock().expect("cache poisoned");
        state.path = Some(path.clone());
        drop(state);
        self.load_from_disk(&path);
    }

    fn load_from_disk(&self, path: &std::path::Path) {
        let Ok(Some(snapshot)) = read_json::<DiskSnapshot>(path) else {
            // 文件不存在或损坏：都按「空缓存」启动，但不覆盖原文件。
            return;
        };
        if snapshot.version != SNAPSHOT_VERSION {
            return;
        }
        let mut state = self.inner.lock().expect("cache poisoned");
        state.entries = snapshot.entries;
        state.depths = snapshot.depths;
        state.dirty = false;
    }

    /// 复位（数据目录切换）。
    pub fn reset(&self) {
        let mut state = self.inner.lock().expect("cache poisoned");
        state.entries.clear();
        state.depths.clear();
        state.breakers.clear();
        state.inflight.clear();
        state.dirty = false;
        state.path = None;
        drop(state);
        self.cv.notify_all();
    }

    /// 取缓存（新鲜则返回；过期但 ≤24h 也返回并标 `stale`）。
    pub fn get(&self, key: &str, ttl: Duration) -> Option<CachedValue> {
        let state = self.inner.lock().expect("cache poisoned");
        let entry = state.entries.get(key)?;
        let now = Self::now_ms();
        let age_ms = (now - entry.fetched_at_ms).max(0);
        let age = Duration::from_millis(age_ms as u64);
        if age <= ttl {
            return Some(CachedValue {
                value: entry.value.clone(),
                stale: false,
                age_secs: age.as_secs() as i64,
            });
        }
        if age <= TTL_FALLBACK {
            return Some(CachedValue {
                value: entry.value.clone(),
                stale: true,
                age_secs: age.as_secs() as i64,
            });
        }
        None
    }

    /// 写入缓存。
    pub fn put(&self, key: &str, source: &str, value: Value) {
        let mut state = self.inner.lock().expect("cache poisoned");
        let now = Self::now_ms();
        state.entries.insert(
            key.to_owned(),
            CacheEntry {
                value,
                fetched_at_ms: now,
                source: source.to_owned(),
            },
        );
        // 超上限：按 fetched_at 淘汰最旧的一批。
        if state.entries.len() > MAX_ENTRIES {
            let mut ages: Vec<(i64, String)> = state
                .entries
                .iter()
                .map(|(k, v)| (v.fetched_at_ms, k.clone()))
                .collect();
            ages.sort_unstable();
            for (_, k) in ages.into_iter().take(state.entries.len() - MAX_ENTRIES) {
                state.entries.remove(&k);
            }
        }
        state.dirty = true;
        let should_flush = state
            .last_flush
            .is_none_or(|t| t.elapsed() >= FLUSH_DEBOUNCE);
        let path = state.path.clone();
        if should_flush {
            state.last_flush = Some(Instant::now());
        }
        drop(state);
        if should_flush
            && let Some(path) = path
        {
            // 防抖落盘失败不阻断读取路径：数据仍在内存里，下次写入会重试。
            let _ = self.flush_to(&path);
        }
    }

    /// 标记某 key 的拉取开始；返回 `false` 表示已有在途者。
    pub fn begin_inflight(&self, key: &str) -> bool {
        let mut state = self.inner.lock().expect("cache poisoned");
        let now = Instant::now();
        // 清理超时的在途标记（对端 panic 会留下僵尸标记）。
        state
            .inflight
            .retain(|_, started| now.duration_since(*started) < INFLIGHT_WAIT);
        if state.inflight.contains_key(key) {
            return false;
        }
        state.inflight.insert(key.to_owned(), now);
        true
    }

    /// 结束在途标记并唤醒等待者。
    pub fn end_inflight(&self, key: &str) {
        let mut state = self.inner.lock().expect("cache poisoned");
        state.inflight.remove(key);
        drop(state);
        self.cv.notify_all();
    }

    /// 等待在途者结束（最多 `INFLIGHT_WAIT`）。
    pub fn wait_inflight(&self, key: &str) {
        let deadline = Instant::now() + INFLIGHT_WAIT;
        let mut state = self.inner.lock().expect("cache poisoned");
        while state.inflight.contains_key(key) {
            let now = Instant::now();
            if now >= deadline {
                return;
            }
            let wait = (deadline - now).min(Duration::from_millis(50));
            let (guard, _) = self.cv.wait_timeout(state, wait).expect("cache poisoned");
            state = guard;
        }
    }

    /// 熔断器是否打开（打开期间不再打网络）。
    pub fn breaker_open(&self, key: &str) -> bool {
        let state = self.inner.lock().expect("cache poisoned");
        state
            .breakers
            .get(key)
            .is_some_and(|b| b.is_open(Instant::now()))
    }

    /// 记录一次失败。
    pub fn note_failure(&self, key: &str) {
        let mut state = self.inner.lock().expect("cache poisoned");
        state
            .breakers
            .entry(key.to_owned())
            .or_default()
            .record_failure(Instant::now());
    }

    /// 记录一次成功。
    pub fn note_success(&self, key: &str) {
        let mut state = self.inner.lock().expect("cache poisoned");
        if let Some(breaker) = state.breakers.get_mut(key) {
            breaker.record_success();
        }
    }

    /// 分页水位：已取页数。
    pub fn read_depth(&self, key: &str) -> Option<u32> {
        self.inner
            .lock()
            .expect("cache poisoned")
            .depths
            .get(key)
            .copied()
    }

    /// 写分页水位（只增不减）。
    pub fn write_depth(&self, key: &str, depth: u32) {
        let mut state = self.inner.lock().expect("cache poisoned");
        let slot = state.depths.entry(key.to_owned()).or_insert(0);
        if depth > *slot {
            *slot = depth;
            state.dirty = true;
        }
    }

    /// 立即落盘。
    pub fn flush(&self) -> Result<(), crate::atomic::WriteError> {
        let path = self.inner.lock().expect("cache poisoned").path.clone();
        match path {
            Some(path) => self.flush_to(&path),
            None => Ok(()),
        }
    }

    fn flush_to(&self, path: &std::path::Path) -> Result<(), crate::atomic::WriteError> {
        let snapshot = {
            let mut state = self.inner.lock().expect("cache poisoned");
            if !state.dirty {
                return Ok(());
            }
            state.dirty = false;
            DiskSnapshot {
                version: SNAPSHOT_VERSION,
                entries: state.entries.clone(),
                depths: state.depths.clone(),
            }
        };
        let result = write_json_atomic(path, &snapshot, Some(MAX_FILE_BYTES));
        if result.is_err() {
            // 写失败：重新标脏，下次还有机会。
            self.inner.lock().expect("cache poisoned").dirty = true;
        }
        result
    }

    /// 清空。
    pub fn clear(&self) -> Result<(), crate::atomic::WriteError> {
        let path = {
            let mut state = self.inner.lock().expect("cache poisoned");
            state.entries.clear();
            state.depths.clear();
            state.breakers.clear();
            state.dirty = true;
            state.path.clone()
        };
        match path {
            Some(path) => self.flush_to(&path),
            None => Ok(()),
        }
    }

    /// 统计。
    pub fn stats(&self) -> CacheStats {
        let state = self.inner.lock().expect("cache poisoned");
        let now = Self::now_ms();
        let fresh = state
            .entries
            .values()
            .filter(|e| now - e.fetched_at_ms <= TTL_CATALOG.as_millis() as i64)
            .count();
        CacheStats {
            entries: state.entries.len(),
            fresh_entries: fresh,
            stale_entries: state.entries.len() - fresh,
            depth_entries: state.depths.len(),
            open_breakers: state
                .breakers
                .values()
                .filter(|b| b.is_open(Instant::now()))
                .count(),
            dirty: state.dirty,
        }
    }
}

/// 缓存统计（`cacheStats` op 返回）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheStats {
    pub entries: usize,
    pub fresh_entries: usize,
    pub stale_entries: usize,
    pub depth_entries: usize,
    pub open_breakers: usize,
    pub dirty: bool,
}

// ── key 构造 ────────────────────────────────────────────────

/// 目录 key（含页号）。
pub fn key_catalog(source: &str, category: &str, page: u32) -> String {
    format!("{source}:catalog:{category}:{page}")
}

/// 目录水位 key。
pub fn key_catalog_depth(source: &str, category: &str) -> String {
    format!("{source}:catalog-depth:{category}")
}

pub fn key_recommend(source: &str) -> String {
    format!("{source}:recommend")
}

pub fn key_ranking(source: &str, board: &str) -> String {
    format!("{source}:ranking:{board}")
}

pub fn key_search(source: &str, keyword: &str) -> String {
    format!("{source}:search:{keyword}")
}

pub fn key_suggest(source: &str, keyword: &str) -> String {
    format!("{source}:suggest:{keyword}")
}

pub fn key_detail(source: &str, id: &str) -> String {
    format!("{source}:detail:{id}")
}

pub fn key_categories(source: &str) -> String {
    format!("{source}:categories")
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    #[test]
    fn fresh_hit_returns_not_stale() {
        let cache = CatalogCache::default();
        cache.put("k", "hongguo", serde_json::json!({"a": 1}));
        let hit = cache.get("k", TTL_CATALOG).expect("hit");
        assert!(!hit.stale);
        assert_eq!(hit.value["a"], 1);
    }

    #[test]
    fn expired_within_fallback_is_stale() {
        let cache = CatalogCache::default();
        // 手工插入一条 1 小时前的条目。
        {
            let mut state = cache.inner.lock().expect("lock");
            state.entries.insert(
                "k".to_owned(),
                CacheEntry {
                    value: serde_json::json!({"old": true}),
                    fetched_at_ms: CatalogCache::now_ms() - 3_600_000,
                    source: "hongguo".to_owned(),
                },
            );
        }
        // TTL 15 分钟 → 已过期；但 1 小时 < 24 小时 → 仍可兜底。
        let hit = cache.get("k", TTL_CATALOG).expect("hit");
        assert!(hit.stale);
        assert_eq!(hit.value["old"], true);
    }

    #[test]
    fn beyond_fallback_is_a_miss() {
        let cache = CatalogCache::default();
        {
            let mut state = cache.inner.lock().expect("lock");
            state.entries.insert(
                "k".to_owned(),
                CacheEntry {
                    value: serde_json::json!({}),
                    fetched_at_ms: CatalogCache::now_ms() - 48 * 3_600_000,
                    source: "hongguo".to_owned(),
                },
            );
        }
        assert!(cache.get("k", TTL_CATALOG).is_none());
    }

    #[test]
    fn breaker_opens_after_three_failures() {
        let cache = CatalogCache::default();
        assert!(!cache.breaker_open("b"));
        for _ in 0..3 {
            cache.note_failure("b");
        }
        assert!(cache.breaker_open("b"));
        // 成功一次即复位。
        cache.note_success("b");
        assert!(!cache.breaker_open("b"));
    }

    #[test]
    fn inflight_dedup() {
        let cache = CatalogCache::default();
        assert!(cache.begin_inflight("k"));
        // 第二个调用者拿不到。
        assert!(!cache.begin_inflight("k"));
        cache.end_inflight("k");
        assert!(cache.begin_inflight("k"));
    }

    #[test]
    fn depth_only_increases() {
        let cache = CatalogCache::default();
        cache.write_depth("d", 3);
        assert_eq!(cache.read_depth("d"), Some(3));
        cache.write_depth("d", 1);
        // 水位只增不减，否则重启后会「少取几页」。
        assert_eq!(cache.read_depth("d"), Some(3));
    }

    #[test]
    fn persists_and_reloads() {
        let dir = TempDir::new("cache");
        let path = dir.path().join("catalogs.json");

        let cache = CatalogCache::default();
        cache.attach(path.clone());
        cache.put("k1", "hongguo", serde_json::json!({"v": "one"}));
        cache.write_depth("d1", 2);
        cache.flush().expect("flush");

        let reloaded = CatalogCache::default();
        reloaded.attach(path);
        let hit = reloaded.get("k1", TTL_CATALOG).expect("hit");
        assert_eq!(hit.value["v"], "one");
        assert_eq!(reloaded.read_depth("d1"), Some(2));
    }

    #[test]
    fn corrupt_snapshot_starts_empty_and_keeps_file() {
        let dir = TempDir::new("cache-corrupt");
        let path = dir.path().join("catalogs.json");
        std::fs::write(&path, b"{broken").expect("write");

        let cache = CatalogCache::default();
        cache.attach(path.clone());
        assert!(cache.get("k", TTL_CATALOG).is_none());
        // 原文件保留，供恢复。
        assert!(path.exists());
    }

    #[test]
    fn clear_empties_everything() {
        let dir = TempDir::new("cache-clear");
        let path = dir.path().join("catalogs.json");
        let cache = CatalogCache::default();
        cache.attach(path);
        cache.put("k", "hongguo", serde_json::json!({}));
        cache.write_depth("d", 5);
        cache.clear().expect("clear");
        assert!(cache.get("k", TTL_CATALOG).is_none());
        assert!(cache.read_depth("d").is_none());
    }

    #[test]
    fn keys_are_source_scoped() {
        // 同 id 不同源必须是不同 key，否则串库。
        assert_ne!(key_detail("hongguo", "1"), key_detail("wuguo", "1"));
        assert_eq!(key_catalog("hongguo", "", 0), "hongguo:catalog::0");
    }

    #[test]
    fn stats_counts_fresh_and_stale() {
        let cache = CatalogCache::default();
        cache.put("fresh", "hongguo", serde_json::json!({}));
        {
            let mut state = cache.inner.lock().expect("lock");
            state.entries.insert(
                "old".to_owned(),
                CacheEntry {
                    value: serde_json::json!({}),
                    fetched_at_ms: CatalogCache::now_ms() - 3_600_000,
                    source: "hongguo".to_owned(),
                },
            );
        }
        let stats = cache.stats();
        assert_eq!(stats.entries, 2);
        assert_eq!(stats.fresh_entries, 1);
        assert_eq!(stats.stale_entries, 1);
    }
}
