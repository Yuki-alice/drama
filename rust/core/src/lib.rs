//! 红果短剧客户端 Rust 核心 —— **薄 FFI 门面**。
//!
//! 只暴露两个 C ABI 符号（见 `drama_core.h`）：
//! - `drama_request(const char* utf8_json) -> char*`
//! - `drama_free(char* ptr)`
//!
//! 所有业务在 `drama-engine`（源注册、调度、缓存、仲裁）及其下游 crate 里。
//! 本 crate **不含任何业务逻辑**——它的唯一职责是：
//!
//! 1. 把 C 字符串变成 UTF-8 校验过的 `&str`；
//! 2. 喂给 [`drama_engine::global().dispatch`]；
//! 3. 把响应序列化成 C 字符串（永不返回空指针）。
//!
//! ## 内存契约
//!
//! 返回指针必须由 [`drama_free`] 释放。任何输入（null、非法 UTF-8、超大）
//! 都返回**合法 JSON** 的错误信封，绝不返回 null——调用方无需判空。

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde_json::Value;

/// 入参上限（与 wire 契约一致）。
const MAX_INPUT_BYTES: usize = 1024 * 1024;

/// 输出错误信封（在任何无法正常分派的场景使用）。
fn error_envelope(code: &str, message: &str) -> CString {
    let body = serde_json::json!({
        "ok": false,
        "error": { "code": code, "msg": message, "retry": false }
    });
    CString::new(body.to_string()).unwrap_or_else(|_| {
        // 消息里若混入 NUL，回落到一段固定文本。
        CString::new(r#"{"ok":false,"error":{"code":"INTERNAL","msg":"encode failed","retry":false}}"#)
            .expect("static json has no NUL")
    })
}

/// 从原始指针读 UTF-8 字符串。
fn read_input<'a>(ptr: *const c_char) -> Result<&'a str, CString> {
    if ptr.is_null() {
        return Err(error_envelope("BAD_REQUEST", "请求为空"));
    }
    // SAFETY: `ptr` 非空且指向 NUL 结尾缓冲区（调用方契约）。
    let raw = unsafe { CStr::from_ptr(ptr) };
    let bytes = raw.to_bytes();
    if bytes.len() > MAX_INPUT_BYTES {
        return Err(error_envelope("TOO_LARGE", "请求超过 1 MiB 上限"));
    }
    std::str::from_utf8(bytes)
        .map_err(|e| error_envelope("BAD_REQUEST", &format!("请求不是合法 UTF-8: {e}")))
}

/// 序列化响应为 C 字符串。
fn to_c_string(response: &Value) -> CString {
    match serde_json::to_string(response) {
        Ok(text) => CString::new(text).unwrap_or_else(|_| {
            error_envelope("INTERNAL", "响应包含非法字符")
        }),
        Err(e) => error_envelope("INTERNAL", &format!("响应序列化失败: {e}")),
    }
}

/// `char* drama_request(const char* utf8_json)`。
///
/// 任何情况下都返回非空、以 NUL 结尾的合法 JSON。
///
/// # Safety
///
/// `input` 必须指向以 NUL 结尾、在调用期间有效的 UTF-8 缓冲区；
/// 返回值必须用 [`drama_free`] 释放。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn drama_request(input: *const c_char) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        let text = match read_input(input) {
            Ok(text) => text,
            Err(cstring) => return cstring,
        };
        // 引擎层的 dispatch 自带 panic 兜底；这里再兜一层，
        // 防止 dispatch 入口本身（如序列化）出问题。
        let response = drama_engine::global().dispatch(text);
        to_c_string(&serde_json::to_value(&response).unwrap_or_else(|_| {
            serde_json::json!({"ok": false, "error": {"code": "INTERNAL", "msg": "encode failed", "retry": false}})
        }))
    }));
    match response {
        Ok(cstring) => cstring.into_raw(),
        Err(_) => error_envelope("INTERNAL", "本地核心处理失败，请重试").into_raw(),
    }
}

/// `void drama_free(char* ptr)`。
///
/// 释放 [`drama_request`] 返回的指针；null 与外来指针是安全的（忽略）。
///
/// # Safety
///
/// `ptr` 必须是 [`drama_request`] 返回的指针，或为 null；
/// 同一指针不得释放两次。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn drama_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` 来自 `drama_request`，且按契约只释放一次。
        // `CString::from_raw` 接管所有权并在 drop 时释放——无需先 read。
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// 测试入口：从 `&str` 走同一条 dispatch 路径。
///
/// CLI 与测试用它，避免绕过 FFI 语义。
#[cfg(any(test, feature = "cli"))]
pub fn request_text(input: &str) -> String {
    let response = drama_engine::global().dispatch(input);
    serde_json::to_string(&serde_json::to_value(&response).unwrap_or_default())
        .unwrap_or_else(|_| r#"{"ok":false,"error":{"code":"INTERNAL","msg":"encode failed","retry":false}}"#.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn dispatch_text(op: &str, params: Value) -> Value {
        let envelope = json!({"v": 1, "op": op, "params": params});
        let text = request_text(&envelope.to_string());
        serde_json::from_str(&text).expect("response json")
    }

    #[test]
    fn ping_through_ffi_path() {
        let value = dispatch_text("ping", json!({}));
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"], "pong");
    }

    #[test]
    fn error_envelope_is_valid_json() {
        let envelope = error_envelope("TEST", "消息");
        let parsed: Value = serde_json::from_str(envelope.to_str().expect("utf8")).expect("json");
        assert_eq!(parsed["ok"], false);
        assert_eq!(parsed["error"]["code"], "TEST");
    }

    #[test]
    fn oversized_input_rejected() {
        let big = vec![b'x'; MAX_INPUT_BYTES + 1];
        let text = String::from_utf8(big).expect("utf8");
        let response = drama_engine::global().dispatch(&text);
        assert!(!response.is_ok());
    }

    #[test]
    fn response_always_serializable() {
        // panic 兜底路径也返回合法 JSON。
        let response = drama_engine::global().dispatch("\u{0}bad");
        let text = serde_json::to_string(&serde_json::to_value(&response).expect("value"))
            .expect("string");
        assert!(text.contains("\"ok\""));
    }
}
