//! 出网层：**全工程唯一**的 HTTP 出口。
//!
//! 任何 crate 直接 `use reqwest` 都是 bug。把限流、退避、超时、代理、错误分类
//! 集中在这里，才能保证「换个源不用重写网络策略」。
//!
//! ## 驱动方式
//!
//! C ABI 的 `drama_request` 是同步入口，由 worker 线程串行消费，因此这里用
//! **异步 reqwest + 全局多线程 Tokio 运行时**，由 [`block_on`] 驱动。
//! block 的是 worker 线程，不是 UI isolate。
//!
//! ## 两条通道
//!
//! - **元数据**（目录/详情/搜索/榜单）：走限流器（并发上限 + 同源最小间隔）、
//!   20 s 总超时、退避重试；
//! - **媒体**（取流/下载/封面）：**不走**限流器、**不设**总超时——
//!   长视频边下边播不能被总超时切断，只保留连接超时与读空闲看门狗。

pub mod backoff;
pub mod client;
pub mod error;
pub mod limiter;
pub mod proxy;

pub use client::{
    DESKTOP_UA, HttpClient, MediaResponse, RequestSpec, USER_AGENT_VALUE, fetch_json,
    fetch_json_custom, fetch_text, fetch_text_throttled, probe_playable,
};
pub use error::{HttpError, HttpErrorKind};
pub use limiter::{LimiterSettings, Priority};

use once_cell::sync::Lazy;

/// 全局多线程 Tokio 运行时（4 个 worker 线程）。
///
/// 4 而不是 2：原实现用 2，实测在首页并发打 `catalog`/`recommend`/`ranking`/`categories`
/// 时，一个慢请求会占住一个 worker，导致 `cancelRead` 排队。
static RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .thread_name("drama-net")
        .enable_all()
        .build()
        .expect("build tokio runtime")
});

/// 在全局运行时上阻塞执行。
///
/// # Panics
///
/// 若在运行时工作线程内调用会 panic（嵌套 `block_on`）。生产路径只从
/// FFI worker 线程进入，不要在 `async` 上下文里调用。
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    RUNTIME.block_on(future)
}

/// 运行时句柄（供需要 spawn 的模块使用）。
pub fn handle() -> tokio::runtime::Handle {
    RUNTIME.handle().clone()
}
