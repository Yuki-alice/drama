//! 源标识与能力声明。
//!
//! ## 为什么能力位是硬契约
//!
//! 一个源「没有搜索」和「搜索返回空」在前端是**完全不同的两件事**：前者应隐藏搜索框，
//! 后者应显示空态。历史上多个站源用「返回空列表」冒充「查过了」，导致用户以为剧不存在。
//! 因此 [`Caps`] 未声明的能力**必须**返回 [`DramaError::Unsupported`]。

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::drama::{Drama, Episode};
use crate::error::DramaError;
use crate::Result;

/// 源 id（小写、短横线分隔）。
///
/// 用 `String` 而不是枚举：扩展源是**运行期安装**的，编译期无法穷举。
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SourceId(String);

impl SourceId {
    pub fn new(id: impl Into<String>) -> Self {
        SourceId(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// 校验源 id 形状：`[a-z0-9][a-z0-9-]{0,63}`。
    ///
    /// 源 id 会进文件名、缓存 key 与会话标识，故不允许大写、空格、路径分隔符。
    ///
    /// 三个条件必须同时成立。这里显式分行写，而不是串成一个 `&&`/`||` 长表达式——
    /// 运算符优先级会让「首字符合法」与「其余字符合法」意外短路成同一层。
    pub fn is_valid(&self) -> bool {
        let bytes = self.0.as_bytes();
        if bytes.is_empty() || bytes.len() > 64 {
            return false;
        }
        let first_ok = bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit();
        let rest_ok = bytes
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-');
        first_ok && rest_ok
    }
}

impl std::fmt::Display for SourceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<&str> for SourceId {
    fn from(s: &str) -> Self {
        SourceId(s.to_owned())
    }
}

impl From<String> for SourceId {
    fn from(s: String) -> Self {
        SourceId(s)
    }
}

/// 内置主源 id。
pub const BUILTIN_SOURCE: &str = "hongguo";

/// 源的来源类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    /// 编译进二进制的内置源（红果）。
    Builtin,
    /// 运行期安装的规则扩展源。
    Rule,
}

/// 能力位。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Caps {
    pub catalog: bool,
    pub search: bool,
    pub suggest: bool,
    pub recommend: bool,
    pub ranking: bool,
    pub detail: bool,
    pub playback: bool,
    /// 弹幕。
    #[serde(default)]
    pub danmaku: bool,
    /// 播放地址是否加密（需要密钥才能解）。
    #[serde(default)]
    pub encrypted_media: bool,
}

impl Caps {
    /// 全开（红果）。
    pub const fn all() -> Self {
        Caps {
            catalog: true,
            search: true,
            suggest: true,
            recommend: true,
            ranking: true,
            detail: true,
            playback: true,
            danmaku: true,
            encrypted_media: true,
        }
    }

    /// 只有浏览面（无取流）。
    pub const fn browse_only() -> Self {
        Caps {
            catalog: true,
            search: true,
            suggest: false,
            recommend: false,
            ranking: false,
            detail: true,
            playback: false,
            danmaku: false,
            encrypted_media: false,
        }
    }

    pub fn to_json(self) -> Value {
        json!({
            "catalog": self.catalog,
            "search": self.search,
            "suggest": self.suggest,
            "recommend": self.recommend,
            "ranking": self.ranking,
            "detail": self.detail,
            "playback": self.playback,
            "danmaku": self.danmaku,
            "encryptedMedia": self.encrypted_media,
        })
    }

    /// 按 op 名取能力位；未知 op 返回 `None`（不参与能力协商）。
    pub fn allows(self, op: &str) -> Option<bool> {
        let flag = match op {
            "catalog" | "catalogPages" => self.catalog,
            "search" => self.search,
            "suggest" => self.suggest,
            "recommend" => self.recommend,
            "ranking" => self.ranking,
            "detail" | "episodeGroups" => self.detail,
            "play" | "preload" | "playQuality" => self.playback,
            "danmaku" => self.danmaku,
            _ => return None,
        };
        Some(flag)
    }
}

/// 源描述（供 `sources` op 列出）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDescriptor {
    pub id: SourceId,
    pub name: String,
    pub kind: SourceKind,
    pub caps: Value,
    /// 规则源版本（内置源为空）。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub version: String,
    /// 规则源作者（内置源为空）。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub author: String,
    /// 是否已启用。
    pub enabled: bool,
    /// 源站基地址（规则源用于显示与故障定位）。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub base_url: String,
}

/// 源能力实现。
///
/// **同步 trait**：引擎在 worker 线程上驱动，源实现内部用阻塞式 HTTP
/// （底层仍是 reqwest + 全局 Tokio 运行时），这样 trait 不必背 `async` 传染。
pub trait SourceProvider: Send + Sync {
    /// 源 id。
    fn id(&self) -> &SourceId;

    /// 显示名。
    fn name(&self) -> &str;

    /// 来源类型。
    fn kind(&self) -> SourceKind;

    /// 能力位。
    fn caps(&self) -> Caps;

    /// 源描述。
    fn descriptor(&self) -> SourceDescriptor {
        SourceDescriptor {
            id: self.id().clone(),
            name: self.name().to_owned(),
            kind: self.kind(),
            caps: self.caps().to_json(),
            version: String::new(),
            author: String::new(),
            enabled: true,
            base_url: String::new(),
        }
    }

    /// 分类列表。返回 `(id, name)` 对。
    ///
    /// 默认实现返回空——但调用方必须先查 [`Caps::catalog`]，
    /// 不得把「无分类」当成「分类为空」。
    fn categories(&self) -> Result<Vec<(String, String)>> {
        Err(DramaError::Unsupported("categories"))
    }

    /// 分类目录：`category` 为空表示「全部」。
    fn catalog(&self, _category: &str, _page: u32) -> Result<CatalogPage> {
        Err(DramaError::Unsupported("catalog"))
    }

    /// 首页推荐。
    fn recommend(&self) -> Result<Vec<Drama>> {
        Err(DramaError::Unsupported("recommend"))
    }

    /// 榜单板列表。
    fn ranking_boards(&self) -> Result<Vec<crate::drama::RankingBoard>> {
        Err(DramaError::Unsupported("ranking"))
    }

    /// 榜单：`board` 为板 id 或源内路由键。
    fn ranking(&self, _board: &str, _page: u32) -> Result<crate::drama::RankingPage> {
        Err(DramaError::Unsupported("ranking"))
    }

    /// 搜索。
    fn search(&self, _keyword: &str) -> Result<SearchResult> {
        Err(DramaError::Unsupported("search"))
    }

    /// 搜索联想。
    fn suggest(&self, _keyword: &str) -> Result<Vec<String>> {
        Err(DramaError::Unsupported("suggest"))
    }

    /// 详情 + 分集。
    fn detail(&self, _series_id: &str) -> Result<DramaDetail> {
        Err(DramaError::Unsupported("detail"))
    }

    /// 取流。
    fn play(&self, _request: PlayRequest) -> Result<crate::media::ResolvedMedia> {
        Err(DramaError::Unsupported("playback"))
    }

    /// 换档：复用上次解析结果，只重挑清晰度。
    fn play_variant(&self, _series_id: &str, _vid: &str, _quality: i64) -> Result<crate::media::ResolvedMedia> {
        Err(DramaError::Unsupported("playQuality"))
    }

    /// 预取下集。
    fn preload(&self, _request: PlayRequest) -> Result<crate::media::ResolvedMedia> {
        Err(DramaError::Unsupported("preload"))
    }

    /// 弹幕。
    fn danmaku(&self, _series_id: &str, _vid: &str, _start_ms: i64, _end_ms: i64) -> Result<DanmakuPage> {
        Err(DramaError::Unsupported("danmaku"))
    }
}

/// 一页目录。
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogPage {
    pub items: Vec<Drama>,
    pub has_more: bool,
    /// 源站给的告警（部分失败时的降级说明）。
    pub warning: String,
    /// 该页是否完全来自本地筛选（而非源站查询）。
    pub local_search: bool,
}

/// 搜索结果。
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub items: Vec<Drama>,
    /// 源站报告的总数（`0` = 未提供）。
    pub total: usize,
    /// 结果被截断（源站限制或超时）。
    pub limited: bool,
    pub warning: String,
}

/// 详情。
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DramaDetail {
    pub drama: Drama,
    pub episodes: Vec<Episode>,
    pub warning: String,
}

/// 取流请求。
#[derive(Debug, Clone)]
pub struct PlayRequest {
    pub series_id: String,
    /// 1-based 集号。
    pub episode: u32,
    /// 已知 `vid` 时优先用它（省一次详情请求）。
    pub vid: Option<String>,
    /// 期望清晰度上限；`0` = 要最高。
    pub quality: i64,
}

/// 弹幕条目。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DanmakuItem {
    pub id: String,
    pub text: String,
    pub time_ms: i64,
}

/// 一页弹幕。
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DanmakuPage {
    pub episode_id: String,
    pub items: Vec<DanmakuItem>,
    pub start_ms: i64,
    /// 下一次请求的起点；`0` = 没有更多。
    pub next_ms: i64,
    pub total: i64,
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn source_id_validation() {
        assert!(SourceId::new("hongguo").is_valid());
        assert!(SourceId::new("huangguo-video").is_valid());
        assert!(SourceId::new("a1").is_valid());
        // 大写、空格、下划线、斜杠、空串都不合法。
        assert!(!SourceId::new("Hongguo").is_valid());
        assert!(!SourceId::new("hong guo").is_valid());
        assert!(!SourceId::new("hong_guo").is_valid());
        assert!(!SourceId::new("a/b").is_valid());
        assert!(!SourceId::new("").is_valid());
        assert!(!SourceId::new("x".repeat(65)).is_valid());
    }

    #[test]
    fn caps_gate_unknown_ops() {
        let caps = Caps::browse_only();
        assert_eq!(caps.allows("catalog"), Some(true));
        assert_eq!(caps.allows("play"), Some(false));
        // 未参与协商的 op 返回 None（不是 false）。
        assert_eq!(caps.allows("ping"), None);
    }

    #[test]
    fn builtin_source_id_is_valid() {
        assert!(SourceId::new(BUILTIN_SOURCE).is_valid());
    }
}
