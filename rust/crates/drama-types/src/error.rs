//! 错误分类：wire 错误码是**前端唯一可见的错误面**，因此这里的枚举必须稳定。

use std::fmt;

use serde::Serialize;

/// wire 错误码。
///
/// 这些字符串直接出现在 `{"ok":false,"error":{"code":"..."}}` 里，前端按它分支。
/// **改名即破坏契约**；新增只能追加。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    /// 入参缺失/非法（含 session 非法）。
    BadRequest,
    /// 信封版本不符。
    BadVersion,
    /// 入参超过 1 MiB。
    TooLarge,
    /// 未知 op，或源未声明该能力。
    Unsupported,
    /// 资源不存在（含未注册源、下载任务不存在）。
    NotFound,
    /// 上游解析失败（源站结构变化）。
    Parse,
    /// 底层 HTTP 失败；是否可重试由 [`DramaError::retry`] 决定。
    Http,
    /// 内层分级超时。
    Timeout,
    /// 同逻辑流内被更新的请求取代。**这是正常现象**，UI 应静默忽略。
    Canceled,
    /// 源被限流/封禁，带建议重试时刻。
    #[serde(rename = "source_blocked")]
    SourceBlocked,
    /// Rust panic 被兜住。
    Internal,
    /// 本机文件缺失或不完整。
    #[serde(rename = "local_media")]
    LocalMedia,
    /// 磁盘/权限失败（区别于网络失败）。
    Storage,
    /// 扩展规则包非法（schema、签名、版本）。
    RuleInvalid,
}

impl ErrorCode {
    /// wire 字符串。
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::BadRequest => "BAD_REQUEST",
            ErrorCode::BadVersion => "BAD_VERSION",
            ErrorCode::TooLarge => "TOO_LARGE",
            ErrorCode::Unsupported => "UNSUPPORTED",
            ErrorCode::NotFound => "NOT_FOUND",
            ErrorCode::Parse => "PARSE",
            ErrorCode::Http => "HTTP",
            ErrorCode::Timeout => "TIMEOUT",
            ErrorCode::Canceled => "CANCELED",
            ErrorCode::SourceBlocked => "source_blocked",
            ErrorCode::Internal => "INTERNAL",
            ErrorCode::LocalMedia => "local_media",
            ErrorCode::Storage => "STORAGE",
            ErrorCode::RuleInvalid => "RULE_INVALID",
        }
    }
}

/// 核心错误。
///
/// **不要**用 `Box<dyn Error>` 擦除类型：`retry` 与 `code` 需要确定性，
/// 而动态错误无法表达「这次失败能不能重试」。
#[derive(Debug, thiserror::Error)]
pub enum DramaError {
    #[error("{0}")]
    BadRequest(String),
    #[error("unsupported envelope version: {0}")]
    BadVersion(u32),
    #[error("input exceeds {0} bytes")]
    TooLarge(usize),
    /// 能力未声明。**绝不返回空列表冒充「查过了」**。
    #[error("capability not supported: {0}")]
    Unsupported(&'static str),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("parse error: {0}")]
    Parse(String),
    #[error("http error: {message}")]
    Http {
        message: String,
        status: Option<u16>,
        retryable: bool,
    },
    #[error("request timed out")]
    Timeout,
    #[error("request canceled")]
    Canceled,
    #[error("source blocked until {retry_at_ms}")]
    SourceBlocked { retry_at_ms: i64 },
    #[error("internal error: {0}")]
    Internal(String),
    #[error("local media unavailable: {0}")]
    LocalMedia(String),
    #[error("storage error: {0}")]
    Storage(String),
    #[error("invalid rule package: {0}")]
    RuleInvalid(String),
}

impl DramaError {
    /// wire 错误码。
    pub fn code(&self) -> ErrorCode {
        match self {
            DramaError::BadRequest(_) => ErrorCode::BadRequest,
            DramaError::BadVersion(_) => ErrorCode::BadVersion,
            DramaError::TooLarge(_) => ErrorCode::TooLarge,
            DramaError::Unsupported(_) => ErrorCode::Unsupported,
            DramaError::NotFound(_) => ErrorCode::NotFound,
            DramaError::Parse(_) => ErrorCode::Parse,
            DramaError::Http { .. } => ErrorCode::Http,
            DramaError::Timeout => ErrorCode::Timeout,
            DramaError::Canceled => ErrorCode::Canceled,
            DramaError::SourceBlocked { .. } => ErrorCode::SourceBlocked,
            DramaError::Internal(_) => ErrorCode::Internal,
            DramaError::LocalMedia(_) => ErrorCode::LocalMedia,
            DramaError::Storage(_) => ErrorCode::Storage,
            DramaError::RuleInvalid(_) => ErrorCode::RuleInvalid,
        }
    }

    /// 是否建议前端重试。
    ///
    /// 口径：**只有「换个时刻可能就好了」的失败才算可重试**。
    /// `CANCELED` 明确是 `false`——它表示用户已经翻页了，弹错误框是打扰。
    pub fn retry(&self) -> bool {
        match self {
            DramaError::Timeout | DramaError::SourceBlocked { .. } => true,
            DramaError::Http { retryable, .. } => *retryable,
            _ => false,
        }
    }

    /// 是否属于「源站被限流」类错误（用于设置源冷却）。
    pub fn is_blocked(&self) -> bool {
        matches!(self, DramaError::SourceBlocked { .. })
    }

    /// 构造一个可重试的传输层错误。
    pub fn http_retryable(message: impl Into<String>, status: Option<u16>) -> Self {
        DramaError::Http {
            message: message.into(),
            status,
            retryable: true,
        }
    }

    /// 构造一个不可重试的传输层错误。
    pub fn http_fatal(message: impl Into<String>, status: Option<u16>) -> Self {
        DramaError::Http {
            message: message.into(),
            status,
            retryable: false,
        }
    }

    /// 按 HTTP 状态码分类：4xx 不可重试（除 408/429），5xx 可重试。
    ///
    /// 429 是**限流**，语义上应当重试但需退避，故归入可重试并附建议时刻。
    pub fn from_status(status: u16, message: impl Into<String>) -> Self {
        let message = message.into();
        match status {
            408 | 429 | 500..=599 => DramaError::Http {
                message,
                status: Some(status),
                retryable: true,
            },
            _ => DramaError::Http {
                message,
                status: Some(status),
                retryable: false,
            },
        }
    }
}

impl From<std::io::Error> for DramaError {
    fn from(e: std::io::Error) -> Self {
        DramaError::Storage(e.to_string())
    }
}

impl From<serde_json::Error> for DramaError {
    fn from(e: serde_json::Error) -> Self {
        DramaError::Parse(e.to_string())
    }
}

/// 错误体的可展示形式（`{code,msg,retry}`），供信封序列化。
#[derive(Debug, Serialize)]
pub struct WireError {
    pub code: &'static str,
    pub msg: String,
    pub retry: bool,
    /// 仅在 `source_blocked` 时出现。
    #[serde(rename = "retryAt", skip_serializing_if = "Option::is_none")]
    pub retry_at_ms: Option<i64>,
}

impl WireError {
    pub fn new(e: &DramaError) -> Self {
        WireError {
            code: e.code().as_str(),
            msg: e.to_string(),
            retry: e.retry(),
            retry_at_ms: match e {
                DramaError::SourceBlocked { retry_at_ms } => Some(*retry_at_ms),
                _ => None,
            },
        }
    }
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.msg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canceled_is_not_retryable() {
        // CANCELED 是正常现象，UI 不应弹错误框。
        assert!(!DramaError::Canceled.retry());
        assert_eq!(DramaError::Canceled.code(), ErrorCode::Canceled);
    }

    #[test]
    fn status_classification() {
        assert!(DramaError::from_status(503, "x").retry());
        assert!(DramaError::from_status(429, "x").retry());
        assert!(!DramaError::from_status(404, "x").retry());
        assert!(!DramaError::from_status(403, "x").retry());
    }

    #[test]
    fn code_strings_are_stable() {
        // 这些字符串是前端分支依据，改名即破坏契约。
        assert_eq!(ErrorCode::BadRequest.as_str(), "BAD_REQUEST");
        assert_eq!(ErrorCode::SourceBlocked.as_str(), "source_blocked");
        assert_eq!(ErrorCode::LocalMedia.as_str(), "local_media");
        assert_eq!(ErrorCode::RuleInvalid.as_str(), "RULE_INVALID");
    }

    #[test]
    fn unsupported_carries_no_retry() {
        let e = DramaError::Unsupported("playback");
        assert_eq!(e.code(), ErrorCode::Unsupported);
        assert!(!e.retry());
    }
}
