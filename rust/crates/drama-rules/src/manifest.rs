//! 规则包清单：schema 定义与加载。
//!
//! ## 两种形态
//!
//! - **作者态 YAML**：给人看的，可注释、可乱序；
//! - **分发态 JSON**：给机器的，规范化（键序固定、无空白），内容哈希可复现。
//!
//! 客户端两者都接受，但 YAML 会**先编译成 JSON 再走同一条校验路径**，
//! 保证「装上去的东西」永远只有一种形态。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// 规则包清单。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// schema 版本；当前只认 `1`。
    pub schema: u32,
    /// 源 id（`[a-z0-9][a-z0-9-]{0,63}`，不能是 `hongguo`）。
    pub id: String,
    /// 展示名。
    pub name: String,
    /// 语义化版本。
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub homepage: String,
    /// 源站基地址（必须 http(s) 绝对 URL）。
    pub base: String,
    /// 能力声明。
    #[serde(default)]
    pub caps: Caps,
    /// 默认请求头（可被各 operation 覆盖）。
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// UA 档案名：`mobile` / `desktop`。
    #[serde(default)]
    pub user_agent: UaProfile,
    /// 鉴权步骤（按序执行）。
    #[serde(default)]
    pub auth: Vec<Auth>,
    /// 各能力对应的操作。
    #[serde(default)]
    pub ops: Ops,
    /// 依赖的内置 codec（如 `codec.aaencode`）；缺失时拒绝安装。
    #[serde(default)]
    pub requires: Vec<String>,
}

/// 能力声明。
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct Caps {
    pub catalog: bool,
    pub search: bool,
    pub suggest: bool,
    #[serde(rename = "ranking")]
    pub ranking: bool,
    pub detail: bool,
    pub playback: bool,
    /// 声明了 playback 的源必须提供 `ops.playback`。
    #[serde(rename = "danmaku")]
    pub danmaku: bool,
}

impl Caps {
    /// 从 ops 有无推断（清单未显式声明时的兜底）。
    pub fn derive_from_ops(ops: &Ops) -> Self {
        Caps {
            catalog: ops.catalog.is_some(),
            search: ops.search.is_some(),
            suggest: ops.suggest.is_some(),
            ranking: ops.ranking.is_some(),
            detail: ops.detail.is_some(),
            playback: ops.playback.is_some(),
            danmaku: false,
        }
    }
}

/// UA 档案。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UaProfile {
    /// 手机浏览器（默认：多数短剧站按移动端分流）。
    #[default]
    Mobile,
    Desktop,
}

impl UaProfile {
    /// 对应 drama-net 的 UA 常量。
    pub fn value(self) -> &'static str {
        match self {
            UaProfile::Mobile => drama_net::USER_AGENT_VALUE,
            UaProfile::Desktop => drama_net::DESKTOP_UA,
        }
    }
}

/// 鉴权步骤。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Auth {
    /// 固定头（星果的 productId/token）。
    StaticHeaders {
        #[serde(default)]
        headers: BTreeMap<String, String>,
    },
    /// 登录换 token 并缓存。
    Login {
        request: RequestSpec,
        /// token 的提取路径（JSON 点路径）。
        extract: String,
        /// 缓存秒数。
        #[serde(default = "default_token_ttl")]
        cache_ttl_s: u64,
        /// 注入头名，如 `Authorization: Bearer {{token}}`。
        header: String,
    },
    /// 拼接签名（猫果：有序字面量 + 秘钥后哈希）。
    Sign {
        /// `md5` / `sha1` / `sha256`。
        algo: HashAlgo,
        /// 拼接模板（支持 `{{var}}`）。
        template: String,
        /// 追加在末尾的秘钥。
        #[serde(default)]
        secret: String,
        /// 结果放哪。
        output: Output,
    },
    /// HMAC 签名。
    Hmac {
        algo: HashAlgo,
        /// HMAC 密钥模板。
        key: String,
        /// 数据模板。
        data: String,
        output: Output,
    },
    /// 响应解包（AES）。
    Aes {
        /// `cbc` / `ecb`。
        mode: AesMode,
        /// 密钥模板（hex 或 UTF-8，由 `key_encoding` 决定）。
        key: String,
        /// IV 模板（ECB 不需要）。
        #[serde(default)]
        iv: String,
        /// 密钥编码。
        #[serde(default)]
        key_encoding: KeyEncoding,
        /// 填充。
        #[serde(default)]
        padding: Padding,
    },
    /// base64 编解码。
    #[serde(rename = "base64")]
    Base64 {
        /// `true` = 解码（默认），`false` = 编码。
        #[serde(default = "default_true")]
        decode: bool,
    },
    /// 字符替换表（猫果的 61 项映射）。
    RuneMap {
        /// `from → to` 逐字符映射。
        table: BTreeMap<char, char>,
    },
    /// 用请求 URI 前 N 字节派生密钥（牛果）。
    UriKey {
        /// 取前多少字节。
        #[serde(default = "default_uri_key_len")]
        length: usize,
    },
}

/// 哈希算法。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HashAlgo {
    Md5,
    Sha1,
    Sha256,
}

/// AES 模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AesMode {
    Cbc,
    Ecb,
}

/// 密钥编码。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KeyEncoding {
    /// 按 UTF-8 字节直接用。
    #[default]
    Utf8,
    /// 按十六进制解码。
    Hex,
}

/// 填充方式。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Padding {
    #[default]
    Pkcs7,
    None,
}

/// 签名输出位置。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Output {
    /// 放进请求头。
    Header(String),
    /// 放进 query 参数。
    Query(String),
}

/// 请求规格。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RequestSpec {
    /// `GET` / `POST`。
    pub method: Method,
    /// URL 模板（支持 `{{var}}`）。
    pub url: String,
    /// 额外请求头。
    pub headers: BTreeMap<String, String>,
    /// 请求体模板（POST 时用）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    /// 超时毫秒。
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,
    /// 响应体上限字节。
    #[serde(default = "default_body_limit")]
    pub max_body_bytes: usize,
}

impl Default for RequestSpec {
    fn default() -> Self {
        RequestSpec {
            method: Method::Get,
            url: String::new(),
            headers: BTreeMap::new(),
            body: None,
            timeout_ms: default_timeout(),
            max_body_bytes: default_body_limit(),
        }
    }
}

/// HTTP 方法。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Method {
    #[default]
    Get,
    Post,
}

/// 响应体提取方式。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Extract {
    /// JSON 点路径（`data.list`），支持 `|` 别名回退。
    Json { path: String },
    /// HTML CSS 选择器。
    Html { css: String },
    /// CSS 选择器 + 属性。
    HtmlAttr { css: String, attr: String },
    /// 正则捕获组。
    Regex { pattern: String, group: u8 },
    /// 整段文本。
    Text,
}

/// 字段映射。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct FieldMap {
    /// 从条目里取值的表达式（点路径 / `css@attr`）。
    pub from: String,
    /// 过滤器链（按序应用）。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub filters: Vec<String>,
    /// 缺省值。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub default: String,
}



/// 分页模式。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Pagination {
    /// `?page=N` 递增；条数小于 `size` 或为 0 即终止。
    Page {
        #[serde(default = "default_page_size")]
        size: u32,
        #[serde(default = "default_page_start")]
        start: u32,
    },
    /// 响应里有布尔标志（`is_end` / `has_more`）。
    Flag {
        /// 标志字段路径；`true` 表示「还有更多」。
        path: String,
        /// 标志取反（即字段表示「已结束」）。
        #[serde(default)]
        invert: bool,
    },
    /// 响应回传游标（`next_id` / `next_offset`）。
    Cursor {
        /// 游标字段路径。
        path: String,
        /// 游标放哪个 query 参数。
        param: String,
    },
    /// 只有一页。
    Single,
}



/// 分集规格。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ChapterSpec {
    /// 分集列表的取值表达式。
    pub items: String,
    /// 集号字段。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub index: String,
    /// 视频 id 字段。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub vid: String,
    /// 地址字段（网页类源直接给）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub url: String,
    /// 标题模板（支持 `{{index}}`）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub title_template: String,
}

/// 取流规格。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct PlaybackSpec {
    /// 取流请求（分集页 / 解析接口）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<RequestSpec>,
    /// 从响应提取地址。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extract: Option<Extract>,
    /// 候选线路列表。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variants: Option<VariantsSpec>,
    /// 清晰度来源字段。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub quality_from: String,
    /// 取流 Referer（模板）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub referer: String,
}

/// 候选线路。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct VariantsSpec {
    /// 线路列表路径。
    pub path: String,
    /// 地址字段。
    pub url: String,
    /// 清晰度字段。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub quality: String,
}

/// 各能力的操作定义。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Ops {
    pub catalog: Option<Operation>,
    pub search: Option<Operation>,
    pub suggest: Option<Operation>,
    pub ranking: Option<Operation>,
    pub detail: Option<Operation>,
    pub playback: Option<PlaybackSpec>,
}

/// 一个能力的完整管线。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Operation {
    /// 请求规格。
    pub request: RequestSpec,
    /// 条目列表的取值表达式；空 = 整个响应是单个对象。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub items: String,
    /// 字段映射（条目 → [`drama_types::Drama`]）。
    pub map: BTreeMap<String, FieldMap>,
    /// 分页模式。
    #[serde(default, skip_serializing_if = "Pagination::is_default")]
    pub pagination: Pagination,
    /// 分集规格（detail 用）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapters: Option<ChapterSpec>,
    /// 身份校验：详情响应必须回显请求 id。
    #[serde(default = "default_true")]
    pub identity_check: bool,
}

// `#[derive(Default)]` 不能用于带数据的变体（`#[default]` 只允许 unit 变体），
// 故手写；clippy 的 derivable 提示在此不适用。
#[allow(clippy::derivable_impls)]
impl Default for Pagination {
    fn default() -> Self {
        Pagination::Single
    }
}

impl Pagination {
    fn is_default(&self) -> bool {
        matches!(self, Pagination::Single)
    }
}

fn default_true() -> bool {
    true
}
fn default_token_ttl() -> u64 {
    21_600
}
fn default_uri_key_len() -> usize {
    16
}
fn default_timeout() -> u64 {
    12_000
}
fn default_body_limit() -> usize {
    8 * 1024 * 1024
}
fn default_page_size() -> u32 {
    24
}
fn default_page_start() -> u32 {
    1
}

/// 清单加载错误。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ManifestError {
    #[error("YAML 解析失败: {0}")]
    Yaml(String),
    #[error("JSON 解析失败: {0}")]
    Json(String),
    #[error("清单校验失败: {0}")]
    Invalid(String),
}

impl Manifest {
    /// 从 YAML 加载（作者态）。
    pub fn from_yaml(text: &str) -> Result<Manifest, ManifestError> {
        let manifest: Manifest =
            serde_yaml_ng::from_str(text).map_err(|e| ManifestError::Yaml(e.to_string()))?;
        Ok(manifest)
    }

    /// 从 JSON 加载（分发态）。
    pub fn from_json(text: &str) -> Result<Manifest, ManifestError> {
        let manifest: Manifest =
            serde_json::from_str(text).map_err(|e| ManifestError::Json(e.to_string()))?;
        Ok(manifest)
    }

    /// 从字节自动判别（JSON 以 `{` 开头，否则按 YAML）。
    pub fn from_bytes(bytes: &[u8]) -> Result<Manifest, ManifestError> {
        let text = String::from_utf8_lossy(bytes);
        let trimmed = text.trim_start();
        if trimmed.starts_with('{') {
            Self::from_json(&text)
        } else {
            Self::from_yaml(&text)
        }
    }

    /// 序列化为规范化 JSON（分发态）。
    ///
    /// `serde_json` 的 BTreeMap 保持键序，输出稳定，可做内容哈希。
    pub fn to_canonical_json(&self) -> Result<String, ManifestError> {
        serde_json::to_string(self).map_err(|e| ManifestError::Json(e.to_string()))
    }

    /// 计算内容哈希（sha256 的十六进制前 32 位）。
    pub fn content_hash(&self) -> Result<String, ManifestError> {
        use sha2::Digest;
        let canonical = self.to_canonical_json()?;
        let digest = sha2::Sha256::digest(canonical.as_bytes());
        Ok(digest
            .iter()
            .take(16)
            .map(|b| format!("{b:02x}"))
            .collect())
    }

    /// 能力位（显式声明优先，否则从 ops 推导）。
    pub fn effective_caps(&self) -> Caps {
        let derived = Caps::derive_from_ops(&self.ops);
        Caps {
            catalog: self.caps.catalog || derived.catalog,
            search: self.caps.search || derived.search,
            suggest: self.caps.suggest || derived.suggest,
            ranking: self.caps.ranking || derived.ranking,
            detail: self.caps.detail || derived.detail,
            playback: self.caps.playback || derived.playback,
            danmaku: self.caps.danmaku || derived.danmaku,
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    const SAMPLE_YAML: &str = r#"
schema: 1
id: wuguo
name: 伍果
version: 1.0.0
author: official
base: https://www.duanju55.com
user_agent: desktop
headers:
  Referer: "{{base}}/"
ops:
  catalog:
    request:
      url: "{{base}}{{category}}/page/{{page}}.html"
    items: "css:.public-list-box"
    map:
      title:
        from: "a@title"
    pagination:
      type: page
      size: 24
  detail:
    request:
      url: "{{base}}/detail/{{id}}.html"
    identity_check: true
"#;

    #[test]
    fn loads_yaml() {
        let manifest = Manifest::from_yaml(SAMPLE_YAML).expect("load");
        assert_eq!(manifest.id, "wuguo");
        assert_eq!(manifest.base, "https://www.duanju55.com");
        assert_eq!(manifest.user_agent, UaProfile::Desktop);
        assert!(manifest.ops.catalog.is_some());
        assert!(manifest.ops.detail.is_some());
    }

    #[test]
    fn caps_derive_from_ops() {
        let manifest = Manifest::from_yaml(SAMPLE_YAML).expect("load");
        let caps = manifest.effective_caps();
        assert!(caps.catalog);
        assert!(caps.detail);
        // 没写 playback / search → 不声明。
        assert!(!caps.playback);
        assert!(!caps.search);
    }

    #[test]
    fn yaml_compiles_to_stable_json() {
        let manifest = Manifest::from_yaml(SAMPLE_YAML).expect("load");
        let json1 = manifest.to_canonical_json().expect("json");
        // 从 JSON 再读一次，哈希必须一致（幂等）。
        let reparsed = Manifest::from_json(&json1).expect("reparse");
        assert_eq!(reparsed, manifest);
        assert_eq!(reparsed.content_hash().expect("hash"), manifest.content_hash().expect("hash"));
    }

    #[test]
    fn content_hash_detects_any_change() {
        let a = Manifest::from_yaml(SAMPLE_YAML).expect("load");
        let mut b = a.clone();
        b.name = "伍果改".to_owned();
        assert_ne!(a.content_hash().expect("hash"), b.content_hash().expect("hash"));
    }

    #[test]
    fn rejects_unknown_fields() {
        let bad = "schema: 1\nid: x\nname: x\nbase: https://a.com\nnot_a_field: 1\n";
        assert!(Manifest::from_yaml(bad).is_err());
    }

    #[test]
    fn rejects_missing_required_fields() {
        assert!(Manifest::from_yaml("schema: 1\nid: x\n").is_err());
    }

    #[test]
    fn accepts_json_distribution() {
        let manifest = Manifest::from_yaml(SAMPLE_YAML).expect("load");
        let json = manifest.to_canonical_json().expect("json");
        let reloaded = Manifest::from_bytes(json.as_bytes()).expect("load from bytes");
        assert_eq!(reloaded, manifest);
    }

    #[test]
    fn pagination_defaults_to_single() {
        let manifest = Manifest::from_yaml(SAMPLE_YAML).expect("load");
        let catalog = manifest.ops.catalog.expect("catalog");
        assert!(matches!(catalog.pagination, Pagination::Page { size: 24, start: 1 }));
    }

    #[test]
    fn request_spec_defaults() {
        let spec = RequestSpec::default();
        assert_eq!(spec.method, Method::Get);
        assert_eq!(spec.timeout_ms, 12_000);
        assert_eq!(spec.max_body_bytes, 8 * 1024 * 1024);
    }

    #[test]
    fn auth_variants_deserialize() {
        let yaml = r#"
schema: 1
id: maoguo
name: 猫果
base: https://api-store.qmplaylet.com
auth:
  - type: sign
    algo: md5
    template: "operation=1tag_id={{category}}"
    secret: "d3dGiJc651gSQ8w1"
    output:
      header: sign
  - type: rune_map
    table:
      "+": "P"
      "/": "X"
"#;
        let manifest = Manifest::from_yaml(yaml).expect("load");
        assert_eq!(manifest.auth.len(), 2);
        assert!(matches!(manifest.auth[0], Auth::Sign { algo: HashAlgo::Md5, .. }));
        assert!(matches!(manifest.auth[1], Auth::RuneMap { .. }));
    }

    #[test]
    fn uri_key_auth() {
        let yaml = r#"
schema: 1
id: niuguo
name: 牛果
base: https://a.com
auth:
  - type: uri_key
    length: 16
"#;
        let manifest = Manifest::from_yaml(yaml).expect("load");
        assert!(matches!(manifest.auth[0], Auth::UriKey { length: 16 }));
    }
}
