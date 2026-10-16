//! 目录缓存引擎（持久化面）。
//!
//! 单文件 JSON（`{dataDir}/catalog_cache_v2.json`，上限 4 MiB），
//! 内存快照 + 原子落盘（写 `.tmp` 再 `rename`）。
//!
//! v2 起全部缓存 key 带源前缀（`{source}:...`），旧版无源 key 文件不再读取。
//!
//! 语义（Dart 侧不再持有任何缓存策略，只渲染）：
//! - 新鲜命中（TTL 内）→ 直接返回，不打网络；
//! - 未命中 → 打网络 → 成功写缓存；
//! - 网络失败 → 回退 ≤[TTL_FALLBACK_MS] 的旧值，并置 `stale=true`；无旧值则**原样抛错**；
//! - 榜单另加每板独立熔断器（[BREAKER_WINDOW_MS] 内 [BREAKER_THRESHOLD] 次失败 → 打开，
//!   冷却 [BREAKER_COOLDOWN_MS] 后放行一次试探）；
//! - 同 key 并发只打一次网络（后来的线程等在途者结束后**重读缓存**）。
//!
//! **封面端口自愈**：封面地址以规范形式 `drama-img:{token}` 落盘——
//! 端口是实现细节，不该成为缓存数据的一部分。读出时用**当前**端口展开，
//! 因此跨会话缓存永不因端口变化而失效，Dart 侧也不必在渲染时改写端口。

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::source::traits::SourceError;

/// 缓存文件上限（超出即拒绝落盘，保留内存态）。
const MAX_FILE_BYTES: usize = 4 * 1024 * 1024;
/// 条数上限（超出按 `fetched_at_ms` 淘汰最旧）。
const MAX_ENTRIES: usize = 500;
/// 落盘防抖窗口：连续翻页时合并成一次写。
const FLUSH_DEBOUNCE_MS: i64 = 500;
/// 等待在途者的上限（超时则自己继续，绝不无限等）。
const INFLIGHT_WAIT: Duration = Duration::from_secs(60);

/// 目录 / 推荐 / 详情 / 搜索 / 联想的新鲜窗口（15min）。
pub const TTL_CATALOG_MS: i64 = 15 * 60 * 1000;
/// 榜单新鲜窗口（5min）——比目录短，越新越反映热度变化。
pub const TTL_RANKING_MS: i64 = 5 * 60 * 1000;
/// 弱网 / 旧值兜底允许的最大年龄（24h）。
pub const TTL_FALLBACK_MS: i64 = 24 * 60 * 60 * 1000;

/// 熔断器：窗口内失败次数阈值 / 窗口 / 冷却。
const BREAKER_THRESHOLD: usize = 3;
const BREAKER_WINDOW_MS: i64 = 18 * 1000;
const BREAKER_COOLDOWN_MS: i64 = 60 * 1000;

/// 封面规范形式前缀（落盘用；读出时按当前端口展开）。
const COVER_CANON_PREFIX: &str = "drama-img:";

// ── key 约定（与诊断脚本口径一致，勿随意改） ─────────────────────────────
//
// 首段一律是源 id（`{source}:...`）：多源同分类/同榜单/同关键词/同剧集 id
// 必须落到不同条目，否则 A 源数据会被 B 源命中（S0 多源命名空间）。
pub fn key_catalog(source: &str, category: &str, page: u32) -> String {
    format!("{source}:catalog:{category}:{page}")
}

pub fn key_catalog_depth(source: &str, category: &str) -> String {
    format!("{source}:catalog:{category}:depth")
}

pub fn key_recommend(source: &str) -> String {
    format!("{source}:recommend")
}

pub fn key_ranking(source: &str, board: &str) -> String {
    format!("{source}:ranking:{board}:last")
}

pub fn key_detail(source: &str, series_id: &str) -> String {
    format!("{source}:detail:{series_id}")
}

pub fn key_search(source: &str, keyword: &str) -> String {
    format!("{source}:search:{keyword}")
}

pub fn key_suggest(source: &str, keyword: &str) -> String {
    format!("{source}:suggest:{keyword}")
}

// ── 缓存条目与状态 ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Entry {
    value_json: String,
    fetched_at_ms: i64,
}

#[derive(Debug, Default)]
struct Cache {
    entries: HashMap<String, Entry>,
    dirty: bool,
    last_flush_ms: i64,
    loaded: bool,
}

/// 每榜单板的独立熔断器（内存态，不持久化）。
#[derive(Debug, Default)]
struct Breaker {
    failures_ms: Vec<i64>,
    opened_at_ms: Option<i64>,
}

/// 在途槽位：后来的线程等在途者结束，然后**重读缓存**（不共享结果值，
/// 因此不需要 [`SourceError`] 可克隆，也不存在跨线程结果所有权问题）。
#[derive(Debug, Default)]
struct Inflight {
    done: Mutex<bool>,
    cv: Condvar,
}

static CACHE: Lazy<Mutex<Cache>> = Lazy::new(|| Mutex::new(Cache::default()));
static BREAKERS: Lazy<Mutex<HashMap<String, Breaker>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static INFLIGHT: Lazy<Mutex<HashMap<String, Arc<Inflight>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn path() -> Option<std::path::PathBuf> {
    // v2：S0 起 key 全部带源前缀，旧文件（无源 key）不再读取，尽力删除。
    crate::device::data_dir().map(|d| d.join("catalog_cache_v2.json"))
}

fn legacy_path() -> Option<std::path::PathBuf> {
    crate::device::data_dir().map(|d| d.join("catalog_cache.json"))
}

fn lock() -> std::sync::MutexGuard<'static, Cache> {
    CACHE.lock().expect("cache poisoned")
}

/// 数据目录切换时复位：清空内存表并取消已加载标记，下次读写从新目录延迟载入。
/// 熔断器与在途槽位与目录无关，保留。由 `device::set_data_dir` / `clear_data_dir` 调用。
pub(crate) fn reset_for_data_dir() {
    let mut cache = lock();
    cache.entries.clear();
    cache.dirty = false;
    cache.last_flush_ms = 0;
    cache.loaded = false;
}

/// 延迟载入：首次读/写时从文件载入（损坏即用空表——缓存是加速手段，不是真相源）。
fn ensure_loaded() {
    let mut cache = lock();
    if cache.loaded {
        return;
    }
    cache.loaded = true;
    if let Some(legacy) = legacy_path() {
        let _ = std::fs::remove_file(&legacy);
    }
    let Some(path) = path() else { return };
    let Ok(raw) = std::fs::read(&path) else {
        return;
    };
    if raw.len() > MAX_FILE_BYTES {
        return;
    }
    if let Ok(map) = serde_json::from_slice::<HashMap<String, Entry>>(&raw) {
        cache.entries = map;
        cache.entries.shrink_to_fit();
    }
}

/// 防抖落盘：脏且距上次落盘超过窗口才真写；否则留待下次调用补写。
fn maybe_flush() {
    let mut cache = lock();
    if !cache.dirty {
        return;
    }
    if now_ms() - cache.last_flush_ms < FLUSH_DEBOUNCE_MS {
        return;
    }
    flush_locked(&mut cache);
}

fn flush_locked(cache: &mut Cache) {
    let Some(path) = path() else {
        cache.dirty = false;
        return;
    };
    let Ok(raw) = serde_json::to_vec(&cache.entries) else {
        return;
    };
    if raw.len() > MAX_FILE_BYTES {
        // 超限时淘汰到一半再试一次；仍超限则放弃本次落盘（内存态照常服务）。
        evict_locked(cache, cache.entries.len() / 2);
        let Ok(raw) = serde_json::to_vec(&cache.entries) else {
            return;
        };
        if raw.len() > MAX_FILE_BYTES {
            return;
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if write_atomic(&path, &raw).is_ok() {
            cache.dirty = false;
            cache.last_flush_ms = now_ms();
        }
        return;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if write_atomic(&path, &raw).is_ok() {
        cache.dirty = false;
        cache.last_flush_ms = now_ms();
    }
}

/// 写临时文件再 `rename` → 原子替换，避免读到半截文件。
fn write_atomic(path: &std::path::Path, raw: &[u8]) -> std::io::Result<()> {
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, raw)?;
    match std::fs::rename(&temp, path) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_file(&temp);
            Err(e)
        }
    }
}

/// 按 `fetched_at_ms` 淘汰到不超过 [MAX_ENTRIES] 条。
fn evict_if_needed() {
    let mut cache = lock();
    if cache.entries.len() <= MAX_ENTRIES {
        return;
    }
    evict_locked(&mut cache, MAX_ENTRIES);
}

fn evict_locked(cache: &mut Cache, keep: usize) {
    if cache.entries.len() <= keep {
        return;
    }
    let mut keys: Vec<(i64, String)> = cache
        .entries
        .iter()
        .map(|(k, v)| (v.fetched_at_ms, k.clone()))
        .collect();
    keys.sort_unstable();
    for (_, key) in keys.iter().take(cache.entries.len() - keep) {
        cache.entries.remove(key);
    }
}

// ── 封面规范形式（端口无关） ─────────────────────────────────────────────

/// `http://127.0.0.1:{port}/img/{token}` → `drama-img:{token}`。
fn canonical_cover(url: &str) -> Option<String> {
    let rest = url.strip_prefix("http://127.0.0.1:")?;
    let (_, tail) = rest.split_once('/')?;
    let token = tail.strip_prefix("img/")?;
    if token.is_empty() {
        return None;
    }
    Some(format!("{COVER_CANON_PREFIX}{token}"))
}

/// `drama-img:{token}` → `http://127.0.0.1:{port}/img/{token}`。
fn expand_cover(canon: &str, port: u16) -> Option<String> {
    let token = canon.strip_prefix(COVER_CANON_PREFIX)?;
    if token.is_empty() {
        return None;
    }
    Some(format!("http://127.0.0.1:{port}/img/{token}"))
}

/// 落盘前：把 `cover` 字段的代理地址换成规范形式（去端口）。
///
/// 只处理键名为 `cover` 的字符串（Drama 里仅封面走本机代理），
/// 避免对整页做全量字符串扫描。
fn canonicalize(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                if key == "cover"
                    && let Some(url) = child.as_str()
                    && let Some(canon) = canonical_cover(url)
                {
                    *child = Value::String(canon);
                    continue;
                }
                canonicalize(child);
            }
        }
        Value::Array(items) => {
            for item in items.iter_mut() {
                canonicalize(item);
            }
        }
        _ => {}
    }
}

/// 读出后：把规范形式展开成**当前端口**的地址。
///
/// 展开失败（端口未绑定）→ 置空串：让 UI 直接回落渐变占位，
/// 而不是发一个必然 404 的请求。
fn expand(value: &mut Value, port: Option<u16>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                if key == "cover"
                    && let Some(canon) = child.as_str()
                {
                    match port.and_then(|p| expand_cover(canon, p)) {
                        // 端口已绑定 → 展开成**本次会话**的地址。
                        Some(url) => {
                            *child = Value::String(url);
                            continue;
                        }
                        // 是规范形式却拿不到端口 → 置空串（见上：不发必然 404 的请求）。
                        None if canon.starts_with(COVER_CANON_PREFIX) => {
                            *child = Value::String(String::new());
                            continue;
                        }
                        // 非代理地址（源站直链）→ 原样保留。
                        None => {}
                    }
                }
                expand(child, port);
            }
        }
        Value::Array(items) => {
            for item in items.iter_mut() {
                expand(item, port);
            }
        }
        _ => {}
    }
}

// ── 读写 ────────────────────────────────────────────────────────────────

/// 读条目：`max_age_ms` 内视为新鲜；命中即展开封面端口。
fn read(key: &str, max_age_ms: i64) -> Option<Value> {
    ensure_loaded();
    let port = crate::covers::media_port();
    let raw = {
        let cache = lock();
        let entry = cache.entries.get(key)?;
        if now_ms() - entry.fetched_at_ms > max_age_ms {
            return None;
        }
        entry.value_json.clone()
    };
    let mut value: Value = serde_json::from_str(&raw).ok()?;
    expand(&mut value, port);
    Some(value)
}

/// 写条目（封面先归一化）：内存立即生效，落盘走防抖。
fn write(key: &str, mut value: Value) {
    ensure_loaded();
    canonicalize(&mut value);
    let Ok(value_json) = serde_json::to_string(&value) else {
        return;
    };
    {
        let mut cache = lock();
        cache.entries.insert(
            key.to_owned(),
            Entry {
                value_json,
                fetched_at_ms: now_ms(),
            },
        );
    }
    evict_if_needed();
    {
        let mut cache = lock();
        cache.dirty = true;
    }
    maybe_flush();
}

/// 读整数条目（分页水位）；缺失/过期返回 `None`。
pub fn read_depth(key: &str) -> Option<i64> {
    ensure_loaded();
    let cache = lock();
    let entry = cache.entries.get(key)?;
    if now_ms() - entry.fetched_at_ms > TTL_FALLBACK_MS {
        return None;
    }
    let value: Value = serde_json::from_str(&entry.value_json).ok()?;
    value.as_i64()
}

/// 写分页水位：取较大值（只增不减）。
pub fn write_depth(key: &str, depth: u32) {
    let current = read_depth(key).unwrap_or(0);
    if i64::from(depth) > current {
        write(key, json!(depth));
    }
}

// ── 熔断器 ──────────────────────────────────────────────────────────────

/// 是否处于「打开且冷却中」——是则不该发网络。
fn breaker_blocked(board: &str) -> bool {
    let breakers = BREAKERS.lock().expect("breakers poisoned");
    match breakers.get(board) {
        Some(b) => match b.opened_at_ms {
            Some(opened) => now_ms() - opened < BREAKER_COOLDOWN_MS,
            None => false,
        },
        None => false,
    }
}

fn breaker_success(board: &str) {
    let mut breakers = BREAKERS.lock().expect("breakers poisoned");
    if let Some(b) = breakers.get_mut(board) {
        b.failures_ms.clear();
        b.opened_at_ms = None;
    }
}

fn breaker_failure(board: &str) {
    let now = now_ms();
    let mut breakers = BREAKERS.lock().expect("breakers poisoned");
    let b = breakers.entry(board.to_owned()).or_default();
    b.failures_ms.retain(|t| now - *t <= BREAKER_WINDOW_MS);
    b.failures_ms.push(now);
    // 已打开则续期冷却；否则达到阈值才打开。
    if b.opened_at_ms.is_some() || b.failures_ms.len() >= BREAKER_THRESHOLD {
        b.opened_at_ms = Some(now);
    }
}

// ── 在途去重 ────────────────────────────────────────────────────────────

/// 尝试进入在途；`false` = 已有他人在途，调用方应等待后重读缓存。
fn inflight_enter(key: &str) -> bool {
    let mut map = INFLIGHT.lock().expect("inflight poisoned");
    if map.contains_key(key) {
        return false;
    }
    map.insert(key.to_owned(), Arc::new(Inflight::default()));
    true
}

fn inflight_exit(key: &str) {
    let slot = INFLIGHT.lock().expect("inflight poisoned").remove(key);
    if let Some(slot) = slot {
        *slot.done.lock().expect("inflight done poisoned") = true;
        slot.cv.notify_all();
    }
}

/// 等待在途者结束（最多 [INFLIGHT_WAIT]）；返回是否等到了。
fn inflight_wait(key: &str) -> bool {
    let slot = {
        let map = INFLIGHT.lock().expect("inflight poisoned");
        map.get(key).cloned()
    };
    let Some(slot) = slot else { return false };
    let deadline = Instant::now() + INFLIGHT_WAIT;
    let guard = slot.done.lock().expect("inflight done poisoned");
    let mut guard = guard;
    while !*guard {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return false;
        }
        let (next, _) = slot
            .cv
            .wait_timeout(guard, remaining)
            .expect("inflight wait poisoned");
        guard = next;
    }
    true
}

// ── 对外：带缓存的一次读 ────────────────────────────────────────────────

/// 一次带缓存的读的结果。
#[derive(Debug)]
pub struct Cached {
    /// 数据（封面端口已按当前会话展开）。
    pub value: Value,
    /// 是否来自兜底旧值（网络失败或熔断中）。
    pub stale: bool,
    /// 数据年龄（秒）；新鲜命中为 0。
    pub age_secs: i64,
}

/// 带缓存地取一次数据。
///
/// - `ttl_ms`：新鲜窗口；`breaker`：榜单板 id（`None` = 不熔断）。
/// - 并发同 key 只打一次网络：后来的线程等在途者结束后重读缓存。
/// - 网络失败 / 熔断中 → 回退 ≤[TTL_FALLBACK_MS] 的旧值并置 `stale=true`；
///   无旧值则**原样抛错**（错误可见）。
pub fn cached<F>(
    key: &str,
    ttl_ms: i64,
    breaker: Option<&str>,
    fetch: F,
) -> Result<Cached, SourceError>
where
    F: FnOnce() -> Result<Value, SourceError>,
{
    maybe_flush();
    if let Some(value) = read(key, ttl_ms) {
        return Ok(Cached {
            value,
            stale: false,
            age_secs: 0,
        });
    }

    // 熔断打开且冷却中：直接回退旧值，不发网络。
    if let Some(board) = breaker
        && breaker_blocked(board)
    {
        return fallback(key).ok_or(SourceError::Blocked {
            retry_at_ms: now_ms() + BREAKER_COOLDOWN_MS,
        });
    }

    if !inflight_enter(key) {
        // 已有他人在途：等它结束后重读缓存（它成功则这里命中）。
        inflight_wait(key);
        if let Some(value) = read(key, ttl_ms) {
            return Ok(Cached {
                value,
                stale: false,
                age_secs: 0,
            });
        }
        return match fallback(key) {
            Some(cached) => Ok(cached),
            None => Err(SourceError::Timeout),
        };
    }

    let outcome = fetch();
    inflight_exit(key);

    match outcome {
        Ok(value) => {
            if let Some(board) = breaker {
                breaker_success(board);
            }
            write(key, value.clone());
            Ok(Cached {
                value,
                stale: false,
                age_secs: 0,
            })
        }
        Err(error) => {
            if let Some(board) = breaker {
                breaker_failure(board);
            }
            match fallback(key) {
                Some(cached) => Ok(cached),
                None => Err(error),
            }
        }
    }
}

/// 兜底：读任意年龄 ≤24h 的旧值并标记 stale。
fn fallback(key: &str) -> Option<Cached> {
    let value = read(key, TTL_FALLBACK_MS)?;
    let age_secs = age_of(key).unwrap_or(0);
    Some(Cached {
        value,
        stale: true,
        age_secs,
    })
}

fn age_of(key: &str) -> Option<i64> {
    let cache = lock();
    let entry = cache.entries.get(key)?;
    Some(((now_ms() - entry.fetched_at_ms) / 1000).max(0))
}

/// 把 [`Cached`] 合并成信封 `data`：`value` 为对象时并入 `stale` / `ageSecs`。
pub fn into_data(cached: Cached) -> Value {
    let Cached {
        value,
        stale,
        age_secs,
    } = cached;
    match value {
        Value::Object(mut map) => {
            map.insert("stale".to_owned(), Value::Bool(stale));
            map.insert("ageSecs".to_owned(), json!(age_secs));
            Value::Object(map)
        }
        other => json!({ "items": other, "stale": stale, "ageSecs": age_secs }),
    }
}

/// 清空全部缓存（设置页「清除缓存」）。
pub fn clear() -> Result<Value, SourceError> {
    {
        let mut cache = lock();
        cache.entries.clear();
        cache.dirty = false;
        cache.last_flush_ms = 0;
    }
    BREAKERS.lock().expect("breakers poisoned").clear();
    if let Some(path) = path()
        && path.exists()
    {
        let _ = std::fs::remove_file(&path);
    }
    Ok(json!({ "cleared": true }))
}

/// 强制落盘（等这次写完）。
pub fn flush() -> Result<Value, SourceError> {
    let mut cache = lock();
    flush_locked(&mut cache);
    Ok(json!({ "flushed": !cache.dirty }))
}

/// 诊断：条数 / 字节数 / 是否脏 / 最旧条目年龄。
pub fn stats() -> Result<Value, SourceError> {
    let cache = lock();
    let bytes: usize = cache.entries.values().map(|e| e.value_json.len()).sum();
    let oldest_secs = cache
        .entries
        .values()
        .map(|e| e.fetched_at_ms)
        .min()
        .map(|t| ((now_ms() - t) / 1000).max(0))
        .unwrap_or(0);
    Ok(json!({
        "entries": cache.entries.len(),
        "bytes": bytes,
        "dirty": cache.dirty,
        "oldestSecs": oldest_secs,
        "maxEntries": MAX_ENTRIES,
    }))
}

/// 测量/集成测试专用：直接写入一条缓存条目（封面归一化照走，不走防抖落盘）。
#[cfg(test)]
pub(crate) fn seed_for_test(key: &str, value: Value) {
    write(key, value);
}

/// 测试专用：条目是否存在（新鲜度不限）。供播种类测试断言前置条件，
/// 把“种子被并行干扰抹掉”与“被测逻辑错误”区分开。
#[cfg(test)]
pub(crate) fn contains_for_test(key: &str) -> bool {
    ensure_loaded();
    lock().entries.contains_key(key)
}

/// 测量/集成测试专用：清空缓存、熔断与在途去重状态。
#[cfg(test)]
pub(crate) fn clear_for_test() {
    let mut cache = lock();
    cache.entries.clear();
    cache.dirty = false;
    cache.last_flush_ms = 0;
    cache.loaded = true;
    drop(cache);
    BREAKERS.lock().unwrap().clear();
    INFLIGHT.lock().unwrap().clear();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 缓存测试串行化：CACHE/BREAKERS/INFLIGHT 为进程静态，并行跑会互踩。
    fn reset() {
        let mut cache = lock();
        cache.entries.clear();
        cache.dirty = false;
        cache.last_flush_ms = 0;
        cache.loaded = true;
        drop(cache);
        BREAKERS.lock().unwrap().clear();
        INFLIGHT.lock().unwrap().clear();
    }

    #[test]
    fn keys_are_namespaced_by_source() {
        // 同分类/同榜/同关键词/同剧集 id 在不同源必须落不同 key，否则串库。
        assert_ne!(key_catalog("a", "c", 0), key_catalog("b", "c", 0));
        assert_ne!(key_catalog_depth("a", "c"), key_catalog_depth("b", "c"));
        assert_ne!(key_recommend("a"), key_recommend("b"));
        assert_ne!(key_ranking("a", "hot"), key_ranking("b", "hot"));
        assert_ne!(key_detail("a", "1"), key_detail("b", "1"));
        assert_ne!(key_search("a", "k"), key_search("b", "k"));
        assert_ne!(key_suggest("a", "k"), key_suggest("b", "k"));
        // 同源同参稳定（重启后续载/去重依赖）。
        assert_eq!(key_catalog("a", "c", 0), key_catalog("a", "c", 0));
    }

    #[test]
    fn fresh_hit_skips_network() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        let mut calls = 0;
        let first = cached("k", TTL_CATALOG_MS, None, || {
            calls += 1;
            Ok(json!({ "items": [1, 2] }))
        })
        .unwrap();
        assert_eq!(calls, 1);
        assert!(!first.stale);
        let second = cached("k", TTL_CATALOG_MS, None, || {
            calls += 1;
            Ok(json!({ "items": [9] }))
        })
        .unwrap();
        // 新鲜命中：闭包根本没被调用，返回的是第一次的值。
        assert_eq!(calls, 1);
        assert_eq!(second.value["items"], json!([1, 2]));
        reset();
    }

    #[test]
    fn network_failure_falls_back_to_stale_value() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        cached("k", TTL_CATALOG_MS, None, || Ok(json!({ "v": 1 }))).unwrap();
        // 把条目年龄推到 TTL 之外（直接改时间戳，不依赖真实等待）。
        {
            let mut cache = lock();
            if let Some(entry) = cache.entries.get_mut("k") {
                entry.fetched_at_ms = now_ms() - TTL_CATALOG_MS - 1;
            }
        }
        let fallback_value =
            cached("k", TTL_CATALOG_MS, None, || Err(SourceError::NotFound)).unwrap();
        assert!(fallback_value.stale, "网络失败必须回退旧值并标记 stale");
        assert_eq!(fallback_value.value["v"], json!(1));
        assert!(fallback_value.age_secs > 0);
        reset();
    }

    #[test]
    fn failure_without_cache_propagates_error() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        let error =
            cached("nope", TTL_CATALOG_MS, None, || Err(SourceError::NotFound)).unwrap_err();
        assert_eq!(error.code(), "NOT_FOUND", "无旧值时错误必须原样上抛");
        reset();
    }

    #[test]
    fn cover_is_stored_port_free_and_expanded_on_read() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        let url = "http://127.0.0.1:47800/img/abc.sig";
        cached("k", TTL_CATALOG_MS, None, || {
            Ok(json!({ "items": [{ "cover": url }] }))
        })
        .unwrap();
        // 落盘形态必须不含端口——端口是实现细节，不该进缓存。
        let stored = lock().entries["k"].value_json.clone();
        assert!(!stored.contains("47800"), "缓存里不该出现端口：{stored}");
        assert!(
            stored.contains("drama-img:abc.sig"),
            "应为规范形式：{stored}"
        );
        reset();
    }

    #[test]
    fn canonical_cover_roundtrip() {
        assert_eq!(
            canonical_cover("http://127.0.0.1:47800/img/abc.sig").as_deref(),
            Some("drama-img:abc.sig")
        );
        assert_eq!(
            expand_cover("drama-img:abc.sig", 47812).as_deref(),
            Some("http://127.0.0.1:47812/img/abc.sig")
        );
        // 非本机代理地址原样保留（不该被误伤）。
        assert_eq!(canonical_cover("https://cdn.example.com/a.jpg"), None);
    }

    #[test]
    fn breaker_opens_after_repeated_failures() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        for _ in 0..BREAKER_THRESHOLD {
            let result = cached("ranking:hot", TTL_RANKING_MS, Some("hot"), || {
                Err(SourceError::NotFound)
            });
            assert!(result.is_err(), "无旧值时失败应上抛");
        }
        assert!(breaker_blocked("hot"), "连续失败后熔断应打开");
        // 熔断中但无旧值 → 抛可重试错误，而不是沉默返回空。
        let error = cached("ranking:hot", TTL_RANKING_MS, Some("hot"), || {
            Ok(json!({ "v": 1 }))
        })
        .unwrap_err();
        assert!(error.retry(), "熔断错误必须是可重试的");
        breaker_success("hot");
        assert!(!breaker_blocked("hot"), "成功后熔断应关闭");
        reset();
    }

    #[test]
    fn breaker_does_not_affect_other_boards() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        for _ in 0..BREAKER_THRESHOLD {
            let _ = cached("ranking:a", TTL_RANKING_MS, Some("a"), || {
                Err(SourceError::NotFound)
            });
        }
        assert!(breaker_blocked("a"));
        assert!(
            !breaker_blocked("b"),
            "熔断必须按板独立，否则一个坏榜拖垮全部"
        );
        reset();
    }

    #[test]
    fn depth_only_grows() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        write_depth(key_catalog_depth("hongguo", "real-drama").as_str(), 3);
        assert_eq!(
            read_depth(&key_catalog_depth("hongguo", "real-drama")),
            Some(3)
        );
        write_depth(key_catalog_depth("hongguo", "real-drama").as_str(), 2);
        assert_eq!(
            read_depth(&key_catalog_depth("hongguo", "real-drama")),
            Some(3)
        );
        write_depth(key_catalog_depth("hongguo", "real-drama").as_str(), 5);
        assert_eq!(
            read_depth(&key_catalog_depth("hongguo", "real-drama")),
            Some(5)
        );
        reset();
    }

    #[test]
    fn eviction_caps_entries_at_max() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        for i in 0..MAX_ENTRIES + 20 {
            write(&format!("k{i}"), json!({ "i": i }));
        }
        let count = lock().entries.len();
        assert!(count <= MAX_ENTRIES, "条数必须被淘汰到上限内，实际 {count}");
        reset();
    }

    #[test]
    fn clear_drops_everything() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        write("k", json!({ "v": 1 }));
        clear().unwrap();
        assert!(lock().entries.is_empty());
        let stats = stats().unwrap();
        assert_eq!(stats["entries"], json!(0));
        reset();
    }

    #[test]
    fn into_data_merges_stale_flag() {
        let data = into_data(Cached {
            value: json!({ "items": [] }),
            stale: true,
            age_secs: 42,
        });
        assert_eq!(data["stale"], json!(true));
        assert_eq!(data["ageSecs"], json!(42));
        assert_eq!(data["items"], json!([]));
    }

    // ── 性能测量 ──────────────────────────────────────────────────────
    //
    // 用 `cargo test --release -- --ignored --nocapture` 跑。
    // 之所以不用 Criterion：它会往依赖图里加新 crate，而缓存命中是
    // 微秒级操作，受首端口绑定等一次性成本干扰较大——这里用 release
    // 下的重复采样 + 分位数足够判断量级与回归。

    /// 构造一页目录（20 条，含封面代理地址），贴近首页真实负载。
    fn sample_page(page: u32) -> Value {
        let items: Vec<Value> = (0..20)
            .map(|i| {
                json!({
                    "id": format!("{page}-{i}"),
                    "title": "剧集标题",
                    "categoryId": "real-drama",
                    "categoryName": "真人短剧",
                    "episodeCount": 80,
                    "summary": "一句话简介，用于列表副标题展示。",
                    "tags": ["都市", "反转"],
                    "status": "ongoing",
                    "vip": false,
                    "cover": format!("http://127.0.0.1:47800/img/tok{page}_{i}.sig"),
                })
            })
            .collect();
        json!({ "items": items, "hasMore": true })
    }

    /// 分位数（已排序切片，线性插值）。
    fn percentile(sorted: &[f64], p: f64) -> f64 {
        if sorted.is_empty() {
            return 0.0;
        }
        let idx = ((sorted.len() - 1) as f64 * p) as usize;
        sorted[idx]
    }

    #[test]
    #[ignore = "性能测量：需 release，见模块内说明"]
    fn bench_cache_hit_path() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        // 预热：端口绑定是一次性成本，先付掉，避免污染第一次采样。
        let port = crate::covers::media_port();
        println!("media_port = {port:?}（预热后）");

        const PAGES: u32 = 20;
        for page in 0..PAGES {
            write(
                &key_catalog("hongguo", "real-drama", page),
                sample_page(page),
            );
        }

        // 1) 缓存命中（含封面端口展开 + JSON 序列化出参）——真实首页路径。
        const RUNS: usize = 2000;
        let mut samples = Vec::with_capacity(RUNS);
        for i in 0..RUNS {
            let key = key_catalog("hongguo", "real-drama", (i as u32) % PAGES);
            let start = Instant::now();
            let hit = cached(&key, TTL_CATALOG_MS, None, || {
                Err(SourceError::NotFound) // 命中时根本不会被调用
            })
            .expect("缓存命中");
            samples.push(start.elapsed().as_secs_f64() * 1e6);
            assert!(!hit.stale);
        }
        samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!(
            "缓存命中（20 条/页，含封面展开）: p50={:.1}µs p95={:.1}µs p99={:.1}µs",
            percentile(&samples, 0.50),
            percentile(&samples, 0.95),
            percentile(&samples, 0.99),
        );

        // 2) 出参体积：这就是每次 FFI 往返要序列化 + Dart 侧要解析的量。
        let hit = cached(
            &key_catalog("hongguo", "real-drama", 0),
            TTL_CATALOG_MS,
            None,
            || Err(SourceError::NotFound),
        )
        .unwrap();
        let json = serde_json::to_string(&hit.value).unwrap();
        println!("单页出参体积: {} 字节（20 条）", json.len());

        // 3) 落盘体积：封面已是规范形式（无端口），比存完整 URL 更短。
        let stored = lock().entries[&key_catalog("hongguo", "real-drama", 0)]
            .value_json
            .clone();
        println!("单页落盘体积: {} 字节（封面为规范形式）", stored.len());

        reset();
    }

    /// 首页「重启续载」的往返成本：N 次 `catalog` vs 1 次 `catalogPages`。
    ///
    /// 这是本次优化最直接的收益——旧实现里 Dart 侧循环 `depth` 次
    /// `catalog()`，每次都是一次完整 FFI 往返（含**两端**各一次 JSON
    /// 编解码）；新实现一次往返取回全部页，缓存命中的页在 Rust 内瞬时返回。
    #[test]
    #[ignore = "性能测量：需 release，见模块内说明"]
    fn bench_home_resume_roundtrips() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        let _ = crate::covers::media_port(); // 预热端口绑定

        const DEPTH: u32 = 5;
        for page in 0..DEPTH {
            write(
                &key_catalog("hongguo", "real-drama", page),
                sample_page(page),
            );
        }

        // A：旧路径等价——Dart 循环 depth 次 catalog（每次一次 FFI 往返）。
        const ROUNDS: usize = 200;
        let per_resume_old = best_of(
            || {
                let start = Instant::now();
                for _ in 0..ROUNDS {
                    for page in 0..DEPTH {
                        let out = crate::dispatch(&format!(
                            r#"{{"v":1,"op":"catalog","params":{{"category":"real-drama","page":{page}}}}}"#
                        ));
                        assert_eq!(out["ok"], json!(true));
                    }
                }
                start.elapsed().as_secs_f64() * 1e6 / ROUNDS as f64
            },
            5,
        );

        // B：新路径——一次 catalogPages 取回全部页。
        let per_resume_new = best_of(
            || {
                let start = Instant::now();
                for _ in 0..ROUNDS {
                    let out = crate::dispatch(
                        r#"{"v":1,"op":"catalogPages","params":{"category":"real-drama","depth":5}}"#,
                    );
                    assert_eq!(out["ok"], json!(true));
                    assert_eq!(
                        out["data"]["pages"].as_array().unwrap().len(),
                        DEPTH as usize
                    );
                }
                start.elapsed().as_secs_f64() * 1e6 / ROUNDS as f64
            },
            5,
        );

        println!(
            "首页续载 depth={DEPTH}（缓存命中，Rust 侧）: 旧 {DEPTH} 次往返={per_resume_old:.1}µs \
             / 新 1 次往返={per_resume_new:.1}µs → Rust 侧比值 {:.2}x\n\
             注：两者在 Rust 侧**同量级**（差异在噪声内）——真正省下的是 Dart 侧的 \
             {} 次 FFI 往返（隔离投递 + 两端 JSON 编解码 + 逐条封面 Uri 改写），\
             这部分不在本测量内。",
            per_resume_old / per_resume_new,
            DEPTH - 1,
        );

        reset();
    }

    /// 多组取最小：本机负载波动大（同一项多次测量能差 40%），
    /// 最小值最接近"无干扰"下的真实成本。
    fn best_of<F: FnMut() -> f64>(mut measure: F, groups: usize) -> f64 {
        (0..groups).map(|_| measure()).fold(f64::INFINITY, f64::min)
    }

    #[test]
    fn stats_reports_entry_count_and_bytes() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        reset();
        write("k", json!({ "v": 1 }));
        let stats = stats().unwrap();
        assert_eq!(stats["entries"], json!(1));
        assert!(stats["bytes"].as_u64().unwrap() > 0);
        assert_eq!(stats["maxEntries"], json!(MAX_ENTRIES));
        reset();
    }
}
