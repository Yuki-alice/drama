//! 红果 App 接口签名（Gorgon 系）。
//!
//! 作用：给 App 接口（`video_detail/v1`、`video_model/v1`、
//! `category/landpage/v`）计算 `X-Gorgon` / `X-Khronos` / `X-SS-Req-Ticket`，
//! 有 body 时还有 `X-SS-STUB`。
//!
//! 算法与参照 Go 实现逐字节一致，正确性由固定向量锁定。
//!
//! ## 三个易错点
//!
//! 1. **`X-SS-STUB` 是大写 hex，`X-Gorgon` 是小写 hex**——反了服务端不认；
//! 2. 第二轮的 `payload[(i+1)%20]` 读的是**已被本轮改写过的**值（原地变换），
//!    不是原始值。写成两遍独立遍历就错了；
//! 3. query 必须按 key 排序后编码（Go `url.Values.Encode` 语义），
//!    因为 MD5 覆盖的是**逐字节的 query 串**。

/// 签名输出。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    pub khronos: String,
    pub gorgon: String,
    pub ticket: String,
    pub stub: Option<String>,
}

/// 对 `raw_query`（已编码的原始 query 串）与 `body` 计算签名。
///
/// `unix_secs` / `unix_millis` 必须取自同一时刻，否则会漂移。
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
    // 原地变换：第 i 项读到的是第 i+1 项的**当前**值（i 之前的已被改写）。
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
pub(crate) fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

/// 大写十六进制（`X-SS-STUB` 用）。
pub(crate) fn hex_upper(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

/// Go `url.Values.Encode` 兼容的 query 编码。
///
/// 按 key 排序；`[A-Za-z0-9-_.~]` 原样，空格变 `+`，其余百分号编码（大写）。
/// **必须与 Go 逐字节一致**，否则签名对不上。
pub fn encode_query_sorted(params: &mut [(String, String)]) -> String {
    params.sort_by(|a, b| a.0.cmp(&b.0));
    params
        .iter()
        .map(|(k, v)| format!("{}={}", query_escape(k), query_escape(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn query_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            b' ' => out.push('+'),
            _ => {
                const HEX: &[u8; 16] = b"0123456789ABCDEF";
                out.push('%');
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 0xf) as usize] as char);
            }
        }
    }
    out
}

/// 生成 19 位数字设备标识（`1e18 + rand % 8e18`）。
pub fn new_device_id(random_u64: u64) -> String {
    (1_000_000_000_000_000_000u64 + random_u64 % 8_000_000_000_000_000_000u64).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gorgon_matches_reference_vector() {
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
        assert_eq!(sig.stub.as_deref(), Some("B7264D14479C67A3F08D32F05F7BF7BB"));
    }

    #[test]
    fn sign_without_body_has_no_stub() {
        let sig = sign_request("aid=8662", None, 1700000000, 1700000000000);
        assert!(sig.stub.is_none());
        assert_eq!(sig.gorgon.len(), 52);
    }

    #[test]
    fn stub_is_uppercase_and_gorgon_lowercase() {
        let sig = sign_request("a=1", Some(b"body"), 1, 2);
        let stub = sig.stub.expect("stub");
        assert_eq!(stub.len(), 32);
        assert!(stub.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(stub.chars().any(|c| c.is_ascii_uppercase()) || stub.chars().all(|c| c.is_ascii_digit()));
        assert!(sig.gorgon.chars().all(|c| !c.is_ascii_uppercase()));
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
    fn query_encoding_keeps_unreserved_chars() {
        let mut params = vec![(
            "k".to_owned(),
            "AZaz09-_.~".to_owned(),
        )];
        assert_eq!(encode_query_sorted(&mut params), "k=AZaz09-_.~");
    }

    #[test]
    fn device_id_is_19_digits() {
        for seed in [0u64, 42, u64::MAX] {
            let id = new_device_id(seed);
            assert_eq!(id.len(), 19, "seed={seed}");
            assert!(id.chars().all(|c| c.is_ascii_digit()));
        }
    }

    #[test]
    fn signature_is_deterministic() {
        let a = sign_request("x=1", Some(b"b"), 100, 200);
        let b = sign_request("x=1", Some(b"b"), 100, 200);
        assert_eq!(a, b);
    }

    #[test]
    fn different_queries_differ() {
        let a = sign_request("x=1", None, 100, 200);
        let b = sign_request("x=2", None, 100, 200);
        assert_ne!(a.gorgon, b.gorgon);
    }
}
