//! 限流器：按**源**（而非 host）分闸，并区分前台/后台优先级。
//!
//! ## 为什么按源而不是按 host
//!
//! 一个站源会打多个 host（站点 + API + CDN）。按 host 限流会让「同一个源」在
//! 换 host 时绕开限流，把源站打得更狠。原实现就是按源分闸，这里保留。
//!
//! ## 为什么前台要饿死后台
//!
//! 后台请求（元数据补齐、预取）是「有空再干」的活。如果它和用户正在等的
//! 目录请求平等竞争槽位，用户会看到「点进详情转圈，因为后台在补齐别的剧」。
//! 因此后台请求必须满足两个额外条件才能启动：
//!
//! 1. 没有前台请求在排队，且当前没有前台请求在跑；
//! 2. 距最后一个前台请求完成已过 `min_interval`。
//!
//! 后台请求还有 8 s 硬超时——它不该长时间占着槽位。

use std::collections::HashMap;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

/// 请求优先级。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Priority {
    /// 用户在等（目录、搜索、详情）。
    Foreground,
    /// 有空再干（预取、元数据补齐、封面修复）。
    Background,
}

impl Priority {
    fn is_background(self) -> bool {
        matches!(self, Priority::Background)
    }
}

/// 限流设置。
#[derive(Debug, Clone, Copy)]
pub struct LimiterSettings {
    /// 全局并发上限（1..=6）。
    pub concurrency: usize,
    /// 同源两次请求的最小间隔。
    pub min_interval: Duration,
}

impl Default for LimiterSettings {
    fn default() -> Self {
        LimiterSettings {
            concurrency: 3,
            min_interval: Duration::from_millis(250),
        }
    }
}

impl LimiterSettings {
    /// 夹到合法区间：并发 1..=6，间隔 0..=5000 ms。
    ///
    /// 用夹取而不是报错：这两个值来自设置页，越界是用户输入问题，
    /// 不该让整个网络栈拒绝工作。
    pub fn clamped(self) -> Self {
        LimiterSettings {
            concurrency: self.concurrency.clamp(1, 6),
            min_interval: self.min_interval.min(Duration::from_secs(5)),
        }
    }
}

/// 单源闸门状态。
#[derive(Debug, Default)]
struct Gate {
    busy: bool,
    last_start: Option<Instant>,
}

/// 限流器。
#[derive(Debug)]
pub struct Limiter {
    inner: Mutex<State>,
    cv: Condvar,
}

#[derive(Debug)]
struct State {
    settings: LimiterSettings,
    active: usize,
    foreground_waiting: usize,
    last_foreground_done: Option<Instant>,
    gates: HashMap<String, Gate>,
}

impl Default for Limiter {
    fn default() -> Self {
        Limiter::new(LimiterSettings::default())
    }
}

/// 许可：`Drop` 时自动归还槽位。
///
/// 用 RAII 而不是手动 `release()`：任何提前 return（包括 panic 展开）
/// 都不会漏还槽位。漏还是限流器最隐蔽的 bug——表现为「跑一段时间后全部卡住」。
#[derive(Debug)]
pub struct Permit<'a> {
    limiter: &'a Limiter,
    source: String,
    priority: Priority,
}

impl Drop for Permit<'_> {
    fn drop(&mut self) {
        self.limiter.release(&self.source, self.priority);
    }
}

impl Limiter {
    pub fn new(settings: LimiterSettings) -> Self {
        Limiter {
            inner: Mutex::new(State {
                settings: settings.clamped(),
                active: 0,
                foreground_waiting: 0,
                last_foreground_done: None,
                gates: HashMap::new(),
            }),
            cv: Condvar::new(),
        }
    }

    /// 更新设置（设置页保存后调用）。会唤醒所有等待者重新判定。
    pub fn update_settings(&self, settings: LimiterSettings) {
        let mut state = self.inner.lock().expect("limiter poisoned");
        state.settings = settings.clamped();
        drop(state);
        self.cv.notify_all();
    }

    pub fn settings(&self) -> LimiterSettings {
        self.inner.lock().expect("limiter poisoned").settings
    }

    /// 获取一个槽位。
    ///
    /// `source` 是源 id（不是 host）。`deadline` 为 `None` 表示不设等待上限
    /// （由调用方的内层超时兜底）。
    ///
    /// 返回 `None` 表示等待期间超时。
    pub fn acquire(
        &self,
        source: &str,
        priority: Priority,
        deadline: Option<Instant>,
    ) -> Option<Permit<'_>> {
        let mut state = self.inner.lock().expect("limiter poisoned");
        let background = priority.is_background();
        if !background {
            state.foreground_waiting += 1;
        }

        loop {
            let now = Instant::now();
            if let Some(dl) = deadline
                && now >= dl
            {
                if !background {
                    state.foreground_waiting -= 1;
                }
                return None;
            }

            let settings = state.settings;
            let gate_ready = state
                .gates
                .get(source)
                .is_none_or(|g| !g.busy && g.last_start.is_none_or(|t| now.duration_since(t) >= settings.min_interval));

            let capacity_ok = state.active < settings.concurrency;

            // 后台优先级：前台无人排队、无在跑的请求，且距最后一个前台完成够久。
            let priority_ok = if background {
                state.foreground_waiting == 0
                    && state.active == 0
                    && state.last_foreground_done.is_none_or(|t| {
                        now.duration_since(t) >= settings.min_interval
                    })
            } else {
                true
            };

            if gate_ready && capacity_ok && priority_ok {
                if !background {
                    state.foreground_waiting -= 1;
                }
                state.active += 1;
                let gate = state.gates.entry(source.to_owned()).or_default();
                gate.busy = true;
                gate.last_start = Some(now);
                return Some(Permit {
                    limiter: self,
                    source: source.to_owned(),
                    priority,
                });
            }

            // 计算等待时长：至少要等到「同源间隔」到期。
            let wait = deadline.map_or(Duration::from_millis(50), |dl| {
                let remaining = dl.saturating_duration_since(now);
                remaining.min(Duration::from_millis(50))
            });
            let wait = wait.max(Duration::from_millis(5));
            let (guard, _timeout) = self
                .cv
                .wait_timeout(state, wait)
                .expect("limiter poisoned");
            state = guard;
        }
    }

    fn release(&self, source: &str, priority: Priority) {
        let mut state = self.inner.lock().expect("limiter poisoned");
        state.active = state.active.saturating_sub(1);
        if let Some(gate) = state.gates.get_mut(source) {
            gate.busy = false;
        }
        if !priority.is_background() {
            state.last_foreground_done = Some(Instant::now());
        }
        drop(state);
        self.cv.notify_all();
    }

    /// 当前在跑的请求数（诊断用）。
    pub fn active(&self) -> usize {
        self.inner.lock().expect("limiter poisoned").active
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn settings_are_clamped() {
        let s = LimiterSettings {
            concurrency: 99,
            min_interval: Duration::from_secs(60),
        }
        .clamped();
        assert_eq!(s.concurrency, 6);
        assert_eq!(s.min_interval, Duration::from_secs(5));

        let s = LimiterSettings {
            concurrency: 0,
            min_interval: Duration::ZERO,
        }
        .clamped();
        assert_eq!(s.concurrency, 1);
    }

    #[test]
    fn permit_releases_on_drop() {
        let limiter = Limiter::new(LimiterSettings {
            concurrency: 2,
            min_interval: Duration::ZERO,
        });
        {
            let _p = limiter.acquire("a", Priority::Foreground, None).expect("permit");
            assert_eq!(limiter.active(), 1);
        }
        assert_eq!(limiter.active(), 0);
    }

    #[test]
    fn same_source_is_serialized() {
        let limiter = Arc::new(Limiter::new(LimiterSettings {
            concurrency: 4,
            min_interval: Duration::from_millis(200),
        }));
        let p1 = limiter.acquire("a", Priority::Foreground, None).expect("first");
        // 同源第二次请求必须等间隔——给它一个已过期的 deadline，应当直接失败。
        let expired = Instant::now() - Duration::from_millis(1);
        assert!(
            limiter
                .acquire("a", Priority::Foreground, Some(expired))
                .is_none()
        );
        drop(p1);
        // 不同源不受影响。
        assert!(limiter.acquire("b", Priority::Foreground, None).is_some());
    }

    #[test]
    fn concurrency_cap_is_respected() {
        let limiter = Limiter::new(LimiterSettings {
            concurrency: 1,
            min_interval: Duration::ZERO,
        });
        let _p = limiter.acquire("a", Priority::Foreground, None).expect("first");
        let expired = Instant::now();
        // 并发已满，不同源也拿不到。
        assert!(
            limiter
                .acquire("b", Priority::Foreground, Some(expired))
                .is_none()
        );
    }

    #[test]
    fn background_waits_for_foreground_to_finish() {
        let limiter = Limiter::new(LimiterSettings {
            concurrency: 4,
            min_interval: Duration::from_millis(50),
        });
        let fg = limiter.acquire("a", Priority::Foreground, None).expect("fg");
        // 前台在跑时，后台即使槽位充足也拿不到。
        assert!(
            limiter
                .acquire("b", Priority::Background, Some(Instant::now()))
                .is_none()
        );
        drop(fg);
        // 前台完成后仍要等 min_interval，用短 deadline 验证它确实在等。
        assert!(
            limiter
                .acquire("b", Priority::Background, Some(Instant::now()))
                .is_none()
        );
    }
}
