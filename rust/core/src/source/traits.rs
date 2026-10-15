//! 源能力契约。
//!
//! **契约纪律**：`Caps` 未声明的能力必须返回 [`SourceError::Unsupported`]
//! （错误码 `UNSUPPORTED`），**绝不返回空列表冒充"查过了"**（星果/河果教训）。

use serde_json::{Value, json};

use crate::http::{HttpError, HttpErrorKind};

/// 能力位。P0 红果实现为 `catalog/search/suggest/recommend/ranking/detail` 全开、
/// `playback` 关闭（轨① 明文直链已不可得）。
#[derive(Debug, Clone, Copy, Default)]
pub struct Caps {
    pub catalog: bool,
    pub search: bool,
    pub suggest: bool,
    pub recommend: bool,
    pub ranking: bool,
    pub detail: bool,
    pub playback: bool,
}

impl Caps {
    /// 序列化为 JSON（供 `version` op 返回）。
    pub fn to_json(self) -> Value {
        json!({
            "catalog": self.catalog,
            "search": self.search,
            "suggest": self.suggest,
            "recommend": self.recommend,
            "ranking": self.ranking,
            "detail": self.detail,
            "playback": self.playback,
        })
    }
}

/// 源错误，作为信封 `error{code,msg,retry}` 的映射源。
#[derive(Debug, thiserror::Error)]
pub enum SourceError {
    /// 未声明能力：绝不返回空列表冒充"查过了"。
    #[error("capability not supported")]
    Unsupported,
    /// 在途读被取消（`CANCELED`，`retry=false`）。
    #[error("request canceled")]
    Canceled,
    /// 内层分级超时（`TIMEOUT`，`retry=true`）。
    #[error("request timed out")]
    Timeout,
    /// 底层 HTTP 失败（`retryable` 由 [`HttpError`] 决定）。
    #[error(transparent)]
    Http(HttpError),
    /// SSR / JSON 解析失败。
    #[error("parse error: {0}")]
    Parse(String),
    /// 资源不存在（含未注册的源 id）。
    #[error("resource not found")]
    NotFound,
    /// 源被限流/封禁，`retry_at_ms` 为建议重试时刻（Unix 毫秒）。
    #[error("source blocked until {retry_at_ms}")]
    Blocked { retry_at_ms: i64 },
}

impl From<HttpError> for SourceError {
    /// 按 [`HttpErrorKind`] 分派：取消/超时映射为独立错误码，其余归入 [`SourceError::Http`]。
    fn from(e: HttpError) -> Self {
        match e.kind {
            HttpErrorKind::Canceled => SourceError::Canceled,
            HttpErrorKind::Timeout => SourceError::Timeout,
            HttpErrorKind::Transport => SourceError::Http(e),
        }
    }
}

impl SourceError {
    /// 信封错误码。
    pub fn code(&self) -> &'static str {
        match self {
            SourceError::Unsupported => "UNSUPPORTED",
            SourceError::Canceled => "CANCELED",
            SourceError::Timeout => "TIMEOUT",
            SourceError::Http(_) => "HTTP",
            SourceError::Parse(_) => "PARSE",
            SourceError::NotFound => "NOT_FOUND",
            SourceError::Blocked { .. } => "source_blocked",
        }
    }

    /// 信封 `retry` 标志。
    pub fn retry(&self) -> bool {
        match self {
            SourceError::Unsupported
            | SourceError::Canceled
            | SourceError::Parse(_)
            | SourceError::NotFound => false,
            SourceError::Timeout => true,
            SourceError::Http(e) => e.retryable,
            SourceError::Blocked { .. } => true,
        }
    }
}

/// 唯一源抽象。P2 扩展源实现同一 trait，引擎调度与 Dart 侧零改动。
pub trait SourceProvider: Send + Sync {
    /// 源 id，如 `"hongguo"`。
    fn id(&self) -> &'static str;
    /// 能力位。
    fn caps(&self) -> Caps;
    /// 分类目录：`category` 为分类路由（`None` 用默认路由）。
    fn catalog(&self, category: Option<&str>, page: u32) -> Result<Value, SourceError>;
    /// 首页推荐。
    fn recommend(&self) -> Result<Value, SourceError>;
    /// 榜单：`board` 为榜板语义名（`hot`/`rising`/`finished`）。
    fn ranking(&self, board: Option<&str>) -> Result<Value, SourceError>;
    /// 搜索。
    fn search(&self, keyword: &str) -> Result<Value, SourceError>;
    /// 搜索建议。
    fn suggest(&self, keyword: &str) -> Result<Value, SourceError>;
    /// 详情 + 选集。
    fn detail(&self, series_id: &str) -> Result<Value, SourceError>;
    /// 取流：默认不支持；红果等源覆盖实现。`episode` 为 1-based 集号，
    /// `vid` 直接给分集 id 时优先用它（免一次详情请求），
    /// `quality` 为期望清晰度上限（0 表示要最高）。
    fn play(
        &self,
        _series_id: &str,
        _episode: u32,
        _vid: Option<String>,
        _quality: i64,
    ) -> Result<Value, SourceError> {
        Err(SourceError::Unsupported)
    }
    /// 预取下集：解析 + 注册会话 + 解密首窗口，播放器打开即播。
    /// 失败是可选的（调用方忽略错误即可），默认不支持。
    fn preload(
        &self,
        _series_id: &str,
        _episode: u32,
        _vid: Option<String>,
        _quality: i64,
    ) -> Result<Value, SourceError> {
        Err(SourceError::Unsupported)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canceled_http_error_maps_to_canceled_code() {
        let e: SourceError = HttpError::canceled().into();
        assert_eq!(e.code(), "CANCELED");
        assert!(!e.retry());
    }

    #[test]
    fn timeout_http_error_maps_to_timeout_code_with_retry() {
        let e: SourceError = HttpError::timeout().into();
        assert_eq!(e.code(), "TIMEOUT");
        assert!(e.retry());
    }
}
