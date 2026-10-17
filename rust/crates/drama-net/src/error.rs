//! HTTP 错误分类。
//!
//! 分类的**唯一目的**是回答「能不能重试」。因此错误只分三类：
//! 传输层可重试、传输层不可重试、以及被取消/超时这两种独立语义。

use std::fmt;

/// 错误种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpErrorKind {
    /// 传输层失败（DNS/TCP/TLS/连接重置）。
    Transport,
    /// 被取消（协作式，来自 `CancellationToken`）。
    Canceled,
    /// 超时。
    Timeout,
}

/// HTTP 错误。
#[derive(Debug, Clone)]
pub struct HttpError {
    pub kind: HttpErrorKind,
    pub status: Option<u16>,
    pub retryable: bool,
    pub message: String,
}

impl HttpError {
    pub fn transport(message: impl Into<String>, retryable: bool) -> Self {
        HttpError {
            kind: HttpErrorKind::Transport,
            status: None,
            retryable,
            message: message.into(),
        }
    }

    pub fn status(status: u16, message: impl Into<String>) -> Self {
        // 4xx 不可重试（除 408/429）；5xx 可重试。
        let retryable = matches!(status, 408 | 429 | 500..=599);
        HttpError {
            kind: HttpErrorKind::Transport,
            status: Some(status),
            retryable,
            message: message.into(),
        }
    }

    pub fn canceled() -> Self {
        HttpError {
            kind: HttpErrorKind::Canceled,
            status: None,
            retryable: false,
            message: "request canceled".to_owned(),
        }
    }

    pub fn timeout() -> Self {
        HttpError {
            kind: HttpErrorKind::Timeout,
            status: None,
            retryable: true,
            message: "request timed out".to_owned(),
        }
    }

    /// 是否可重试。
    pub fn retryable(&self) -> bool {
        self.retryable
    }
}

impl fmt::Display for HttpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.status {
            Some(code) => write!(f, "{} (HTTP {code})", self.message),
            None => f.write_str(&self.message),
        }
    }
}

impl std::error::Error for HttpError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_classification() {
        assert!(HttpError::status(503, "x").retryable());
        assert!(HttpError::status(429, "x").retryable());
        assert!(HttpError::status(408, "x").retryable());
        assert!(!HttpError::status(404, "x").retryable());
        assert!(!HttpError::status(403, "x").retryable());
        assert!(!HttpError::status(401, "x").retryable());
    }

    #[test]
    fn timeout_is_retryable_cancel_is_not() {
        assert!(HttpError::timeout().retryable());
        assert!(!HttpError::canceled().retryable());
        assert_eq!(HttpError::canceled().kind, HttpErrorKind::Canceled);
    }
}
