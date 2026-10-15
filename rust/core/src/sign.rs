//! 红果 App 接口签名（Gorgon 系）。
//!
//! 作用：给 App 接口（`video_detail/v1`、`video_model/v1`）计算
//! `X-Gorgon` / `X-Khronos` / `X-SS-Req-Ticket`（有 body 时还有 `X-SS-STUB`）。
//! 算法与参照 Go 实现逐字节一致，正确性由 `gorgon_matches_go_reference`
//! 用 Go 实现生成的固定向量锁定。

/// 19 位数字设备标识（与参照实现同分布：`1e18 + rand % 8e18`）。
pub fn new_device_id(random_u64: u64) -> String {
    (1_000_000_000_000_000_000u64 + random_u64 % 8_000_000_000_000_000_000u64).to_string()
}

/// 签名输出。
pub struct Signature {
    pub khronos: String,
    pub gorgon: String,
    pub ticket: String,
    pub stub: Option<String>,
}

/// 对 `raw_query`（已编码的原始 query 串）与 `body` 计算签名。
/// `unix_secs` / `unix_millis` 由调用方取同一时刻，避免两者漂移。
pub fn sign_request(
    raw_query: &str,
    body: Option<&[u8]>,
    unix_secs: u32,
    unix_millis: i64,
) -> Signature {
    let query_hash = md5::compute(raw_query.as_bytes());
    let mut payload = [0u8; 20];
    payload[..4].copy_from_slice(&query_hash.0[..4]);
    let stub = body.map(|b| {
        let body_hash = md5::compute(b);
        payload[4..8].copy_from_slice(&body_hash.0[..4]);
        hex_upper(&body_hash.0)
    });
    payload[12..16].copy_from_slice(&[0, 6, 11, 28]);
    payload[16..20].copy_from_slice(&unix_secs.to_be_bytes());

    const KEY: [u8; 20] = [
        0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2,
        0xc4, 0xa4, 0x96, 0x93, 0x8f,
    ];
    for (i, b) in payload.iter_mut().enumerate() {
        *b ^= KEY[i];
    }
    for i in 0..payload.len() {
        let mixed = payload[i].rotate_left(4) ^ payload[(i + 1) % payload.len()];
        payload[i] = mixed.reverse_bits() ^ 0xff ^ payload.len() as u8;
    }

    let mut signature = [0u8; 26];
    signature[..6].copy_from_slice(&[0x84, 0x04, 0x40, 0x1c, 0, 0]);
    signature[6..].copy_from_slice(&payload);

    Signature {
        khronos: unix_secs.to_string(),
        gorgon: hex_lower(&signature),
        ticket: unix_millis.to_string(),
        stub,
    }
}

/// 小写十六进制。
fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

/// 大写十六进制（`X-SS-STUB` 用，与 Go `%X` 同形）。
fn hex_upper(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

/// Go `url.Values.Encode` 兼容的 query 编码：按 key 排序；
/// `[A-Za-z0-9-_.~]` 原样，空格变 `+`，其余百分号编码（大写）。
pub fn encode_query_sorted(params: &mut [(String, String)]) -> String {
    params.sort_by(|a, b| a.0.cmp(&b.0));
    params
        .iter()
        .map(|(k, v)| format!("{}={}", query_escape(k), query_escape(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn query_escape(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gorgon_matches_go_reference() {
        // 向量由参照 Go 实现（固定 query/body/时间戳）生成。
        let sig = sign_request(
            "aid=8662&device_id=1234567890123456789",
            Some(br#"{"video_id":"7654321","content_type":1}"#),
            1700000000,
            1700000000000,
        );
        assert_eq!(
            sig.gorgon,
            "8404401c00007ee0845f76d72ebf7022103fad22c9d970977e8a"
        );
        assert_eq!(sig.khronos, "1700000000");
        assert_eq!(sig.ticket, "1700000000000");
        assert_eq!(
            sig.stub.as_deref(),
            Some("B7264D14479C67A3F08D32F05F7BF7BB")
        );
    }

    #[test]
    fn sign_without_body_has_no_stub() {
        let sig = sign_request("aid=8662", None, 1700000000, 1700000000000);
        assert!(sig.stub.is_none());
        assert_eq!(sig.gorgon.len(), 52);
    }

    #[test]
    fn query_encoding_sorts_and_escapes_like_go() {
        let mut params = vec![
            ("resolution".to_owned(), "1280*2772".to_owned()),
            ("aid".to_owned(), "8662".to_owned()),
            ("q".to_owned(), "a b".to_owned()),
        ];
        assert_eq!(
            encode_query_sorted(&mut params),
            "aid=8662&q=a+b&resolution=1280%2A2772"
        );
    }

    #[test]
    fn device_id_is_19_digits() {
        let id = new_device_id(42);
        assert_eq!(id.len(), 19);
        assert!(id.chars().all(|c| c.is_ascii_digit()));
    }
}
