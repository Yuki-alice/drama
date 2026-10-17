//! wire 契约：请求信封、响应信封、op 表。
//!
//! 这份文件是 Flutter 与 Rust 之间**唯一**的契约面。它同时充当：
//!
//! 1. **解析器**——`drama_request` 收到的 JSON 在这里被拆解与校验；
//! 2. **契约表**——[`OPS`] 列出全部 op 及其是否参与仲裁，测试据此守卫
//!    「代码加了 op 但文档没写」；
//! 3. **诊断出口**——`ops` op 直接返回这张表，前端可自检版本漂移。
//!
//! ## 信封
//!
//! 入参：`{v:1, op, source?, session?, sequence?, params?}`
//! 出参：`{ok:true, data}` 或 `{ok:false, error:{code, msg, retry}}`

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::error::{DramaError, WireError};
use crate::Result;

/// 入参上限 1 MiB。
pub const MAX_INPUT_BYTES: usize = 1024 * 1024;

/// 信封版本。
pub const ENVELOPE_VERSION: u32 = 1;

/// session 标识最大长度。
pub const MAX_SESSION_LEN: usize = 128;

/// 一个 op 的静态描述。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpSpec {
    pub name: &'static str,
    /// 是否参与 `session`/`sequence` 仲裁（读类）。
    pub arbitrated: bool,
    /// 内层超时预算（毫秒）。
    pub budget_ms: u64,
    /// 是否需要已注册的源（`false` = 引擎级 op）。
    pub needs_source: bool,
    /// 说明（供 `ops` op 与文档使用）。
    pub summary: &'static str,
}

/// 默认内层预算：60 s。
pub const DEFAULT_BUDGET_MS: u64 = 60_000;

/// **契约表**。新增 op 必须在此登记，否则 `dispatch` 无法路由。
///
/// 顺序即文档顺序：先无状态、再读类、再写类、再下载、再扩展源。
pub const OPS: &[OpSpec] = &[
    // ── 引擎 / 诊断 ────────────────────────────────────────────
    OpSpec { name: "ping", arbitrated: false, budget_ms: 5_000, needs_source: false, summary: "回声，验证 FFI 往返" },
    OpSpec { name: "version", arbitrated: false, budget_ms: 5_000, needs_source: false, summary: "核心版本、已注册源 caps、网关端口" },
    OpSpec { name: "ops", arbitrated: false, budget_ms: 5_000, needs_source: false, summary: "返回本契约表（自检版本漂移）" },
    OpSpec { name: "init", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "设置数据目录与下载目录，加载持久化状态" },
    OpSpec { name: "cancelRead", arbitrated: false, budget_ms: 5_000, needs_source: false, summary: "取消同 session 的在途读请求" },
    OpSpec { name: "diagnostics", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "运行期诊断快照（源健康、缓存、下载、网关）" },

    // ── 读类（参与仲裁）────────────────────────────────────────
    OpSpec { name: "catalog", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: true, summary: "分类目录单页" },
    OpSpec { name: "catalogPages", arbitrated: true, budget_ms: 120_000, needs_source: true, summary: "一次取回多页目录（首页续载）" },
    OpSpec { name: "categories", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: true, summary: "源的分类列表" },
    OpSpec { name: "recommend", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: true, summary: "首页推荐" },
    OpSpec { name: "ranking", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: true, summary: "榜单单页" },
    OpSpec { name: "rankingBoards", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: false, summary: "全部榜单板定义" },
    OpSpec { name: "search", arbitrated: true, budget_ms: 90_000, needs_source: true, summary: "在线搜索" },
    OpSpec { name: "suggest", arbitrated: true, budget_ms: 15_000, needs_source: true, summary: "搜索联想" },
    OpSpec { name: "detail", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: true, summary: "详情 + 分集" },
    OpSpec { name: "episodeGroups", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: true, summary: "选集分组（分组规则归 Rust）" },
    OpSpec { name: "play", arbitrated: true, budget_ms: DEFAULT_BUDGET_MS, needs_source: true, summary: "取流并注册代理会话" },
    OpSpec { name: "preload", arbitrated: true, budget_ms: 15_000, needs_source: true, summary: "预取下集" },
    OpSpec { name: "playQuality", arbitrated: true, budget_ms: 15_000, needs_source: true, summary: "换档（复用上次解析，零网络）" },
    OpSpec { name: "danmaku", arbitrated: true, budget_ms: 10_000, needs_source: true, summary: "弹幕时间段" },

    // ── 本地播放 ──────────────────────────────────────────────
    OpSpec { name: "playLocal", arbitrated: false, budget_ms: 15_000, needs_source: true, summary: "离线优先：已完成下载的分集" },
    OpSpec { name: "playFile", arbitrated: false, budget_ms: 15_000, needs_source: false, summary: "按任务 id 播放已下载文件" },

    // ── 追剧 / 进度 / 搜索历史 ──────────────────────────────────
    OpSpec { name: "followPut", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "写入/更新追剧" },
    OpSpec { name: "followDel", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "取消追剧" },
    OpSpec { name: "followList", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "追剧列表" },
    OpSpec { name: "historyPut", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "写入观看进度" },
    OpSpec { name: "historyGet", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "读观看进度" },
    OpSpec { name: "historyClear", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "清空观看进度" },
    OpSpec { name: "searchHistoryPut", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "写入搜索历史" },
    OpSpec { name: "searchHistoryList", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "搜索历史列表" },
    OpSpec { name: "searchHistoryDel", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "删除一条搜索历史" },
    OpSpec { name: "searchHistoryClear", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "清空搜索历史" },

    // ── 下载 ──────────────────────────────────────────────────
    OpSpec { name: "downloadStart", arbitrated: false, budget_ms: 20_000, needs_source: true, summary: "新建下载任务" },
    OpSpec { name: "downloadList", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "任务列表与进度" },
    OpSpec { name: "downloadPause", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "暂停任务" },
    OpSpec { name: "downloadRetry", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "重试任务" },
    OpSpec { name: "downloadCancel", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "取消并删除未完成数据" },
    OpSpec { name: "downloadDelete", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "删除任务与文件" },
    OpSpec { name: "downloadSetConcurrency", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "设置并行任务数" },
    OpSpec { name: "moveDownloads", arbitrated: true, budget_ms: 600_000, needs_source: false, summary: "迁移下载目录" },
    OpSpec { name: "storage", arbitrated: false, budget_ms: 30_000, needs_source: false, summary: "下载目录占用与剩余空间" },

    // ── 缓存 ──────────────────────────────────────────────────
    OpSpec { name: "cacheClear", arbitrated: false, budget_ms: 30_000, needs_source: false, summary: "清空目录缓存" },
    OpSpec { name: "cacheFlush", arbitrated: false, budget_ms: 30_000, needs_source: false, summary: "立即落盘缓存" },
    OpSpec { name: "cacheStats", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "缓存统计" },

    // ── 设置 ──────────────────────────────────────────────────
    OpSpec { name: "resourceSettings", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "读取网络/并发设置" },
    OpSpec { name: "saveResourceSettings", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "保存网络/并发设置" },

    // ── 扩展源 ────────────────────────────────────────────────
    OpSpec { name: "sources", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "已安装源列表（含规则源）" },
    OpSpec { name: "sourceInstall", arbitrated: false, budget_ms: 30_000, needs_source: false, summary: "安装/更新规则源包" },
    OpSpec { name: "sourceUninstall", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "卸载规则源" },
    OpSpec { name: "sourceEnable", arbitrated: false, budget_ms: 10_000, needs_source: false, summary: "启用/停用规则源" },
    OpSpec { name: "sourceValidate", arbitrated: false, budget_ms: 30_000, needs_source: false, summary: "校验规则源包（不安装）" },
    OpSpec { name: "sourceTest", arbitrated: true, budget_ms: 60_000, needs_source: false, summary: "对规则源做连通性与解析自测" },

    // 局域网同步（lan）与多用户（users）**不在范围内**：
    // 已按产品决定移除，契约表里不留空位——留着一个永远返回
    // UNSUPPORTED 的 op 只会让前端误以为「以后会有」。
];

/// 按名字查 op。
pub fn op_spec(name: &str) -> Option<&'static OpSpec> {
    OPS.iter().find(|o| o.name == name)
}

/// 按 op 取内层超时预算。
pub fn budget_for(name: &str) -> std::time::Duration {
    std::time::Duration::from_millis(op_spec(name).map_or(DEFAULT_BUDGET_MS, |o| o.budget_ms))
}

/// 请求信封。
#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    #[serde(default = "default_version")]
    pub v: u32,
    pub op: String,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub session: Option<String>,
    #[serde(default)]
    pub sequence: Option<u64>,
    #[serde(default)]
    pub params: Value,
}

fn default_version() -> u32 {
    ENVELOPE_VERSION
}

impl Request {
    /// 解析并校验信封。
    ///
    /// 校验顺序有意为之：**先看大小，再看版本，最后看 session**——
    /// 巨大入参不该先走一遍 JSON 解析。
    pub fn parse(input: &str) -> Result<Request> {
        if input.len() > MAX_INPUT_BYTES {
            return Err(DramaError::TooLarge(MAX_INPUT_BYTES));
        }
        let req: Request = serde_json::from_str(input)
            .map_err(|e| DramaError::BadRequest(format!("invalid request: {e}")))?;
        req.validate()?;
        Ok(req)
    }

    /// 校验版本与 session 形状。
    pub fn validate(&self) -> Result<()> {
        if self.v != ENVELOPE_VERSION {
            return Err(DramaError::BadVersion(self.v));
        }
        if let Some(session) = self.session.as_deref()
            && !is_valid_session(session)
        {
            return Err(DramaError::BadRequest(
                "session must match [0-9a-zA-Z-_:.] and be 1..=128 chars".to_owned(),
            ));
        }
        Ok(())
    }

    /// 取字符串参数。
    pub fn str_param(&self, key: &str) -> Option<&str> {
        self.params.get(key).and_then(Value::as_str)
    }

    /// 取无符号整数参数；缺失用 `default`，超 `u32` 饱和（**禁止 `as` 截断回绕**，
    /// 那会把巨大的 `depth` 静默变成 0）。
    pub fn u32_param(&self, key: &str, default: u32) -> u32 {
        self.params
            .get(key)
            .and_then(Value::as_u64)
            .map_or(default, |n| u32::try_from(n).unwrap_or(u32::MAX))
    }

    /// 取有符号整数参数。
    pub fn i64_param(&self, key: &str, default: i64) -> i64 {
        self.params.get(key).and_then(Value::as_i64).unwrap_or(default)
    }

    /// 取布尔参数。
    pub fn bool_param(&self, key: &str, default: bool) -> bool {
        self.params.get(key).and_then(Value::as_bool).unwrap_or(default)
    }
}

/// session 字符集：`[0-9a-zA-Z-_:.]`，长度 1..=128。
///
/// 收窄字符集是为了让 session 能安全进文件名与日志，不必再转义。
pub fn is_valid_session(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_SESSION_LEN
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':' | b'.'))
}

/// 错误体（wire）。
#[derive(Debug, Clone, Serialize)]
pub struct ErrorBody {
    pub code: &'static str,
    pub msg: String,
    pub retry: bool,
    #[serde(rename = "retryAt", skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<i64>,
}

impl From<&DramaError> for ErrorBody {
    fn from(e: &DramaError) -> Self {
        let wire = WireError::new(e);
        ErrorBody {
            code: wire.code,
            msg: wire.msg,
            retry: wire.retry,
            retry_at: wire.retry_at_ms,
        }
    }
}

/// 响应信封。
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum Response {
    Ok { ok: bool, data: Value },
    Err { ok: bool, error: ErrorBody },
}

impl Response {
    /// 成功响应。
    ///
    /// **不用 `json!` 宏**：宏对已有的 `Value` 会走 `to_value` 深拷贝整个 `data`
    /// （一页目录 5.6 KB、一次多页聚合 28 KB）。这里直接构造，`data` 是 move。
    pub fn ok(data: Value) -> Self {
        Response::Ok {
            ok: true,
            data,
        }
    }

    /// 失败响应。
    pub fn err(e: &DramaError) -> Self {
        Response::Err {
            ok: false,
            error: ErrorBody::from(e),
        }
    }

    /// 序列化为字符串。
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            r#"{"ok":false,"error":{"code":"INTERNAL","msg":"serialize failed","retry":false}}"#
                .to_owned()
        })
    }

    pub fn is_ok(&self) -> bool {
        matches!(self, Response::Ok { .. })
    }

    /// 取出 `data`（失败时 `None`）。
    pub fn data(&self) -> Option<&Value> {
        match self {
            Response::Ok { data, .. } => Some(data),
            Response::Err { .. } => None,
        }
    }
}

/// 构造成功响应的便捷入口：`ok(json!({...}))`。
pub fn ok(data: Value) -> Response {
    Response::ok(data)
}

/// 构造 `{ "items": [...] }` 形态的成功响应。
pub fn ok_items(items: Vec<Value>) -> Response {
    let mut map = Map::with_capacity(1);
    map.insert("items".to_owned(), Value::Array(items));
    Response::ok(Value::Object(map))
}

/// 契约表的 wire 形态（供 `ops` op）。
pub fn ops_json() -> Value {
    Value::Array(
        OPS.iter()
            .map(|o| {
                json!({
                    "name": o.name,
                    "arbitrated": o.arbitrated,
                    "budgetMs": o.budget_ms,
                    "needsSource": o.needs_source,
                    "summary": o.summary,
                })
            })
            .collect(),
    )
}

/// [`Envelope`] 别名，保留历史命名。
pub type Envelope = Response;

/// [`OpName`] 别名：op 名是运行期字符串，此处仅为可读性。
pub type OpName = str;

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn session_validation() {
        assert!(is_valid_session("hongguo:catalog:abc-1.2_3"));
        assert!(!is_valid_session(""));
        assert!(!is_valid_session("has space"));
        assert!(!is_valid_session("has/slash"));
        assert!(!is_valid_session(&"x".repeat(129)));
        assert!(is_valid_session(&"x".repeat(128)));
    }

    #[test]
    fn request_rejects_wrong_version() {
        let req = Request::parse(r#"{"v":2,"op":"ping"}"#).unwrap_err();
        assert_eq!(req.code(), crate::ErrorCode::BadVersion);
    }

    #[test]
    fn request_rejects_bad_session() {
        let e = Request::parse(r#"{"v":1,"op":"catalog","session":"bad session"}"#).unwrap_err();
        assert_eq!(e.code(), crate::ErrorCode::BadRequest);
    }

    #[test]
    fn request_rejects_oversized_input() {
        let big = "x".repeat(MAX_INPUT_BYTES + 1);
        let e = Request::parse(&big).unwrap_err();
        assert_eq!(e.code(), crate::ErrorCode::TooLarge);
    }

    #[test]
    fn params_saturate_instead_of_wrapping() {
        let req = Request::parse(r#"{"v":1,"op":"catalog","params":{"depth":18446744073709551615}}"#)
            .expect("parse");
        // 不能变成 0（那样会静默跟随水位）。
        assert_eq!(req.u32_param("depth", 1), u32::MAX);
    }

    #[test]
    fn contract_table_has_unique_names() {
        let mut names: Vec<&str> = OPS.iter().map(|o| o.name).collect();
        let count = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), count, "duplicate op names in OPS");
    }

    #[test]
    fn budget_lookup_falls_back_to_default() {
        assert_eq!(budget_for("preload").as_millis(), 15_000);
        assert_eq!(
            budget_for("no-such-op").as_millis(),
            u128::from(DEFAULT_BUDGET_MS)
        );
    }

    #[test]
    fn response_serializes_both_shapes() {
        let ok = Response::ok(json!({"a": 1}));
        assert!(ok.to_json().contains(r#""ok":true"#));

        let err = Response::err(&DramaError::Timeout);
        let text = err.to_json();
        assert!(text.contains(r#""code":"TIMEOUT""#));
        assert!(text.contains(r#""retry":true"#));
    }

    #[test]
    fn blocked_error_carries_retry_at() {
        let e = DramaError::SourceBlocked { retry_at_ms: 1234 };
        let text = Response::err(&e).to_json();
        assert!(text.contains(r#""retryAt":1234"#));
    }
}
