//! 代理配置：直连 / 手动 / 跟随系统。
//!
//! 语义与设置页一致：`auto` 跟随环境变量（`HTTPS_PROXY` 等）与系统设置；
//! `direct` 强制直连；`manual` 用用户填的地址。
//!
//! **回环永远直连**：本机代理（媒体网关、封面代理）若走系统代理，
//! 在开了全局代理的机器上会自己绕回自己，表现为「播放一直转圈」。

use std::fmt;

use reqwest::Proxy;

/// 代理模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ProxyMode {
    /// 跟随系统 / 环境变量。
    #[default]
    Auto,
    /// 强制直连。
    Direct,
    /// 手动指定。
    Manual,
}

impl ProxyMode {
    pub fn as_str(self) -> &'static str {
        match self {
            ProxyMode::Auto => "auto",
            ProxyMode::Direct => "direct",
            ProxyMode::Manual => "manual",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "auto" => Some(ProxyMode::Auto),
            "direct" => Some(ProxyMode::Direct),
            "manual" => Some(ProxyMode::Manual),
            _ => None,
        }
    }
}

/// 代理设置。
#[derive(Debug, Clone, Default)]
pub struct ProxySettings {
    pub mode: ProxyMode,
    pub url: String,
}

/// 代理地址校验错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyError(pub String);

impl fmt::Display for ProxyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ProxyError {}

/// 校验手动代理地址。
///
/// 规则（与设置页文案一致）：
/// - 长度 ≤ 2048；
/// - scheme ∈ `http|https|socks5|socks5h`；
/// - 有 hostname；
/// - 无 query、无 fragment；
/// - path 为空或 `/`；
/// - 端口（若有）在 1..=65535。
pub fn validate_proxy_url(raw: &str) -> Result<(), ProxyError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ProxyError("请输入代理地址".to_owned()));
    }
    if trimmed.len() > 2048 {
        return Err(ProxyError("代理地址过长".to_owned()));
    }
    let parsed = url::Url::parse(trimmed)
        .map_err(|_| ProxyError("请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址".to_owned()))?;
    if !matches!(parsed.scheme(), "http" | "https" | "socks5" | "socks5h") {
        return Err(ProxyError(
            "请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址".to_owned(),
        ));
    }
    if parsed.host_str().is_none_or(str::is_empty) {
        return Err(ProxyError(
            "请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址".to_owned(),
        ));
    }
    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(ProxyError(
            "代理地址不能包含查询参数或片段".to_owned(),
        ));
    }
    if !matches!(parsed.path(), "" | "/") {
        return Err(ProxyError("代理地址不能包含路径".to_owned()));
    }
    // `url` crate 在解析阶段就拒绝 `:0` 之外的非法端口；端口 0 被它视为「无端口」，
    // 故这里只需确认「显式写了端口时，它落在合法区间」。
    if let Some(port) = parsed.port()
        && !(1..=65535).contains(&port)
    {
        return Err(ProxyError("代理端口无效".to_owned()));
    }
    Ok(())
}

/// 是否回环地址（永不代理）。
pub fn is_loopback(host: &str) -> bool {
    matches!(host, "127.0.0.1" | "localhost" | "::1" | "[::1]")
        || host.starts_with("127.")
}

/// 根据设置构造 reqwest 代理。
///
/// 返回 `None` 表示「不显式设置代理」，交给 reqwest 的默认行为
/// （读取 `HTTPS_PROXY`/`ALL_PROXY` 等环境变量）。
pub fn build_proxy(settings: &ProxySettings) -> Result<Option<Proxy>, ProxyError> {
    match settings.mode {
        ProxyMode::Direct => Ok(None),
        ProxyMode::Auto => Ok(None),
        ProxyMode::Manual => {
            validate_proxy_url(&settings.url)?;
            let proxy = Proxy::all(settings.url.trim())
                .map_err(|e| ProxyError(format!("代理地址无法使用: {e}")))?;
            // 本机回环一律直连，否则媒体网关会绕回自己。
            Ok(Some(proxy.no_proxy(reqwest::NoProxy::from_string(
                "127.0.0.1,localhost,::1",
            ))))
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn accepts_valid_proxy_urls() {
        assert!(validate_proxy_url("http://127.0.0.1:7890").is_ok());
        assert!(validate_proxy_url("socks5://user:pass@10.0.0.2:1080").is_ok());
        assert!(validate_proxy_url("https://proxy.example.com:443/").is_ok());
        assert!(validate_proxy_url("http://proxy.example.com").is_ok());
    }

    #[test]
    fn rejects_invalid_proxy_urls() {
        assert!(validate_proxy_url("").is_err());
        assert!(validate_proxy_url("ftp://x:1").is_err());
        assert!(validate_proxy_url("http://").is_err());
        assert!(validate_proxy_url("http://x:1/path").is_err());
        assert!(validate_proxy_url("http://x:1/?q=1").is_err());
        assert!(validate_proxy_url("http://x:1/#frag").is_err());
        assert!(validate_proxy_url("not a url").is_err());
    }

    #[test]
    fn rejects_oversized_proxy_url() {
        let long = format!("http://x:1/{}", "a".repeat(2100));
        assert!(validate_proxy_url(&long).is_err());
    }

    #[test]
    fn loopback_detection() {
        assert!(is_loopback("127.0.0.1"));
        assert!(is_loopback("localhost"));
        assert!(is_loopback("::1"));
        assert!(is_loopback("127.5.5.5"));
        assert!(!is_loopback("example.com"));
        assert!(!is_loopback("10.0.0.1"));
    }

    #[test]
    fn direct_mode_builds_no_proxy() {
        let settings = ProxySettings {
            mode: ProxyMode::Direct,
            url: "http://127.0.0.1:7890".to_owned(),
        };
        assert!(build_proxy(&settings).expect("build").is_none());
    }

    #[test]
    fn manual_mode_validates_before_building() {
        let settings = ProxySettings {
            mode: ProxyMode::Manual,
            url: "garbage".to_owned(),
        };
        assert!(build_proxy(&settings).is_err());
    }

    #[test]
    fn proxy_mode_roundtrips() {
        for mode in [ProxyMode::Auto, ProxyMode::Direct, ProxyMode::Manual] {
            assert_eq!(ProxyMode::parse(mode.as_str()), Some(mode));
        }
        assert_eq!(ProxyMode::parse("AUTO"), Some(ProxyMode::Auto));
        assert_eq!(ProxyMode::parse("nope"), None);
    }
}
