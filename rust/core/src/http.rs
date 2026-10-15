//! HTTP 会话 / 限流 / 退避。
//!
//! **驱动方式**：C ABI 的 `drama_request` 是同步入口，由 Dart worker isolate 单线程消费，
//! 因此这里用**异步 reqwest + 全局多线程 Tokio 运行时**，由 `RUNTIME.block_on(...)` 驱动。
//! block 的是调用线程（worker），不是 UI isolate。若将来在已有 Tokio 上下文内调用会 panic，
//! 届时再退回 `reqwest::blocking`（本次不采用，因为 async 更易与限流/退避组合）。
//!
//! **限流纪律**：SSR/API 元数据请求走 [`fetch_text_throttled`]（并发上限 + 同域最小间隔）；
//! **媒体直链不走限流器**——由 [`fetch_bytes_unthrottled`] 承担（W3/W4 接入）。
//!
//! **取消与分级超时**：每次读请求经 [`enter_read`] 登记"取消句柄 + 截止时刻"，
//! 由 [`request_bytes`] 用 `tokio::select!` 同时等待「HTTP 结果」与「取消信号」，
//! 用 `tokio::time::timeout_at` 施加内层超时；被取消 → `CANCELED`，超时 → `TIMEOUT`。
//!
//! ⚠️ **单 worker 约束（如实记录）**：Dart 侧是常驻 worker isolate 单线程串行消费，`drama_request`
//! 逐个执行，`cancelRead` 只能在上一个请求返回**之后**才被处理——**单 worker 形态下"在途取消"不可达**。
//! 这里提供的是真实的中断机制（为多 worker/并发形态预留，且可取消同 session 的其他并发读），
//! 单 worker 下实际生效的是 `sequence` 仲裁丢弃迟到响应与内层分级超时。

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use reqwest::header::{ACCEPT_LANGUAGE, HeaderMap, HeaderValue};
use serde_json::Value;
use tokio::runtime::Runtime;
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

/// 统一浏览器 UA（媒体回源也用它，CDN 兼容性最好）。
pub const USER_AGENT_VALUE: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                                 (KHTML, like Gecko) Chrome/131.0 Safari/537.36";

/// 连接超时。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// 单请求总超时。
const TOTAL_TIMEOUT: Duration = Duration::from_secs(20);
/// 同域最小请求间隔。
const MIN_HOST_INTERVAL: Duration = Duration::from_millis(250);
/// 并发上限（同时进行中的请求数）。
const MAX_CONCURRENCY: usize = 3;
/// 最大重试次数（不含首次请求）。
const MAX_RETRIES: u32 = 3;
/// 退避上限。
const MAX_BACKOFF: Duration = Duration::from_secs(30);

/// 默认内层超时预算（目录/详情/搜索等默认档 60s，**内层先于 Dart 外层到期**）。
pub const DEFAULT_INNER_TIMEOUT: Duration = Duration::from_secs(60);

/// 分级内层超时预算：默认 60s / `preload` 15s / `moveDownloads` 600s。
///
/// 纯函数，便于离线单测。
pub fn inner_timeout_for(op: &str) -> Duration {
    match op {
        "preload" => Duration::from_secs(15),
        "moveDownloads" => Duration::from_secs(600),
        _ => DEFAULT_INNER_TIMEOUT,
    }
}

/// 代理支持。
///
/// 只读取**项目专用** `DRAMA_PROXY`：给了就显式接管（便于在构建钩子/桌面环境里
/// 明确指定，且便于离线单测）；没给则返回 `None`，交给 `reqwest` 的**默认系统代理**
/// 处理（`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 等）。空白串视为未设置。
///
/// 纯函数（注入式取值），便于离线单测。
pub fn explicit_proxy_from(get: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let raw = get("DRAMA_PROXY")?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.to_owned())
}

/// 全局多线程 Tokio 运行时（2 个 worker 线程）。
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("build tokio runtime")
});

/// 主运行时句柄（测试等需要驱动 async 流程时用；生产路径经各模块封装函数进入，
/// 不要在运行时工作线程上直接 `block_on`，否则死锁）。
pub fn runtime_handle() -> tokio::runtime::Handle {
    RUNTIME.handle().clone()
}

/// 全局并发闸门。
static SEM: Lazy<Semaphore> = Lazy::new(|| Semaphore::new(MAX_CONCURRENCY));

/// 每个 host 最近一次放行时刻（用于同域最小间隔控制）。
static HOST_LAST: Lazy<Mutex<HashMap<String, Instant>>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// 统一 HTTP 客户端（低耦合单例）。
static CLIENT: Lazy<reqwest::Client> = Lazy::new(|| {
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT_LANGUAGE, HeaderValue::from_static("zh-CN"));
    let mut builder = reqwest::Client::builder()
        .user_agent(USER_AGENT_VALUE)
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(TOTAL_TIMEOUT)
        .default_headers(headers);
    // 代理支持：`DRAMA_PROXY` 显式接管；否则 reqwest 默认系统代理照旧生效。
    if let Some(url) = explicit_proxy_from(&|key| std::env::var(key).ok())
        && let Ok(proxy) = reqwest::Proxy::all(&url)
    {
        builder = builder.proxy(proxy);
    }
    builder.build().expect("build reqwest client")
});

/// HTTP 错误类别：决定映射到信封错误码。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpErrorKind {
    /// 传输层/状态码错误（映射 `HTTP`）。
    Transport,
    /// 在途读被取消（映射 `CANCELED`，`retry=false`）。
    Canceled,
    /// 内层分级超时（映射 `TIMEOUT`，`retry=true`）。
    Timeout,
}

/// HTTP 错误：`status` 为响应码（若是连接层错误则为 `None`），`retryable` 给出是否建议重试，
/// `kind` 区分传输错误 / 取消 / 超时以做错误码映射。
#[derive(Debug, thiserror::Error)]
#[error("http error (kind={kind:?}, status={status:?}, retryable={retryable}): {msg}")]
pub struct HttpError {
    pub kind: HttpErrorKind,
    pub status: Option<u16>,
    pub retryable: bool,
    pub msg: String,
}

impl HttpError {
    fn new(status: Option<u16>, retryable: bool, msg: impl Into<String>) -> Self {
        Self {
            kind: HttpErrorKind::Transport,
            status,
            retryable,
            msg: msg.into(),
        }
    }

    /// 在途读被取消。
    pub fn canceled() -> Self {
        Self {
            kind: HttpErrorKind::Canceled,
            status: None,
            retryable: false,
            msg: "request canceled".to_owned(),
        }
    }

    /// 内层分级超时。
    pub fn timeout() -> Self {
        Self {
            kind: HttpErrorKind::Timeout,
            status: None,
            retryable: true,
            msg: "inner timeout".to_owned(),
        }
    }
}

/// 读请求上下文：取消句柄（`None` 表示不参与取消）+ 本次读的截止时刻。
struct ReadContext {
    cancel: Option<CancellationToken>,
    deadline: Instant,
}

thread_local! {
    /// 当前线程正在执行的读请求上下文（worker 单线程，同一时刻仅一个）。
    static READ_CTX: RefCell<Option<ReadContext>> = const { RefCell::new(None) };
}

/// [`enter_read`] 的守卫：作用域结束时恢复上一层上下文。
pub struct ReadGuard {
    prev: Option<ReadContext>,
}

impl Drop for ReadGuard {
    fn drop(&mut self) {
        let prev = self.prev.take();
        READ_CTX.with(|c| *c.borrow_mut() = prev);
    }
}

/// 进入读请求上下文：登记取消句柄并设定内层超时预算（以**本 op 进入时刻**起算的截止点，
/// 保证同一 op 内多次 HTTP 读取合计不超过该预算，从而"内层先于 Dart 外层到期"）。
pub fn enter_read(cancel: Option<CancellationToken>, budget: Duration) -> ReadGuard {
    let ctx = ReadContext {
        cancel,
        deadline: Instant::now() + budget,
    };
    let prev = READ_CTX.with(|c| c.borrow_mut().replace(ctx));
    ReadGuard { prev }
}

/// 取文本入口（HTML/JSON）：受并发与同域间隔约束，带指数退避重试。
pub fn fetch_text_throttled(url: &str) -> Result<String, HttpError> {
    let bytes = RUNTIME.block_on(request_bytes(url, true))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// 自定义出站请求（签名 App 接口用）：方法 + 完整 URL + 逐请求头 + 可选 body。
/// 复用同一 reqwest 客户端（连接池保留），逐请求头覆盖默认值。
pub struct OutboundRequest {
    pub post: bool,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
}

/// API 响应体上限（8 MiB；签名接口只返回小 JSON，超限即视为异常）。
pub const MAX_API_BODY_BYTES: usize = 8 * 1024 * 1024;

/// 取 JSON 入口（签名 App 接口）：与 `fetch_text_throttled` 同一套
/// 并发/间隔/重试/取消/超时 plumbing，外加响应体上限与 JSON 解析。
pub fn fetch_json_custom(req: &OutboundRequest) -> Result<Value, HttpError> {
    let bytes = RUNTIME.block_on(request_custom(req, true))?;
    if bytes.len() > MAX_API_BODY_BYTES {
        return Err(HttpError::new(None, false, "api response too large"));
    }
    serde_json::from_slice(&bytes)
        .map_err(|e| HttpError::new(None, false, format!("invalid json: {e}")))
}

/// 取字节入口（媒体直链）：**不限流**，供 W3/W4 取流使用。
///
/// 说明：媒体请求不占限流额度——并发闸门与同域间隔只保护 SSR/API 元数据请求，
/// 否则单个大文件会长期占满并发额度、拖慢元数据请求。
pub fn fetch_bytes_unthrottled(url: &str) -> Result<Vec<u8>, HttpError> {
    RUNTIME.block_on(request_bytes(url, false))
}

/// 一次请求（可选限流），**施加取消与内层超时**。
///
/// 用 `tokio::select!` 同时等待「HTTP 结果」与「取消信号」；用 `timeout_at` 施加截止点。
/// 未被 [`enter_read`] 登记上下文时（例如直连调用）退化为纯 HTTP 读取。
async fn request_bytes(url: &str, throttle: bool) -> Result<Vec<u8>, HttpError> {
    request_with_ctx(
        &OutboundRequest {
            post: false,
            url: url.to_owned(),
            headers: Vec::new(),
            body: None,
        },
        throttle,
    )
    .await
}

/// 一次自定义请求（可选限流），**施加取消与内层超时**（与 [`request_bytes`] 同语义）。
async fn request_custom(req: &OutboundRequest, throttle: bool) -> Result<Vec<u8>, HttpError> {
    request_with_ctx(req, throttle).await
}

/// 取消/超时包装的公共内核。
async fn request_with_ctx(req: &OutboundRequest, throttle: bool) -> Result<Vec<u8>, HttpError> {
    let ctx = READ_CTX.with(|c| c.borrow().as_ref().map(|c| (c.cancel.clone(), c.deadline)));
    let Some((cancel, deadline)) = ctx else {
        return request_inner(req, throttle).await;
    };
    let timed = tokio::time::timeout_at(
        tokio::time::Instant::from_std(deadline),
        request_inner(req, throttle),
    );
    match cancel {
        Some(token) => tokio::select! {
            biased;
            // 取消优先：被 `cancelRead` 触发 → CANCELED，并丢弃在途 HTTP future（真正中断）。
            _ = token.cancelled() => Err(HttpError::canceled()),
            result = timed => result.unwrap_or_else(|_| Err(HttpError::timeout())),
        },
        None => timed.await.unwrap_or_else(|_| Err(HttpError::timeout())),
    }
}

/// 一次请求（可选限流），内部含退避重试。
async fn request_inner(req: &OutboundRequest, throttle: bool) -> Result<Vec<u8>, HttpError> {
    if !throttle {
        return send_with_retry(req).await;
    }
    let permit = SEM
        .acquire()
        .await
        .map_err(|_| HttpError::new(None, false, "semaphore closed"))?;
    enforce_min_interval(&host_of(&req.url)).await;
    let out = send_with_retry(req).await;
    drop(permit);
    out
}

/// 发送并处理退避重试：403/429/5xx 可重试，尊重 `Retry-After`，最多 [`MAX_RETRIES`] 次。
async fn send_with_retry(req: &OutboundRequest) -> Result<Vec<u8>, HttpError> {
    let mut attempt = 0u32;
    loop {
        let mut builder = CLIENT.request(
            if req.post {
                reqwest::Method::POST
            } else {
                reqwest::Method::GET
            },
            &req.url,
        );
        for (name, value) in &req.headers {
            let name = reqwest::header::HeaderName::from_bytes(name.as_bytes())
                .map_err(|_| HttpError::new(None, false, "invalid header name"))?;
            let value = reqwest::header::HeaderValue::from_str(value)
                .map_err(|_| HttpError::new(None, false, "invalid header value"))?;
            builder = builder.header(name, value);
        }
        if let Some(body) = req.body.as_ref() {
            builder = builder.body(body.clone());
        }
        let resp = builder
            .send()
            .await
            .map_err(|e| HttpError::new(None, true, e.to_string()))?;
        let status = resp.status();
        if status.is_success() {
            let bytes = resp
                .bytes()
                .await
                .map_err(|e| HttpError::new(Some(status.as_u16()), false, e.to_string()))?;
            return Ok(bytes.to_vec());
        }
        let code = status.as_u16();
        let retryable = is_retryable(code);
        let delay = retry_after_of(resp.headers()).unwrap_or_else(|| backoff(attempt));
        if !retryable || attempt >= MAX_RETRIES {
            return Err(HttpError::new(
                Some(code),
                retryable,
                format!("status {code}"),
            ));
        }
        tokio::time::sleep(delay).await;
        attempt += 1;
    }
}

/// 403 / 429 / 5xx 视为可退避重试。
fn is_retryable(code: u16) -> bool {
    code == 403 || code == 429 || (500..=599).contains(&code)
}

/// 指数退避：1s 起、每轮翻倍、封顶 [`MAX_BACKOFF`]。
fn backoff(attempt: u32) -> Duration {
    let secs = 1u64.checked_shl(attempt).unwrap_or(u64::MAX);
    Duration::from_secs(secs).min(MAX_BACKOFF)
}

/// 从响应头解析 `Retry-After`（仅支持秒数形式，HTTP 日期形式忽略）。
fn retry_after_of(headers: &HeaderMap) -> Option<Duration> {
    let raw = headers.get(reqwest::header::RETRY_AFTER)?.to_str().ok()?;
    parse_retry_after_value(raw)
}

/// 解析 `Retry-After` 秒数并封顶。
fn parse_retry_after_value(raw: &str) -> Option<Duration> {
    let secs: u64 = raw.trim().parse().ok()?;
    Some(Duration::from_secs(secs).min(MAX_BACKOFF))
}

/// 取 URL 的 host（用于同域间隔控制）。
fn host_of(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .unwrap_or_else(|| url.to_owned())
}

/// 同域最小间隔：距上次放行不足 [`MIN_HOST_INTERVAL`] 时等待。
async fn enforce_min_interval(host: &str) {
    loop {
        let wait = {
            let mut map = HOST_LAST.lock().expect("host throttle poisoned");
            let now = Instant::now();
            match map.get(host).copied() {
                Some(last) => {
                    let elapsed = now.duration_since(last);
                    if elapsed < MIN_HOST_INTERVAL {
                        Some(MIN_HOST_INTERVAL - elapsed)
                    } else {
                        map.insert(host.to_owned(), now);
                        None
                    }
                }
                None => {
                    map.insert(host.to_owned(), now);
                    None
                }
            }
        };
        match wait {
            Some(d) => tokio::time::sleep(d).await,
            None => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_is_exponential_and_capped() {
        assert_eq!(backoff(0), Duration::from_secs(1));
        assert_eq!(backoff(1), Duration::from_secs(2));
        assert_eq!(backoff(2), Duration::from_secs(4));
        assert_eq!(backoff(10), MAX_BACKOFF);
    }

    #[test]
    fn explicit_proxy_prefers_drama_proxy_and_ignores_blank() {
        let none = |_: &str| None;
        assert_eq!(explicit_proxy_from(&none), None);

        // `DRAMA_PROXY` 给了就显式接管，并去除首尾空白。
        let drama = |k: &str| (k == "DRAMA_PROXY").then(|| "  http://127.0.0.1:8888  ".to_owned());
        assert_eq!(
            explicit_proxy_from(&drama).as_deref(),
            Some("http://127.0.0.1:8888")
        );

        // 只设 HTTPS_PROXY 时不显式接管（交给 reqwest 的默认系统代理）。
        let system = |k: &str| (k == "HTTPS_PROXY").then(|| "http://127.0.0.1:1080".to_owned());
        assert_eq!(explicit_proxy_from(&system), None);

        // 空白串视为未设置。
        let blank = |_: &str| Some("   ".to_owned());
        assert_eq!(explicit_proxy_from(&blank), None);
    }

    #[test]
    fn retry_after_parses_seconds_only() {
        assert_eq!(parse_retry_after_value("5"), Some(Duration::from_secs(5)));
        assert_eq!(
            parse_retry_after_value(" 12 "),
            Some(Duration::from_secs(12))
        );
        assert_eq!(parse_retry_after_value("9999"), Some(MAX_BACKOFF));
        assert_eq!(
            parse_retry_after_value("Wed, 21 Oct 2015 07:28:00 GMT"),
            None
        );
    }

    #[test]
    fn host_of_extracts_host_or_falls_back() {
        assert_eq!(
            host_of("https://www.hongguoduanju.com/detail?series_id=1"),
            "www.hongguoduanju.com"
        );
        assert_eq!(host_of("not a url"), "not a url");
    }

    /// 当前线程是否登记了读上下文。
    fn ctx_is_present() -> bool {
        READ_CTX.with(|c| c.borrow().is_some())
    }

    #[test]
    fn enter_read_guard_restores_previous_context() {
        assert!(!ctx_is_present());
        {
            let _guard = enter_read(None, Duration::from_secs(1));
            assert!(ctx_is_present());
        }
        assert!(!ctx_is_present());
    }

    #[test]
    fn already_canceled_token_yields_canceled_without_network() {
        let token = CancellationToken::new();
        token.cancel();
        let _guard = enter_read(Some(token), Duration::from_secs(60));
        // biased select 优先命中已取消信号，无需触达网络。
        let err = RUNTIME
            .block_on(request_bytes("https://example.invalid/", false))
            .unwrap_err();
        assert_eq!(err.kind, HttpErrorKind::Canceled);
    }

    #[test]
    fn exhausted_budget_yields_timeout() {
        // 预算为 0 → 截止点已到，读取立即映射为 TIMEOUT（不等待真实网络完成）。
        let _guard = enter_read(None, Duration::ZERO);
        let err = RUNTIME
            .block_on(request_bytes("https://example.invalid/", false))
            .unwrap_err();
        assert_eq!(err.kind, HttpErrorKind::Timeout);
    }

    #[test]
    fn inner_timeout_tiers_follow_design() {
        // 分级内层超时：默认 60s / preload 15s / moveDownloads 600s。
        assert_eq!(inner_timeout_for("preload"), Duration::from_secs(15));
        assert_eq!(inner_timeout_for("moveDownloads"), Duration::from_secs(600));
        assert_eq!(inner_timeout_for("catalog"), DEFAULT_INNER_TIMEOUT);
        assert_eq!(inner_timeout_for("detail"), Duration::from_secs(60));
    }
}
