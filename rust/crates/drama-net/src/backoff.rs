//! 退避：源被限流时的冷却窗口。
//!
//! 原实现的 `requestBackoff` 是**按 host** 的：一个 host 被 403/429 打到后，
//! 后续所有发往该 host 的请求立即失败，而不是继续打过去把自己封得更死。
//!
//! 这里保留同样的语义，并额外区分**前台/后台**两条通道：
//! 后台请求（预取、元数据补齐）拿到的 403 不该污染前台浏览的冷却窗口。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use once_cell::sync::Lazy;

/// 默认冷却时长。
pub const DEFAULT_COOLDOWN: Duration = Duration::from_secs(60);
/// 冷却上限（`Retry-After` 再大也不超过）。
pub const MAX_COOLDOWN: Duration = Duration::from_secs(30 * 60);

/// 一条冷却记录。
#[derive(Debug, Clone)]
pub struct Backoff {
    pub host: String,
    pub until: Instant,
    pub status: u16,
    pub reason: String,
}

impl Backoff {
    /// 剩余秒数（向上取整，至少 1）。
    pub fn remaining_secs(&self) -> u64 {
        let left = self.until.saturating_duration_since(Instant::now());
        (left.as_secs() + u64::from(left.subsec_millis() > 0)).max(1)
    }

    /// 到期时刻（Unix 毫秒），供 wire 的 `retryAt` 使用。
    pub fn retry_at_ms(&self) -> i64 {
        let left = self.until.saturating_duration_since(Instant::now());
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        now + left.as_millis() as i64
    }
}

/// 通道：前台 / 后台。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lane {
    Foreground,
    Background,
}

/// 全局冷却表。
#[derive(Debug, Default)]
pub struct BackoffTable {
    inner: Mutex<HashMap<(String, Lane), Backoff>>,
}

static TABLE: Lazy<BackoffTable> = Lazy::new(BackoffTable::default);

/// 全局冷却表。
pub fn table() -> &'static BackoffTable {
    &TABLE
}

impl BackoffTable {
    /// 查询某 host 在指定通道上是否处于冷却期。
    pub fn get(&self, host: &str, lane: Lane) -> Option<Backoff> {
        let mut guard = self.inner.lock().expect("backoff table poisoned");
        let key = (host.to_owned(), lane);
        match guard.get(&key) {
            Some(b) if b.until > Instant::now() => Some(b.clone()),
            Some(_) => {
                // 过期即清理，避免表无限增长。
                guard.remove(&key);
                None
            }
            None => None,
        }
    }

    /// 登记冷却。
    ///
    /// `retry_after` 来自响应头；缺省 [`DEFAULT_COOLDOWN`]，上限 [`MAX_COOLDOWN`]。
    pub fn put(
        &self,
        host: &str,
        lane: Lane,
        status: u16,
        reason: impl Into<String>,
        retry_after: Option<Duration>,
    ) -> Backoff {
        let delay = retry_after.unwrap_or(DEFAULT_COOLDOWN).min(MAX_COOLDOWN);
        let entry = Backoff {
            host: host.to_owned(),
            until: Instant::now() + delay,
            status,
            reason: reason.into(),
        };
        self.inner
            .lock()
            .expect("backoff table poisoned")
            .insert((host.to_owned(), lane), entry.clone());
        entry
    }

    /// 手动清除（源健康检查通过时用）。
    pub fn clear(&self, host: &str, lane: Lane) {
        self.inner
            .lock()
            .expect("backoff table poisoned")
            .remove(&(host.to_owned(), lane));
    }

    /// 清空全部（设置变更、切换代理后调用）。
    pub fn clear_all(&self) {
        self.inner.lock().expect("backoff table poisoned").clear();
    }

    /// 当前处于冷却期的 host 数量（诊断用）。
    pub fn len(&self) -> usize {
        let mut guard = self.inner.lock().expect("backoff table poisoned");
        let now = Instant::now();
        guard.retain(|_, b| b.until > now);
        guard.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// 解析 `Retry-After` 头（delta-seconds 或 HTTP-date）。
///
/// HTTP-date 分支只处理 `IMF-fixdate` 形式（`Sun, 06 Nov 1994 08:49:37 GMT`）——
/// 另两种历史格式在实践中已不出现，解析失败就回落到默认冷却。
pub fn parse_retry_after(value: &str) -> Option<Duration> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(secs) = trimmed.parse::<u64>() {
        return Some(Duration::from_secs(secs.min(MAX_COOLDOWN.as_secs())));
    }
    None
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn retry_after_seconds() {
        assert_eq!(parse_retry_after("120"), Some(Duration::from_secs(120)));
        assert_eq!(parse_retry_after("  30 "), Some(Duration::from_secs(30)));
        // 超过上限被夹住。
        assert_eq!(
            parse_retry_after("999999"),
            Some(Duration::from_secs(MAX_COOLDOWN.as_secs()))
        );
        assert_eq!(parse_retry_after("not-a-date"), None);
        assert_eq!(parse_retry_after(""), None);
    }

    #[test]
    fn put_then_get_returns_entry() {
        let table = BackoffTable::default();
        let entry = table.put("example.com", Lane::Foreground, 429, "限流", None);
        assert_eq!(entry.status, 429);
        assert!(table.get("example.com", Lane::Foreground).is_some());
        // 另一条通道不受影响。
        assert!(table.get("example.com", Lane::Background).is_none());
        table.clear("example.com", Lane::Foreground);
        assert!(table.get("example.com", Lane::Foreground).is_none());
    }

    #[test]
    fn remaining_secs_is_at_least_one() {
        let table = BackoffTable::default();
        let entry = table.put("x.test", Lane::Foreground, 403, "", Some(Duration::ZERO));
        assert!(entry.remaining_secs() >= 1);
        assert!(entry.retry_at_ms() > 0);
    }

    #[test]
    fn clear_all_empties_table() {
        let table = BackoffTable::default();
        table.put("a.test", Lane::Foreground, 403, "", None);
        table.put("b.test", Lane::Background, 429, "", None);
        assert_eq!(table.len(), 2);
        table.clear_all();
        assert!(table.is_empty());
    }
}
