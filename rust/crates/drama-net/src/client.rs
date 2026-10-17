//! HTTP 客户端：请求构造、限流接入、超时、重试、取消。
//!
//! ## 两套超时
//!
//! - **元数据**：单请求总超时 20 s（`TOTAL_TIMEOUT`）。慢就是慢，让用户重试。
//! - **媒体**：**不设总超时**，只有连接超时与读空闲看门狗。
//!   长视频边下边播不能被总超时切断——原实现踩过这个坑（下载中途被
//!   `http.Client.Timeout` 掐断，表现为「大文件永远下不完」）。
//!
//! ## 取消
//!
//! 用 [`tokio_util::sync::CancellationToken`]：`tokio::select!` 同时等
//! HTTP 结果与取消信号。取消是**协作式**的——它让调用方立刻返回，
//! 但不保证立刻中断对端 socket。

use std::collections::HashMap;
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::backoff::{Lane, table as backoff_table};
use crate::error::HttpError;
use crate::limiter::{Limiter, LimiterSettings, Priority};
use crate::proxy::{ProxySettings, build_proxy};

/// 统一浏览器 UA（媒体回源也用它，CDN 兼容性最好）。
pub const USER_AGENT_VALUE: &str = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) \
AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1";

/// 桌面 Chrome UA（部分站点按 UA 分流）。
pub const DESKTOP_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 连接超时。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// 元数据单请求总超时。
const TOTAL_TIMEOUT: Duration = Duration::from_secs(20);
/// 媒体读空闲看门狗：多久没有新字节就判失败。
pub const MEDIA_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// 媒体最大重定向次数。
const MAX_MEDIA_REDIRECTS: usize = 5;

/// 一次请求的规格。
#[derive(Debug, Clone)]
pub struct RequestSpec {
    pub method: Method,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    /// 请求类别：决定超时策略与限流通道。
    pub class: RequestClass,
    /// 限流用的源 id（`None` = 不限流，媒体路径）。
    pub source: Option<String>,
    pub priority: Priority,
    pub cancellation: Option<CancellationToken>,
    /// 单请求超时覆盖（`None` 用类别默认值）。
    pub timeout: Option<Duration>,
}

/// HTTP 方法（只支持这两种，够用且不给出错的余地）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

impl Method {
    fn as_reqwest(self) -> reqwest::Method {
        match self {
            Method::Get => reqwest::Method::GET,
            Method::Post => reqwest::Method::POST,
        }
    }
}

/// 请求类别。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestClass {
    /// 元数据：限流 + 总超时。
    Metadata,
    /// 媒体：不限流 + 无总超时（只有空闲看门狗）。
    Media,
    /// 封面：不限流 + 25 s 总超时。
    Cover,
}

impl RequestClass {
    fn timeout(self) -> Option<Duration> {
        match self {
            RequestClass::Metadata => Some(TOTAL_TIMEOUT),
            RequestClass::Media => None,
            RequestClass::Cover => Some(Duration::from_secs(25)),
        }
    }

    fn throttled(self) -> bool {
        matches!(self, RequestClass::Metadata)
    }
}

impl RequestSpec {
    /// GET 元数据请求。
    pub fn get(url: impl Into<String>, source: impl Into<String>) -> Self {
        RequestSpec {
            method: Method::Get,
            url: url.into(),
            headers: Vec::new(),
            body: None,
            class: RequestClass::Metadata,
            source: Some(source.into()),
            priority: Priority::Foreground,
            cancellation: None,
            timeout: None,
        }
    }

    /// POST 元数据请求。
    pub fn post(url: impl Into<String>, source: impl Into<String>) -> Self {
        RequestSpec {
            method: Method::Post,
            url: url.into(),
            headers: Vec::new(),
            body: None,
            class: RequestClass::Metadata,
            source: Some(source.into()),
            priority: Priority::Foreground,
            cancellation: None,
            timeout: None,
        }
    }

    /// 媒体请求（不限流、无总超时）。
    pub fn media(url: impl Into<String>) -> Self {
        RequestSpec {
            method: Method::Get,
            url: url.into(),
            headers: Vec::new(),
            body: None,
            class: RequestClass::Media,
            source: None,
            priority: Priority::Foreground,
            cancellation: None,
            timeout: None,
        }
    }

    /// 封面请求。
    pub fn cover(url: impl Into<String>) -> Self {
        RequestSpec {
            method: Method::Get,
            url: url.into(),
            headers: Vec::new(),
            body: None,
            class: RequestClass::Cover,
            source: None,
            priority: Priority::Background,
            cancellation: None,
            timeout: None,
        }
    }

    pub fn header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    pub fn body(mut self, body: Vec<u8>) -> Self {
        self.body = Some(body);
        self
    }

    pub fn json_body(mut self, value: &Value) -> Result<Self, HttpError> {
        let bytes = serde_json::to_vec(value)
            .map_err(|e| HttpError::transport(format!("encode body: {e}"), false))?;
        self.body = Some(bytes);
        self.headers.push((
            "Content-Type".to_owned(),
            "application/json; charset=utf-8".to_owned(),
        ));
        Ok(self)
    }

    pub fn cancellation(mut self, token: CancellationToken) -> Self {
        self.cancellation = Some(token);
        self
    }

    pub fn priority(mut self, priority: Priority) -> Self {
        self.priority = priority;
        self
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = Some(timeout);
        self
    }
}

/// 响应体。
#[derive(Debug)]
pub struct ResponseBody {
    pub status: u16,
    pub bytes: Vec<u8>,
    /// 跟随重定向后的最终地址（HLS 相对路径要基于它解析）。
    pub final_url: String,
    pub content_type: String,
}

impl ResponseBody {
    /// 按 UTF-8 解码（替换非法字节，不报错——站源偶尔会混入坏字节）。
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }

    /// 解析为 JSON。
    pub fn json(&self) -> Result<Value, HttpError> {
        serde_json::from_slice(&self.bytes)
            .map_err(|e| HttpError::transport(format!("invalid json: {e}"), false))
    }
}

/// 媒体流响应（不缓冲，调用方边读边处理）。
pub struct MediaResponse {
    pub status: u16,
    pub headers: HeaderMap,
    pub final_url: String,
    pub inner: reqwest::Response,
}

impl std::fmt::Debug for MediaResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MediaResponse")
            .field("status", &self.status)
            .field("final_url", &self.final_url)
            .finish_non_exhaustive()
    }
}

/// 全局客户端集合。
#[derive(Debug)]
pub struct HttpClient {
    metadata: reqwest::Client,
    media: reqwest::Client,
    limiter: Limiter,
}

/// 全局客户端槽。
///
/// 用 `Arc` + `RwLock` 而不是 `OnceLock`：代理设置变更时必须能**整体替换**
/// 客户端（reqwest 的 proxy 不可变），而读侧不希望每次请求都深拷贝。
static CLIENT: Lazy<std::sync::RwLock<std::sync::Arc<HttpClient>>> = Lazy::new(|| {
    let built = HttpClient::build(&ProxySettings::default(), LimiterSettings::default())
        .expect("build default http client");
    std::sync::RwLock::new(std::sync::Arc::new(built))
});

/// 取全局客户端快照。
///
/// 返回 `Arc` 而非 `&'static`：调用方可能在请求进行中被 `reconfigure` 换掉
/// 客户端，持有快照能保证一次请求自始至终用同一个客户端。
pub fn client() -> std::sync::Arc<HttpClient> {
    CLIENT
        .read()
        .expect("client poisoned")
        .clone()
}

impl HttpClient {
    /// 构建客户端。
    pub fn build(proxy: &ProxySettings, limiter: LimiterSettings) -> Result<Self, HttpError> {
        let proxy_config = build_proxy(proxy)
            .map_err(|e| HttpError::transport(format!("proxy: {e}"), false))?;

        let mut builder = reqwest::Client::builder()
            .user_agent(USER_AGENT_VALUE)
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(TOTAL_TIMEOUT)
            .redirect(reqwest::redirect::Policy::limited(MAX_MEDIA_REDIRECTS));
        if let Some(p) = proxy_config.clone() {
            builder = builder.proxy(p);
        }
        let metadata = builder
            .build()
            .map_err(|e| HttpError::transport(format!("build client: {e}"), false))?;

        // 媒体客户端：无总超时。
        let mut media_builder = reqwest::Client::builder()
            .user_agent(USER_AGENT_VALUE)
            .connect_timeout(CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::limited(MAX_MEDIA_REDIRECTS));
        if let Some(p) = proxy_config {
            media_builder = media_builder.proxy(p);
        }
        let media = media_builder
            .build()
            .map_err(|e| HttpError::transport(format!("build media client: {e}"), false))?;

        Ok(HttpClient {
            metadata,
            media,
            limiter: Limiter::new(limiter),
        })
    }

    /// 更新代理与限流设置（设置页保存后调用）。
    ///
    /// 构建成功才替换：构建失败（代理地址非法）时保留旧客户端继续工作，
    /// 不能因为一次坏设置让整个网络栈停摆。
    pub fn reconfigure(proxy: &ProxySettings, limiter: LimiterSettings) -> Result<(), HttpError> {
        let rebuilt = HttpClient::build(proxy, limiter)?;
        *CLIENT.write().expect("client poisoned") = std::sync::Arc::new(rebuilt);
        // 换代理后旧冷却记录不再适用。
        backoff_table().clear_all();
        Ok(())
    }

    pub fn limiter(&self) -> &Limiter {
        &self.limiter
    }

    /// 执行请求并读完全部响应体（元数据/封面）。
    pub fn execute(&self, spec: RequestSpec) -> Result<ResponseBody, HttpError> {
        crate::block_on(self.execute_async(spec))
    }

    async fn execute_async(&self, spec: RequestSpec) -> Result<ResponseBody, HttpError> {
        let host = host_of(&spec.url)?;
        let lane = if spec.priority == Priority::Background {
            Lane::Background
        } else {
            Lane::Foreground
        };

        // 冷却检查：被限流的 host 直接失败，不再打过去。
        if let Some(backoff) = backoff_table().get(&host, lane) {
            return Err(HttpError {
                kind: crate::error::HttpErrorKind::Transport,
                status: Some(backoff.status),
                retryable: true,
                message: format!(
                    "{} HTTP {}，请在 {} 秒后重试",
                    backoff.host,
                    backoff.status,
                    backoff.remaining_secs()
                ),
            });
        }

        // 限流（仅元数据路径）。
        let _permit = if spec.class.throttled() {
            let source = spec.source.clone().unwrap_or_else(|| host.clone());
            let deadline = spec.timeout.or_else(|| spec.class.timeout()).map(|t| Instant::now() + t);
            Some(
                self.limiter
                    .acquire(&source, spec.priority, deadline)
                    .ok_or_else(HttpError::timeout)?,
            )
        } else {
            None
        };

        let timeout = spec.timeout.or_else(|| spec.class.timeout());
        let fut = self.send_once(&spec, timeout);

        let result = match spec.cancellation.clone() {
            Some(token) => tokio::select! {
                biased;
                _ = token.cancelled() => Err(HttpError::canceled()),
                out = fut => out,
            },
            None => fut.await,
        };

        match result {
            Ok(body) => {
                // 观察响应：403/429 登记冷却。
                if matches!(body.status, 403 | 429) {
                    backoff_table().put(&host, lane, body.status, "", None);
                }
                Ok(body)
            }
            Err(e) => Err(e),
        }
    }

    async fn send_once(
        &self,
        spec: &RequestSpec,
        timeout: Option<Duration>,
    ) -> Result<ResponseBody, HttpError> {
        let request = self.build_request(spec)?;
        let send = self.metadata.execute(request);
        let response = match timeout {
            Some(limit) => tokio::time::timeout(limit, send)
                .await
                .map_err(|_| HttpError::timeout())?,
            None => send.await,
        };
        let response = response.map_err(map_reqwest_error)?;
        let status = response.status().as_u16();
        let final_url = response.url().to_string();
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        let bytes = response.bytes().await.map_err(map_reqwest_error)?.to_vec();
        if !(200..300).contains(&status) {
            return Err(HttpError::status(
                status,
                format!("HTTP {status} from {}", host_of(&final_url).unwrap_or_default()),
            ));
        }
        Ok(ResponseBody {
            status,
            bytes,
            final_url,
            content_type,
        })
    }

    fn build_request(&self, spec: &RequestSpec) -> Result<reqwest::Request, HttpError> {
        let mut request = self
            .metadata
            .request(spec.method.as_reqwest(), &spec.url)
            .header("Accept-Language", "zh-CN,zh;q=0.9");
        let mut headers = HeaderMap::new();
        for (name, value) in &spec.headers {
            let header_name = HeaderName::from_bytes(name.as_bytes())
                .map_err(|_| HttpError::transport(format!("invalid header name: {name}"), false))?;
            let header_value = HeaderValue::from_str(value)
                .map_err(|_| HttpError::transport(format!("invalid header value for {name}"), false))?;
            headers.insert(header_name, header_value);
        }
        request = request.headers(headers);
        if let Some(body) = &spec.body {
            request = request.body(body.clone());
        }
        request
            .build()
            .map_err(|e| HttpError::transport(format!("build request: {e}"), false))
    }

    /// 发起媒体请求，返回未读的流。
    pub fn open_media(&self, spec: RequestSpec) -> Result<MediaResponse, HttpError> {
        crate::block_on(self.open_media_async(spec))
    }

    async fn open_media_async(&self, spec: RequestSpec) -> Result<MediaResponse, HttpError> {
        let request = {
            let mut request = self
                .media
                .request(spec.method.as_reqwest(), &spec.url)
                .header("Accept", "*/*")
                .header("Accept-Language", "zh-CN,zh;q=0.9");
            let mut headers = HeaderMap::new();
            for (name, value) in &spec.headers {
                if let (Ok(n), Ok(v)) = (
                    HeaderName::from_bytes(name.as_bytes()),
                    HeaderValue::from_str(value),
                ) {
                    headers.insert(n, v);
                }
            }
            request = request.headers(headers);
            request
                .build()
                .map_err(|e| HttpError::transport(format!("build media request: {e}"), false))?
        };
        let send = self.media.execute(request);
        let response = match spec.cancellation.clone() {
            Some(token) => tokio::select! {
                biased;
                _ = token.cancelled() => return Err(HttpError::canceled()),
                out = send => out,
            },
            None => send.await,
        };
        let response = response.map_err(map_reqwest_error)?;
        let status = response.status().as_u16();
        let final_url = response.url().to_string();
        let headers = response.headers().clone();
        Ok(MediaResponse {
            status,
            headers,
            final_url,
            inner: response,
        })
    }
}

/// 提取 host（用于冷却表 key）。
fn host_of(url: &str) -> Result<String, HttpError> {
    let parsed = url::Url::parse(url)
        .map_err(|e| HttpError::transport(format!("invalid url: {e}"), false))?;
    parsed
        .host_str()
        .map(str::to_ascii_lowercase)
        .ok_or_else(|| HttpError::transport("url has no host", false))
}

fn map_reqwest_error(e: reqwest::Error) -> HttpError {
    if e.is_timeout() {
        return HttpError::timeout();
    }
    if e.is_connect() || e.is_request() {
        return HttpError::transport(format!("connection failed: {e}"), true);
    }
    if let Some(status) = e.status() {
        return HttpError::status(status.as_u16(), e.to_string());
    }
    HttpError::transport(e.to_string(), e.is_timeout() || e.is_connect())
}

// ── 便捷入口 ────────────────────────────────────────────────

/// 取文本（走限流）。
pub fn fetch_text_throttled(url: &str) -> Result<String, HttpError> {
    let spec = RequestSpec::get(url, host_of(url)?);
    Ok(client().execute(spec)?.text())
}

/// 取文本（自定义请求）。
pub fn fetch_text(spec: RequestSpec) -> Result<String, HttpError> {
    Ok(client().execute(spec)?.text())
}

/// 取 JSON（自定义请求）。
pub fn fetch_json_custom(spec: RequestSpec) -> Result<Value, HttpError> {
    client().execute(spec)?.json()
}

/// 取 JSON（默认 GET）。
pub fn fetch_json(url: &str) -> Result<Value, HttpError> {
    let spec = RequestSpec::get(url, host_of(url)?);
    client().execute(spec)?.json()
}

/// 探测媒体地址是否可播（发 `Range: bytes=0-1`）。
///
/// 为什么需要它：把 404 地址交给播放器，表现是**黑屏无错误**——
/// 用户不知道是「没权限」还是「网络问题」。先探一次，能给出明确文案。
///
/// 返回 `Ok(())` 表示 200/206；`404` 映射为不可重试错误（调用方据此提示
/// 「该集需授权」）；其余状态按 HTTP 语义分类。
pub fn probe_playable(url: &str, referer: &str) -> Result<(), HttpError> {
    let spec = RequestSpec::media(url)
        .header("Referer", referer)
        .header("Range", "bytes=0-1")
        .header("User-Agent", USER_AGENT_VALUE)
        .timeout(Duration::from_secs(15));
    match client().open_media(spec) {
        Ok(response) => {
            let status = response.status;
            if matches!(status, 200 | 206) {
                Ok(())
            } else if status == 404 {
                Err(HttpError {
                    kind: crate::error::HttpErrorKind::Transport,
                    status: Some(404),
                    retryable: false,
                    message: "media not found (404)".to_owned(),
                })
            } else {
                Err(HttpError::status(status, "media not playable"))
            }
        }
        Err(e) => Err(e),
    }
}

/// 请求头构造辅助：把 `Vec<(String,String)>` 转成 reqwest 的 `HeaderMap`。
pub fn to_header_map(headers: &[(String, String)]) -> HeaderMap {
    let mut map = HeaderMap::with_capacity(headers.len());
    for (name, value) in headers {
        if let (Ok(n), Ok(v)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            map.insert(n, v);
        }
    }
    map
}

/// 每个 host 的最近一次请求时刻（诊断/测试用）。
pub fn host_last_seen() -> HashMap<String, Instant> {
    HashMap::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_extraction() {
        assert_eq!(host_of("https://Example.COM/a/b").unwrap(), "example.com");
        assert!(host_of("not-a-url").is_err());
        assert!(host_of("file:///tmp/x").is_err());
    }

    #[test]
    fn request_class_timeouts() {
        assert_eq!(RequestClass::Metadata.timeout(), Some(TOTAL_TIMEOUT));
        // 媒体没有总超时——长视频不能被掐断。
        assert_eq!(RequestClass::Media.timeout(), None);
        assert_eq!(RequestClass::Cover.timeout(), Some(Duration::from_secs(25)));
    }

    #[test]
    fn only_metadata_is_throttled() {
        assert!(RequestClass::Metadata.throttled());
        assert!(!RequestClass::Media.throttled());
        assert!(!RequestClass::Cover.throttled());
    }

    #[test]
    fn spec_builders_set_expected_fields() {
        let spec = RequestSpec::get("https://x.test/a", "hongguo")
            .header("Referer", "https://x.test/");
        assert_eq!(spec.class, RequestClass::Metadata);
        assert_eq!(spec.source.as_deref(), Some("hongguo"));
        assert_eq!(spec.headers.len(), 1);

        let media = RequestSpec::media("https://cdn.test/v.mp4");
        assert_eq!(media.class, RequestClass::Media);
        assert!(media.source.is_none());

        let cover = RequestSpec::cover("https://cdn.test/c.jpg");
        assert_eq!(cover.priority, Priority::Background);
    }

    #[test]
    fn json_body_sets_content_type() {
        let spec = RequestSpec::post("https://x.test/a", "hongguo")
            .json_body(&serde_json::json!({"a": 1}))
            .expect("json body");
        assert!(spec.body.is_some());
        assert!(
            spec.headers
                .iter()
                .any(|(k, _)| k == "Content-Type")
        );
    }

    #[test]
    fn response_body_text_is_lossy() {
        let body = ResponseBody {
            status: 200,
            bytes: vec![0x61, 0xff, 0x62],
            final_url: String::new(),
            content_type: String::new(),
        };
        // 非法字节被替换，不 panic。
        assert!(body.text().contains('a'));
        assert!(body.text().contains('b'));
    }

    #[test]
    fn response_body_json_error_is_not_retryable() {
        let body = ResponseBody {
            status: 200,
            bytes: b"{not json".to_vec(),
            final_url: String::new(),
            content_type: String::new(),
        };
        let err = body.json().unwrap_err();
        assert!(!err.retryable());
    }
}
