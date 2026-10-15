//! 取消协议：`session`/`sequence` 仲裁 + 在途注册表 + `cancelRead`。
//!
//! **契约纪律**：取消是**协作式**的——核心语义是"标记取消 + 丢弃迟到响应"；
//! 若调用方另外持有取消令牌（见 [`CancellationToken`]），`cancelRead` 可**尽力**提前
//! 释放被阻塞的读请求，但**不保证立即中断对端 socket**（最坏情况下在途请求仍会
//! 占住一个 worker isolate 直到其内层超时到期）。
//!
//! 核心是**纯函数** [`arbitrate`]：给定注册表状态快照 + 本次 `sequence` + 阶段，
//! 输出 [`Decision`]，因此仲裁逻辑可完全离线单测（不联网、不依赖全局状态）。

use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;

use once_cell::sync::Lazy;
use tokio_util::sync::CancellationToken;

/// `session` 最大长度（`[0-9a-zA-Z-_:.]`，≥1 且 ≤128）。
const MAX_SESSION_LEN: usize = 128;

/// 仲裁阶段。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// 读请求进入（网络请求发出前）。
    Enter,
    /// 读请求收尾（成功或失败结果已就绪）。
    Complete,
}

/// 仲裁判定。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// 放行。
    Continue,
    /// 被更新的 `sequence` 取代，或已被 `cancelRead` 覆盖：丢弃。
    Canceled,
}

/// `session` 合法性：字符集 `[0-9a-zA-Z-_:.]`，长度 ∈ `[1, 128]`。
///
/// 字符集全为 ASCII，故按字节长度校验等价于按字符长度。
pub fn is_valid_session(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_SESSION_LEN
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':' | b'.'))
}

/// **纯仲裁函数**（离线可测）：由注册表状态快照 + 本次 `sequence` + 阶段得出判定。
///
/// - [`Phase::Enter`]：本请求 `sequence` **小于**已记录的 `latest` → 旧请求，直接 `Canceled`
///   （旧 `sequence` 的请求在网络发出前即被丢弃）。
/// - [`Phase::Complete`]：`latest` 已被更大的 `sequence` 覆盖（`latest > sequence`），
///   或本请求 `sequence ≤ cancel_before` → 迟到响应丢弃，`Canceled`。
pub fn arbitrate(
    latest: Option<u64>,
    cancel_before: Option<u64>,
    sequence: u64,
    phase: Phase,
) -> Decision {
    match phase {
        Phase::Enter => match latest {
            Some(l) if sequence < l => Decision::Canceled,
            _ => Decision::Continue,
        },
        Phase::Complete => {
            let superseded = latest.is_some_and(|l| l > sequence);
            let canceled = cancel_before.is_some_and(|b| sequence <= b);
            if superseded || canceled {
                Decision::Canceled
            } else {
                Decision::Continue
            }
        }
    }
}

/// 每个 session 的仲裁状态：只保留 `latest` / `cancel_before` 两个标量 +
/// 一个**有界**的活跃表（上限 = 前台在途 ≤16，不会无界增长）。
#[derive(Default)]
struct SessionEntry {
    /// 已进入的最大 `sequence`。
    latest: Option<u64>,
    /// `cancelRead` 设置：取消所有 `sequence` **小于**该值的在途请求。
    cancel_before: Option<u64>,
    /// 在途读请求的 `sequence` → 其取消令牌（供 `cancelRead` 尽力提前释放）。
    active: BTreeMap<u64, CancellationToken>,
}

/// 全局注册表（session → 状态）。`session` 生命周期 = App 生命周期，条目数很小。
static REGISTRY: Lazy<Mutex<HashMap<String, SessionEntry>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// 取注册表锁（中毒时取回内部数据，避免 panic 扩散到 FFI 边界）。
fn lock() -> std::sync::MutexGuard<'static, HashMap<String, SessionEntry>> {
    REGISTRY.lock().unwrap_or_else(|e| e.into_inner())
}

/// 读请求进入：按 [`Phase::Enter`] 仲裁；放行时更新 `latest` 并登记在途令牌。
///
/// 返回 [`Decision::Canceled`] 时**不登记**、不更新 `latest`（旧请求直接作废）。
pub fn begin(session: &str, sequence: u64, token: CancellationToken) -> Decision {
    let mut map = lock();
    let entry = map.entry(session.to_owned()).or_default();
    let decision = arbitrate(entry.latest, entry.cancel_before, sequence, Phase::Enter);
    if decision == Decision::Continue {
        entry.latest = Some(sequence);
        entry.active.insert(sequence, token);
    }
    decision
}

/// 读请求收尾：移出在途表，按 [`Phase::Complete`] 仲裁决定是否丢弃结果；
/// 在途表清空即回收该 session 条目（防无界增长）。
pub fn complete(session: &str, sequence: u64) -> Decision {
    let mut map = lock();
    let (decision, empty) = match map.get_mut(session) {
        Some(entry) => {
            entry.active.remove(&sequence);
            let decision = arbitrate(entry.latest, entry.cancel_before, sequence, Phase::Complete);
            (decision, entry.active.is_empty())
        }
        None => (Decision::Continue, false),
    };
    if empty {
        map.remove(session);
    }
    decision
}

/// `cancelRead`：把 `cancel_before` 抬到 `sequence`，取消所有在途的 `sequence < sequence`
/// 的读请求并返回其数量。
///
/// **不阻塞、不参与仲裁**；不存在的 session 返回 `0`（不为其建条目）。
pub fn cancel_read(session: &str, sequence: u64) -> usize {
    let mut map = lock();
    let Some(entry) = map.get_mut(session) else {
        return 0;
    };
    entry.cancel_before = Some(entry.cancel_before.map_or(sequence, |b| b.max(sequence)));
    let mut canceled = 0;
    for (_, token) in entry.active.range(..sequence) {
        token.cancel();
        canceled += 1;
    }
    canceled
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_charset_and_length() {
        assert!(is_valid_session("app"));
        assert!(is_valid_session("a-b_c:.9"));
        assert!(is_valid_session(&"a".repeat(MAX_SESSION_LEN)));
        assert!(!is_valid_session(""));
        assert!(!is_valid_session("has space"));
        assert!(!is_valid_session("bad!"));
        assert!(!is_valid_session("中文"));
        assert!(!is_valid_session(&"a".repeat(MAX_SESSION_LEN + 1)));
    }

    #[test]
    fn arbitrate_enter_rejects_older_sequence() {
        assert_eq!(
            arbitrate(Some(10), None, 3, Phase::Enter),
            Decision::Canceled
        );
        assert_eq!(
            arbitrate(Some(10), None, 10, Phase::Enter),
            Decision::Continue
        );
        assert_eq!(
            arbitrate(Some(10), None, 11, Phase::Enter),
            Decision::Continue
        );
        assert_eq!(arbitrate(None, None, 1, Phase::Enter), Decision::Continue);
    }

    #[test]
    fn arbitrate_complete_drops_superseded_and_canceled() {
        // `latest` 已被更大的 sequence 覆盖 → 迟到响应丢弃。
        assert_eq!(
            arbitrate(Some(11), None, 5, Phase::Complete),
            Decision::Canceled
        );
        // 本请求 sequence ≤ cancel_before → 丢弃。
        assert_eq!(
            arbitrate(Some(5), Some(5), 5, Phase::Complete),
            Decision::Canceled
        );
        // cancel_before 更小、latest 未被覆盖 → 放行。
        assert_eq!(
            arbitrate(Some(5), Some(4), 5, Phase::Complete),
            Decision::Continue
        );
        assert_eq!(
            arbitrate(Some(5), None, 5, Phase::Complete),
            Decision::Continue
        );
    }

    #[test]
    fn begin_marks_latest_and_cancel_read_counts_inflight() {
        // 独立 session 名，避免与并行测试共享的全局注册表冲突。
        let s = "unit-cancel-count";
        assert_eq!(begin(s, 5, CancellationToken::new()), Decision::Continue);
        assert_eq!(begin(s, 6, CancellationToken::new()), Decision::Continue);
        // 只有 seq 5 < 6，故被标记取消 1 个。
        assert_eq!(cancel_read(s, 6), 1);
        assert_eq!(cancel_read(s, 7), 2);
        // 不存在 session → 0。
        assert_eq!(cancel_read("unit-no-such-session", 9), 0);
        // 收尾：被 cancel_before 覆盖 → 双方均 Canceled。
        assert_eq!(complete(s, 5), Decision::Canceled);
        assert_eq!(complete(s, 6), Decision::Canceled);
    }

    #[test]
    fn cancel_read_cancels_inflight_token() {
        let s = "unit-token-cancel";
        let token = CancellationToken::new();
        assert_eq!(begin(s, 5, token.clone()), Decision::Continue);
        assert!(!token.is_cancelled());
        assert_eq!(cancel_read(s, 6), 1);
        // 令牌被触发：在途 HTTP future 会经 `tokio::select!` 提前释放。
        assert!(token.is_cancelled());
        let _ = complete(s, 5);
    }

    #[test]
    fn complete_reports_superseded_when_newer_request_arrived() {
        let s = "unit-supersede";
        assert_eq!(begin(s, 5, CancellationToken::new()), Decision::Continue);
        assert_eq!(begin(s, 6, CancellationToken::new()), Decision::Continue);
        // 后到的 6 覆盖 latest；5 收尾应被判为 Canceled。
        assert_eq!(complete(s, 5), Decision::Canceled);
        assert_eq!(complete(s, 6), Decision::Continue);
    }
}
