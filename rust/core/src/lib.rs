//! 红果短剧客户端 Rust 核心（MVP 骨架）。
//!
//! 对外仅暴露两个 C ABI 符号（ARCH §3.1）：
//! - `drama_request(const char* utf8_json) -> char*`
//! - `drama_free(char* ptr)`
//!
//! JSON-RPC 信封遵循 ARCH §3.1/§3.2：入参 `{v:1, op, source?, session?, sequence?, params?}`，
//! 出参 `{ok:true, data}` 或 `{ok:false, error:{code, msg, retry}}`。
//!
//! **取消协议与分级超时（ARCH §3.2）**：见 [`cancel`] 与 [`http`]。读类 op 带 `session`/`sequence`
//! 时参与仲裁——旧 `sequence` 直接丢弃（`CANCELED`）；内层分级超时映射为 `TIMEOUT`（`retry=true`）；
//! `cancelRead` 取消同 session 中 `sequence` 更小的在途读请求并返回被取消数量。
//!
//! **并发布局**：Dart 侧为常驻 worker **池**（见 `lib/data/services/rust_core.dart`），
//! 故「一个 worker 阻塞在网络时，另一个 worker 仍能处理 `cancelRead`」——`cancelRead` 登记的
//! 取消令牌会被在途读的 `tokio::select!` 观察到，**尽力**提前释放该请求。

pub mod cancel;
pub mod http;
pub mod source;
pub mod sources;

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use source::traits::{SourceError, SourceProvider};

/// 入参上限 1 MiB（ARCH §3.1）。
const MAX_INPUT_BYTES: usize = 1024 * 1024;

/// 信封版本（ARCH §3.2）。
const ENVELOPE_VERSION: u32 = 1;

/// 请求信封：`{v:1, op, source?, session?, sequence?, params?}`（ARCH §3.1/§3.2）。
#[derive(Debug, Deserialize)]
struct Request {
    #[serde(default = "default_version")]
    v: u32,
    op: String,
    /// 源 id：`None` 用默认源（hongguo）。W2 起使用。
    #[serde(default)]
    source: Option<String>,
    /// 读请求会话标识（ARCH §3.2）：字符集 `[0-9a-zA-Z-_:.]`，长度 ≤128；不合法 → `BAD_REQUEST`。
    #[serde(default)]
    session: Option<String>,
    /// 同 session 内单调递增的序号（ARCH §3.2）。缺失 → 不参与仲裁（兼容 `ping`/`version`）。
    #[serde(default)]
    sequence: Option<u64>,
    /// 各 op 参数（W2 起使用）。
    #[serde(default)]
    params: Value,
}

fn default_version() -> u32 {
    ENVELOPE_VERSION
}

/// 错误体：`{code, msg, retry}`（ARCH §3.2）。
#[derive(Debug, Serialize)]
struct ErrorBody {
    code: &'static str,
    msg: String,
    retry: bool,
}

/// 成功响应。
fn ok(data: Value) -> Value {
    json!({ "ok": true, "data": data })
}

/// 失败响应（`retry` 默认 false）。
fn err(code: &'static str, msg: impl Into<String>) -> Value {
    err_with(code, msg, false)
}

/// 失败响应（显式指定 `retry`）。
fn err_with(code: &'static str, msg: impl Into<String>, retry: bool) -> Value {
    json!({
        "ok": false,
        "error": ErrorBody { code, msg: msg.into(), retry },
    })
}

/// 取参数中的字符串（非字符串/缺失 → `None`）。
fn param_str(params: &Value, key: &str) -> Option<String> {
    params.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// 取参数中的无符号整数（缺失 → `default`）。
fn param_u32(params: &Value, key: &str, default: u32) -> u32 {
    params
        .get(key)
        .and_then(Value::as_u64)
        .map_or(default, |n| n as u32)
}

/// 取源实现并执行 `f`，把 [`SourceError`] 映射成信封 `error{code,msg,retry}`。
fn with_provider<F>(source: Option<&str>, f: F) -> Value
where
    F: FnOnce(&dyn SourceProvider) -> Result<Value, SourceError>,
{
    match source::provider(source) {
        Ok(p) => match f(p.as_ref()) {
            Ok(v) => ok(v),
            Err(e) => err_with(e.code(), e.to_string(), e.retry()),
        },
        Err(e) => err_with(e.code(), e.to_string(), e.retry()),
    }
}

/// 读类 op 的取消/超时包装（ARCH §3.2）。
///
/// - 带 `session`+`sequence`：进入时旧 `sequence` 直接 `CANCELED`（**不发网络请求**）；
///   收尾时若已被更新的 `sequence` 取代或本请求 `sequence ≤ cancel_before` → 结果替换为 `CANCELED`。
/// - 无论是否仲裁：都在 [`http::enter_read`] 下运行以施加**内层分级超时**（`TIMEOUT`，`retry=true`）。
fn arbitrated_read<F>(session: Option<&str>, sequence: Option<u64>, op: &str, run: F) -> Value
where
    F: FnOnce() -> Value,
{
    let budget = http::inner_timeout_for(op);
    let (Some(session), Some(sequence)) = (session, sequence) else {
        // 缺 session/sequence（如无状态调用）：不仲裁，但仍施加内层超时。
        let _guard = http::enter_read(None, budget);
        return run();
    };

    let token = CancellationToken::new();
    if cancel::begin(session, sequence, token.clone()) == cancel::Decision::Canceled {
        return err("CANCELED", "superseded by newer sequence");
    }

    let out = {
        let _guard = http::enter_read(Some(token), budget);
        run()
    };

    if cancel::complete(session, sequence) == cancel::Decision::Canceled {
        return err("CANCELED", "superseded by newer sequence");
    }
    out
}

/// 核心分发：解析信封并按 `op` 路由。
fn dispatch(input: &str) -> Value {
    if input.len() > MAX_INPUT_BYTES {
        return err(
            "TOO_LARGE",
            format!("input exceeds {MAX_INPUT_BYTES} bytes"),
        );
    }

    let req: Request = match serde_json::from_str(input) {
        Ok(req) => req,
        Err(e) => return err("BAD_REQUEST", format!("invalid request: {e}")),
    };

    if req.v != ENVELOPE_VERSION {
        return err(
            "BAD_VERSION",
            format!("unsupported envelope version: {}", req.v),
        );
    }

    // session 信封级校验（ARCH §3.2）：非法即 `BAD_REQUEST`。
    if let Some(s) = req.session.as_deref()
        && !cancel::is_valid_session(s)
    {
        return err("BAD_REQUEST", "invalid session");
    }

    match req.op.as_str() {
        // W0 冒烟：回声，用于验证 FFI 往返。无状态，不参与仲裁。
        "ping" => ok(Value::String("pong".to_owned())),

        // core 版本 + 已注册源的 caps（供 Dart 侧能力协商）。无状态，不参与仲裁。
        "version" => {
            let list: Vec<Value> = source::registered()
                .iter()
                .map(|p| json!({ "id": p.id(), "caps": p.caps().to_json() }))
                .collect();
            ok(json!({ "core": env!("CARGO_PKG_VERSION"), "sources": list }))
        }

        // 取消在途读：`{session, sequence}` → `{canceled:N}`；不阻塞、不参与仲裁。
        "cancelRead" => match (
            param_str(&req.params, "session"),
            req.params.get("sequence").and_then(Value::as_u64),
        ) {
            (Some(s), Some(seq)) if cancel::is_valid_session(&s) => {
                ok(json!({ "canceled": cancel::cancel_read(&s, seq) }))
            }
            _ => err("BAD_REQUEST", "cancelRead requires {session, sequence}"),
        },

        "catalog" => arbitrated_read(req.session.as_deref(), req.sequence, "catalog", || {
            with_provider(req.source.as_deref(), |p| {
                p.catalog(
                    param_str(&req.params, "category").as_deref(),
                    param_u32(&req.params, "page", 1),
                )
            })
        }),

        "recommend" => arbitrated_read(req.session.as_deref(), req.sequence, "recommend", || {
            with_provider(req.source.as_deref(), |p| p.recommend())
        }),

        "ranking" => arbitrated_read(req.session.as_deref(), req.sequence, "ranking", || {
            with_provider(req.source.as_deref(), |p| {
                p.ranking(param_str(&req.params, "board").as_deref())
            })
        }),

        "search" => match param_str(&req.params, "keyword") {
            Some(kw) if !kw.is_empty() => {
                arbitrated_read(req.session.as_deref(), req.sequence, "search", || {
                    with_provider(req.source.as_deref(), |p| p.search(&kw))
                })
            }
            _ => err("BAD_REQUEST", "missing keyword"),
        },

        "suggest" => match param_str(&req.params, "keyword") {
            Some(kw) if !kw.is_empty() => {
                arbitrated_read(req.session.as_deref(), req.sequence, "suggest", || {
                    with_provider(req.source.as_deref(), |p| p.suggest(&kw))
                })
            }
            _ => err("BAD_REQUEST", "missing keyword"),
        },

        // `detail` 轨① 直链不可得（EVIDENCE §21.4），但详情/选集元数据可免签取得。
        "detail" => match param_str(&req.params, "id") {
            Some(id) if !id.is_empty() => {
                arbitrated_read(req.session.as_deref(), req.sequence, "detail", || {
                    with_provider(req.source.as_deref(), |p| p.detail(&id))
                })
            }
            _ => err("BAD_REQUEST", "missing id"),
        },

        // 超时档位已落位（[`http::inner_timeout_for`] 的 `preload`/`moveDownloads` 档），
        // 业务尚未实现 → `UNSUPPORTED`。
        "preload" => err(
            "UNSUPPORTED",
            "preload not implemented (inner 15s / outer 20s reserved)",
        ),
        "moveDownloads" => err(
            "UNSUPPORTED",
            "moveDownloads not implemented (inner 600s / outer 620s reserved)",
        ),

        other => err("UNSUPPORTED", format!("unknown op: {other}")),
    }
}

/// 入口：`char* drama_request(const char* utf8_json)`。
/// 返回的指针必须由 [`drama_free`] 释放；任何情况下都返回合法 JSON（不返回空指针）。
/// # Safety
/// `ptr` 必须为有效的、以 NUL 结尾的 UTF-8 字节串指针（或空指针）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn drama_request(ptr: *const c_char) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if ptr.is_null() {
            return err("BAD_REQUEST", "null input");
        }
        // SAFETY: 调用方保证 `ptr` 指向以 NUL 结尾的 UTF-8 字节串。
        match unsafe { CStr::from_ptr(ptr) }.to_str() {
            Ok(input) => dispatch(input),
            Err(_) => err("BAD_REQUEST", "input is not valid UTF-8"),
        }
    }))
    .unwrap_or_else(|_| err("INTERNAL", "panic in rust core"));

    let json = serde_json::to_string(&response).unwrap_or_else(|_| {
        r#"{"ok":false,"error":{"code":"INTERNAL","msg":"serialize failed","retry":false}}"#
            .to_owned()
    });

    // SAFETY: `CString` 持有内存所有权；`into_raw` 后所有权交给调用方，由 [`drama_free`] 回收。
    CString::new(json).unwrap_or_default().into_raw()
}

/// 释放 [`drama_request`] 返回的字符串指针。
///
/// # Safety
/// `ptr` 必须是 [`drama_request`] 返回、且尚未释放的指针（或空指针）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn drama_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: `ptr` 由 `drama_request` 的 `CString::into_raw` 产生，且仅在此处回收一次。
    unsafe { drop(CString::from_raw(ptr)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_returns_pong() {
        let out = dispatch(r#"{"v":1,"op":"ping"}"#);
        assert_eq!(out["ok"], json!(true));
        assert_eq!(out["data"], json!("pong"));
    }

    #[test]
    fn unknown_op_is_unsupported() {
        let out = dispatch(r#"{"v":1,"op":"nope"}"#);
        assert_eq!(out["ok"], json!(false));
        assert_eq!(out["error"]["code"], json!("UNSUPPORTED"));
    }

    #[test]
    fn invalid_json_is_bad_request() {
        let out = dispatch("not json");
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn wrong_envelope_version_is_rejected() {
        let out = dispatch(r#"{"v":2,"op":"ping"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_VERSION"));
    }

    #[test]
    fn oversized_input_is_rejected() {
        let big = "a".repeat(MAX_INPUT_BYTES + 1);
        let out = dispatch(&big);
        assert_eq!(out["error"]["code"], json!("TOO_LARGE"));
    }

    #[test]
    fn version_reports_source_caps() {
        let out = dispatch(r#"{"v":1,"op":"version"}"#);
        assert_eq!(out["ok"], json!(true));
        assert_eq!(out["data"]["sources"][0]["id"], json!("hongguo"));
        assert_eq!(out["data"]["sources"][0]["caps"]["detail"], json!(true));
        assert_eq!(out["data"]["sources"][0]["caps"]["playback"], json!(false));
    }

    #[test]
    fn playback_op_is_unsupported() {
        let out = dispatch(r#"{"v":1,"op":"play","params":{"id":"x"}}"#);
        assert_eq!(out["error"]["code"], json!("UNSUPPORTED"));
    }

    #[test]
    fn preload_and_move_downloads_are_unsupported_tiers_reserved() {
        let out = dispatch(r#"{"v":1,"op":"preload"}"#);
        assert_eq!(out["error"]["code"], json!("UNSUPPORTED"));
        let out = dispatch(r#"{"v":1,"op":"moveDownloads"}"#);
        assert_eq!(out["error"]["code"], json!("UNSUPPORTED"));
        // 档位映射已落位（纯函数单测见 http::tests）。
        assert_eq!(
            http::inner_timeout_for("preload"),
            std::time::Duration::from_secs(15)
        );
        assert_eq!(
            http::inner_timeout_for("moveDownloads"),
            std::time::Duration::from_secs(600)
        );
    }

    #[test]
    fn search_without_keyword_is_bad_request() {
        let out = dispatch(r#"{"v":1,"op":"search"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn unknown_source_is_not_found() {
        let out = dispatch(r#"{"v":1,"op":"catalog","source":"nope"}"#);
        assert_eq!(out["error"]["code"], json!("NOT_FOUND"));
    }

    #[test]
    fn invalid_session_is_bad_request() {
        // 非法字符 / 超长 / 非 ASCII → BAD_REQUEST（任何 op 前的信封级校验）。
        let out = dispatch(r#"{"v":1,"op":"catalog","session":"bad session!","sequence":1}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        let out = dispatch(r#"{"v":1,"op":"ping","session":"中文"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn stale_sequence_is_canceled_without_network() {
        // 进入仲裁：已在途的更大 sequence 会让旧 sequence 在**发网络请求前**即被丢弃。
        let s = "stale-seq-test";
        assert_eq!(
            cancel::begin(s, 10, CancellationToken::new()),
            cancel::Decision::Continue
        );
        let out = dispatch(&format!(
            r#"{{"v":1,"op":"catalog","session":"{s}","sequence":3,"params":{{"category":"real-drama"}}}}"#
        ));
        assert_eq!(out["error"]["code"], json!("CANCELED"));
        assert_eq!(out["error"]["retry"], json!(false));
        let _ = cancel::complete(s, 10);
    }

    #[test]
    fn cancel_read_reports_count_and_zero_for_unknown_session() {
        // 不存在的 session → {canceled:0}。
        let out =
            dispatch(r#"{"v":1,"op":"cancelRead","params":{"session":"nope-x","sequence":9}}"#);
        assert_eq!(out["ok"], json!(true));
        assert_eq!(out["data"]["canceled"], json!(0));

        // 在途 5、6 两条，取消边界 6 → 只有 5 被取消。
        let s = "cancel-count-dispatch";
        assert_eq!(
            cancel::begin(s, 5, CancellationToken::new()),
            cancel::Decision::Continue
        );
        assert_eq!(
            cancel::begin(s, 6, CancellationToken::new()),
            cancel::Decision::Continue
        );
        let out = dispatch(&format!(
            r#"{{"v":1,"op":"cancelRead","params":{{"session":"{s}","sequence":6}}}}"#
        ));
        assert_eq!(out["data"]["canceled"], json!(1));
        let _ = cancel::complete(s, 5);
        let _ = cancel::complete(s, 6);
    }

    #[test]
    fn cancel_read_without_valid_params_is_bad_request() {
        let out = dispatch(r#"{"v":1,"op":"cancelRead"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        let out =
            dispatch(r#"{"v":1,"op":"cancelRead","params":{"session":"bad param","sequence":1}}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn ffi_roundtrip_via_c_abi() {
        let input = CString::new(r#"{"v":1,"op":"ping"}"#).unwrap();
        // SAFETY: `input` 为有效的 C 字符串。
        let out_ptr = unsafe { drama_request(input.as_ptr()) };
        assert!(!out_ptr.is_null());
        // SAFETY: `out_ptr` 由 `drama_request` 返回，尚未释放。
        let out = unsafe { CStr::from_ptr(out_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        // SAFETY: `out_ptr` 由 `drama_request` 返回，仅释放一次。
        unsafe { drama_free(out_ptr) };
        assert!(out.contains("\"ok\":true"));
        assert!(out.contains("pong"));
    }

    #[test]
    fn ffi_null_input_is_safe() {
        // SAFETY: 传入空指针，函数内部会安全处理。
        let out_ptr = unsafe { drama_request(std::ptr::null()) };
        assert!(!out_ptr.is_null());
        // SAFETY: `out_ptr` 由 `drama_request` 返回，尚未释放。
        let out = unsafe { CStr::from_ptr(out_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        // SAFETY: `out_ptr` 由 `drama_request` 返回，仅释放一次。
        unsafe { drama_free(out_ptr) };
        assert!(out.contains("BAD_REQUEST"));
    }
}
