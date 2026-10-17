//! 红果内置主源：签名、SSR 解析、App 接口、三级取流、弹幕。
//!
//! ## 为什么红果不走规则引擎
//!
//! 它需要：两套签名（Gorgon + 注释签名 X-Argus/X-Ladon，含自研 SM3/ARX/XTEA 变体）、
//! App 签名接口 + 网页 SSR + 公开轨的三级降级、游标状态机（head/tail 模式、
//! 停滞检测、30 分钟会话过期）、搜索双通道合并 + 季数补齐算法。
//! 这些都不适合塞进声明式规则。
//!
//! ## 模块划分
//!
//! - [`sign`]：Gorgon 签名（元数据接口）
//! - [`comment_sign`]：注释签名（弹幕接口，X-Argus + X-Ladon）
//! - [`device`]：设备身份（`device_id` / `install_id` 持久化）
//! - [`app_api`]：签名 App 接口的请求构造与响应校验
//! - [`ssr`]：官网 `_ROUTER_DATA` 解析
//! - [`media`]：取流三级降级 + 密钥解码
//! - [`danmaku`]：弹幕

pub mod app_api;
pub mod comment_sign;
pub mod danmaku;
pub mod device;
pub mod media;
pub mod provider;
pub mod sign;
pub mod ssr;


/// 站点根。
pub const WEB_BASE: &str = "https://www.hongguoduanju.com";
/// App 接口根。
pub const APP_BASE: &str = "https://api5-normal-sinfonlineb.fqnovel.com";
/// 播放器侧 Referer（取流地址要求）。
pub const PLAYER_REFERER: &str = "https://novel.snssdk.com/";
/// 官网站内资源（公开轨视频、播放页）的 Referer。
pub const WEB_REFERER: &str = "https://www.hongguoduanju.com/";
/// 源 id。
pub const SOURCE_ID: &str = "hongguo";

/// 数字 ID 形状（1~32 位 ASCII 数字）。
pub fn is_numeric_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 32 && s.bytes().all(|b| b.is_ascii_digit())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn numeric_id_shape() {
        assert!(is_numeric_id("7654321"));
        assert!(is_numeric_id(&"9".repeat(32)));
        assert!(!is_numeric_id(""));
        assert!(!is_numeric_id(&"9".repeat(33)));
        assert!(!is_numeric_id("12a"));
        assert!(!is_numeric_id(" 12"));
        assert!(!is_numeric_id("-12"));
    }
}
