//! 签名 App 接口：请求构造与响应校验。
//!
//! 五个端点：目录/推荐、详情、取流、弹幕（弹幕走注释签名）。

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::sign::{Signature, encode_query_sorted, sign_request};
use crate::{APP_BASE, device};

/// App UA（与参照实现一致）。
pub const APP_UA: &str = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; \
Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";

/// 固定 query 参数（顺序无关，`encode_query_sorted` 会排序）。
fn base_params(device_id: &str, install_id: &str) -> Vec<(String, String)> {
    [
        ("aid", "8662"),
        ("app_name", "novelread"),
        ("version_code", "73532"),
        ("version_name", "7.3.5.32"),
        ("manifest_version_code", "73532"),
        ("update_version_code", "73532"),
        ("channel", "update_64"),
        ("device_platform", "android"),
        ("os", "android"),
        ("ssmix", "a"),
        ("device_type", "25053RT47C"),
        ("device_brand", "Redmi"),
        ("language", "zh"),
        ("os_api", "36"),
        ("os_version", "16"),
        ("resolution", "1280*2772"),
        ("dpi", "520"),
        ("ac", "wifi"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.to_owned()))
    .chain([
        ("device_id".to_owned(), device_id.to_owned()),
        ("iid".to_owned(), install_id.to_owned()),
    ])
    .collect()
}

/// 构造一次签名请求。
#[derive(Debug)]
pub struct SignedRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    /// 便于测试与诊断。
    pub signature: Signature,
}

/// 构造签名 App 请求。
///
/// `path` 形如 `/novel/player/video_detail/v1/`。
pub fn build_request(
    method_post: bool,
    path: &str,
    extra_query: &[(&str, String)],
    body: Option<&Value>,
) -> Result<SignedRequest, String> {
    let identity = device::identity();
    let mut params = base_params(&identity.device_id, &identity.install_id);
    for (k, v) in extra_query {
        params.push(((*k).to_owned(), v.clone()));
    }

    let body_bytes = body
        .map(serde_json::to_vec)
        .transpose()
        .map_err(|e| format!("encode body: {e}"))?;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("clock error: {e}"))?;
    let unix_secs = now.as_secs() as u32;
    let unix_millis = now.as_millis() as i64;

    // `_rticket` 参与签名，必须先注入再编码。
    params.push(("_rticket".to_owned(), unix_millis.to_string()));
    let raw_query = encode_query_sorted(&mut params);
    let signature = sign_request(&raw_query, body_bytes.as_deref(), unix_secs, unix_millis);

    let url = format!("{APP_BASE}{path}?{raw_query}");
    let mut headers = vec![
        ("User-Agent".to_owned(), APP_UA.to_owned()),
        ("Accept".to_owned(), "application/json".to_owned()),
        ("X-XS-From-Web".to_owned(), "0".to_owned()),
        ("Sdk-Version".to_owned(), "2".to_owned()),
        ("X-Khronos".to_owned(), signature.khronos.clone()),
        ("X-Gorgon".to_owned(), signature.gorgon.clone()),
        ("X-SS-Req-Ticket".to_owned(), signature.ticket.clone()),
    ];
    if let Some(stub) = signature.stub.clone() {
        headers.push(("X-SS-STUB".to_owned(), stub));
    }
    if body_bytes.is_some() {
        headers.push((
            "Content-Type".to_owned(),
            "application/json; charset=utf-8".to_owned(),
        ));
    }

    let _ = method_post;
    Ok(SignedRequest {
        url,
        headers,
        body: body_bytes,
        signature,
    })
}

/// 业务码检查：`code` / `Code` / `status_code` / `BaseResp.StatusCode` 非 0 即失败。
///
/// 为什么四处都看：不同端点的封装层不一样，漏看一处就会把「接口不可用」
/// 当成「返回了空数据」，用户看到空列表而不是错误提示。
pub fn check_app_code(value: &Value) -> Result<(), String> {
    let code = value
        .get("code")
        .or_else(|| value.get("Code"))
        .or_else(|| value.get("status_code"))
        .and_then(as_code_string)
        .or_else(|| {
            value
                .get("BaseResp")
                .and_then(|b| b.get("StatusCode"))
                .and_then(as_code_string)
        });
    match code.as_deref() {
        Some(c) if c != "0" && !c.is_empty() => {
            Err(format!("红果 App 接口暂不可用（{}）", truncate(c, 20)))
        }
        _ => Ok(()),
    }
}

fn as_code_string(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn truncate(s: &str, limit: usize) -> String {
    let trimmed = s.trim();
    if trimmed.chars().count() <= limit {
        trimmed.to_owned()
    } else {
        trimmed.chars().take(limit).collect::<String>() + "..."
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn zero_code_passes() {
        assert!(check_app_code(&json!({"code": "0"})).is_ok());
        assert!(check_app_code(&json!({"code": 0})).is_ok());
        // 缺失码也算通过（部分端点不返回）。
        assert!(check_app_code(&json!({"data": {}})).is_ok());
    }

    #[test]
    fn nonzero_code_fails() {
        let err = check_app_code(&json!({"code": "1001"})).unwrap_err();
        assert!(err.contains("1001"));

        assert!(check_app_code(&json!({"Code": 500})).is_err());
        assert!(check_app_code(&json!({"status_code": "3"})).is_err());
        assert!(check_app_code(&json!({"BaseResp": {"StatusCode": "42"}})).is_err());
    }

    #[test]
    fn base_resp_zero_passes() {
        assert!(check_app_code(&json!({"BaseResp": {"StatusCode": "0"}})).is_ok());
    }

    #[test]
    fn truncate_limits_chars_not_bytes() {
        // 中文按字符截断，不能截出半个 UTF-8 序列。
        let s = "一二三四五六七八九十";
        let out = truncate(s, 3);
        assert_eq!(out, "一二三...");
    }
}
