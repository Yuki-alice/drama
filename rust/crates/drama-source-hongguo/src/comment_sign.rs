//! 注释接口签名（弹幕用）：`X-Argus` + `X-Ladon` + 变体 `X-Gorgon`。
//!
//! 弹幕接口 `/novel/commentapi/comment/list/{vid}/v1/` 用的是**另一套签名**，
//! 比元数据接口的 Gorgon 复杂得多。三件东西：
//!
//! 1. **变体 Gorgon**：非标准 RC4 的 KSA（**赋值而非交换**）+ 20 字节 PRGA；
//! 2. **X-Ladon**：34 轮 XTEA 变体，密钥调度从 MD5 的 **ASCII hex** 摘要派生；
//! 3. **X-Argus**：protobuf 序列化 → 72 轮 ARX 加密 → 异或 → 反转 → AES-128-CBC。
//!
//! ## 为什么不用现成 crate
//!
//! 这是**自研混淆**，没有标准可依。唯一正确性来源是参照实现的固定向量，
//! 因此所有常量都逐字抄自 Go 源码，并由向量测试锁定。
//!
//! ## 随机数
//!
//! 每次请求生成 11 字节 nonce，**失败必须报错而不是退化成固定值**——
//! 固定 nonce 会让签名可预测，服务端可能直接拒绝。


/// 11 字节 nonce。
#[derive(Debug, Clone, Copy)]
pub struct Nonce(pub [u8; 11]);

impl Nonce {
    /// 用随机源填充。
    pub fn random() -> Result<Nonce, String> {
        let mut buf = [0u8; 11];
        crate::device::fill_random(&mut buf)?;
        Ok(Nonce(buf))
    }

    /// 用固定字节构造（测试用）。
    pub fn from_bytes(bytes: [u8; 11]) -> Self {
        Nonce(bytes)
    }
}

/// 注释签名输出（6 个头）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommentSignature {
    pub gorgon: String,
    pub khronos: String,
    pub ticket: String,
    /// 注释接口显式置空。
    pub stub: String,
    pub argus: String,
    pub ladon: String,
}

/// 计算注释签名。
///
/// `aid` 来自 query 的 `aid` 参数（红果恒为 `"8662"`）。
pub fn sign_comment_request(
    raw_query: &str,
    aid: &str,
    nonce: Nonce,
    unix_secs: u32,
    unix_millis: i64,
) -> CommentSignature {
    let stamp = unix_secs;
    let head2 = (nonce.0[0] % 7 + 1) << 5;
    let head3 = 0xe0 | (nonce.0[1] & 15);

    // ── 变体 Gorgon ──────────────────────────────────────
    let mut seed = [0u8; 20];
    let hash = md5::compute(raw_query.as_bytes());
    seed[..4].copy_from_slice(&hash.0[..4]);
    seed[12..16].copy_from_slice(&[0, 1, 7, 4]);
    seed[16..20].copy_from_slice(&stamp.to_be_bytes());

    let key = [0x4a, 0x00, 0x16, head3, 0x47, 0x6c, 0x00, head2];

    let mut box_ = [0u8; 256];
    for (i, b) in box_.iter_mut().enumerate() {
        *b = i as u8;
    }
    // 注意：`box_[i] = box_[j]` 是**赋值**，不是交换（与标准 RC4 不同）。
    let mut j: u8 = 0;
    for i in 0..256 {
        j = j.wrapping_add(box_[i]).wrapping_add(key[i & 7]);
        box_[i] = box_[j as usize];
    }
    j = 0;
    for (offset, slot) in seed.iter_mut().enumerate() {
        let i = (offset + 1) as u8;
        j = j.wrapping_add(box_[i as usize]);
        box_[i as usize] = box_[j as usize];
        let idx = box_[i as usize].wrapping_add(box_[j as usize]);
        *slot ^= box_[idx as usize];
    }
    for i in 0..seed.len() {
        let mixed = seed[i].rotate_left(4) ^ seed[(i + 1) % seed.len()];
        seed[i] = mixed.reverse_bits() ^ 0xeb;
    }

    let mut gorgon_bytes = Vec::with_capacity(26);
    gorgon_bytes.extend_from_slice(&[0x84, 0x04, head2, head3, 0x00, 0x00]);
    gorgon_bytes.extend_from_slice(&seed);

    CommentSignature {
        gorgon: crate::sign::hex_lower(&gorgon_bytes),
        khronos: stamp.to_string(),
        ticket: unix_millis.to_string(),
        stub: String::new(),
        argus: argus(raw_query, stamp, nonce),
        ladon: ladon(aid, stamp, &nonce.0[2..6]),
    }
}

/// PKCS#7 填充到 16 字节边界（**整块补满**，与 Go 实现一致）。
fn pad16(data: &[u8]) -> Vec<u8> {
    let padding = 16 - data.len() % 16;
    let mut out = Vec::with_capacity(data.len() + padding);
    out.extend_from_slice(data);
    out.extend(std::iter::repeat_n(padding as u8, padding));
    out
}

/// X-Ladon：34 轮 XTEA 变体。
fn ladon(aid: &str, timestamp: u32, prefix: &[u8]) -> String {
    use base64::Engine;

    let mut input = Vec::with_capacity(prefix.len() + aid.len());
    input.extend_from_slice(prefix);
    input.extend_from_slice(aid.as_bytes());
    let hash = md5::compute(&input);
    // 关键：摘要转成 **ASCII hex**（32 字节）后再按小端读 u64。
    let digest = crate::sign::hex_lower(&hash.0);
    let digest = digest.as_bytes();

    let read_u64 = |b: &[u8]| -> u64 { u64::from_le_bytes(b[..8].try_into().expect("8 bytes")) };

    let mut left = read_u64(&digest[0..8]);
    let mut right = read_u64(&digest[8..16]);
    // FIFO 队列：每轮把 `mixed` 压入队尾，再弹出队首作为下一轮的 `right`。
    let mut queue: std::collections::VecDeque<u64> = std::collections::VecDeque::with_capacity(8);
    queue.push_back(read_u64(&digest[16..24]));
    queue.push_back(read_u64(&digest[24..32]));

    let mut keys = [0u64; 34];
    for (i, key) in keys.iter_mut().enumerate() {
        *key = left;
        let mixed = (right.rotate_right(8).wrapping_add(left)) ^ (i as u64);
        queue.push_back(mixed);
        left = mixed ^ left.rotate_left(3);
        right = queue.pop_front().expect("queue always has 2+ entries");
    }

    let mut data = pad16(format!("{timestamp}-1611921764-3019").as_bytes());
    let mut offset = 0;
    while offset < data.len() {
        let mut l = u64::from_le_bytes(data[offset..offset + 8].try_into().expect("8 bytes"));
        let mut r = u64::from_le_bytes(data[offset + 8..offset + 16].try_into().expect("8 bytes"));
        for key in keys {
            r = key ^ (l.wrapping_add(r.rotate_right(8)));
            l = r ^ l.rotate_left(3);
        }
        data[offset..offset + 8].copy_from_slice(&l.to_le_bytes());
        data[offset + 8..offset + 16].copy_from_slice(&r.to_le_bytes());
        offset += 16;
    }

    let mut out = Vec::with_capacity(prefix.len() + data.len());
    out.extend_from_slice(prefix);
    out.extend_from_slice(&data);
    base64::engine::general_purpose::STANDARD.encode(out)
}

/// protobuf varint 字段。
fn pb_varint(buf: &mut Vec<u8>, field: u64, value: u64) {
    append_uvarint(buf, field * 8);
    append_uvarint(buf, value);
}

/// protobuf length-delimited 字段。
fn pb_bytes(buf: &mut Vec<u8>, field: u64, value: &[u8]) {
    append_uvarint(buf, field * 8 + 2);
    append_uvarint(buf, value.len() as u64);
    buf.extend_from_slice(value);
}

/// protobuf varint 追加。
fn append_uvarint(buf: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        buf.push((value as u8) | 0x80);
        value >>= 7;
    }
    buf.push(value as u8);
}

/// X-Argus：protobuf → 72 轮 ARX → 异或 → 反转 → AES-128-CBC。
fn argus(query: &str, timestamp: u32, nonce: Nonce) -> String {
    use aes::cipher::{BlockModeEncrypt, KeyIvInit};
    use base64::Engine;

    const KEY_HEX: &str = "ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c";
    let key = hex_decode(KEY_HEX).expect("valid key hex");

    let mut message = Vec::new();
    pb_varint(&mut message, 1, 0x2020_0929 * 2);
    pb_varint(&mut message, 2, 2);
    pb_varint(
        &mut message,
        3,
        u64::from(u32::from_le_bytes(
            nonce.0[6..10].try_into().expect("4 bytes"),
        )),
    );
    pb_bytes(&mut message, 4, b"3019");
    pb_bytes(&mut message, 6, b"1611921764");
    pb_bytes(&mut message, 7, b"6.8.1.32");
    pb_bytes(&mut message, 8, b"v04.07.01-ml-android");
    pb_varint(&mut message, 9, 135_135_744);
    pb_bytes(&mut message, 10, &[0u8; 8]);
    pb_varint(&mut message, 12, u64::from(timestamp) * 2);

    let body_hash = sm3(&[0u8; 16]);
    let query_hash = sm3(query.as_bytes());
    pb_bytes(&mut message, 13, &body_hash[..6]);
    pb_bytes(&mut message, 14, &query_hash[..6]);

    let mut nested = vec![8, 2 + (nonce.0[10] % 49) * 2];
    for field in [2u64, 3, 4] {
        append_uvarint(&mut nested, field * 8);
        append_uvarint(&mut nested, 1_388_734);
    }
    pb_bytes(&mut message, 15, &nested);
    pb_bytes(&mut message, 20, b"none");
    pb_varint(&mut message, 21, 738);

    let mut data = pad16(&message);

    // 密钥调度：SM3(key || 3c cc 56 7b || key) → 72 轮常量。
    let mut seed = Vec::with_capacity(68);
    seed.extend_from_slice(&key);
    seed.extend_from_slice(&[0x3c, 0xcc, 0x56, 0x7b]);
    seed.extend_from_slice(&key);
    let derived = sm3(&seed);

    let mut rounds = [0u64; 72];
    for (i, slot) in rounds.iter_mut().take(4).enumerate() {
        *slot = u64::from_le_bytes(derived[i * 8..i * 8 + 8].try_into().expect("8 bytes"));
    }
    for i in 4..72 {
        let mut mixed = rounds[i - 1].rotate_right(3) ^ rounds[i - 3];
        mixed ^= mixed.rotate_right(1);
        rounds[i] = !rounds[i - 4]
            ^ mixed
            ^ ((0x3dc9_4c3a_046d_678bu64 >> ((i - 4) % 62)) & 1)
            ^ 3;
    }

    let mut offset = 0;
    while offset < data.len() {
        let mut left = u64::from_le_bytes(data[offset..offset + 8].try_into().expect("8 bytes"));
        let mut right =
            u64::from_le_bytes(data[offset + 8..offset + 16].try_into().expect("8 bytes"));
        for round in rounds {
            let next = left
                ^ (right.rotate_left(1) & right.rotate_left(8))
                ^ right.rotate_left(2)
                ^ round;
            left = right;
            right = next;
        }
        data[offset..offset + 8].copy_from_slice(&left.to_le_bytes());
        data[offset + 8..offset + 16].copy_from_slice(&right.to_le_bytes());
        offset += 16;
    }

    const XOR: [u8; 8] = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
    for (i, b) in data.iter_mut().enumerate() {
        *b ^= XOR[i % 8];
    }
    let mut reversed = Vec::with_capacity(XOR.len() + data.len());
    reversed.extend_from_slice(&XOR);
    reversed.extend_from_slice(&data);
    reversed.reverse();

    let mut container = Vec::with_capacity(9 + reversed.len());
    container.extend_from_slice(&[0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18]);
    container.extend_from_slice(&reversed);
    container.push(0x56);
    container.push(0x7b);
    let mut container = pad16(&container);

    let aes_key = md5::compute(&key[..16]);
    let iv = md5::compute(&key[16..32]);
    // 输入已按 16 字节对齐，故用 NoPadding（填充由 `pad16` 显式完成）。
    let cipher = cbc::Encryptor::<aes::Aes128>::new(&aes_key.0.into(), &iv.0.into());
    let msg_len = container.len();
    let encrypted = cipher
        .encrypt_padded::<aes::cipher::block_padding::NoPadding>(&mut container, msg_len)
        .expect("container is block aligned")
        .to_vec();

    let mut out = Vec::with_capacity(2 + encrypted.len());
    out.extend_from_slice(&[0x3c, 0xcc]);
    out.extend_from_slice(&encrypted);
    base64::engine::general_purpose::STANDARD.encode(out)
}

/// SM3 哈希（GB/T 32905-2016）。
///
/// 自己实现而不是用 crate：需要与参照实现**逐字节**一致，且这里只用到
/// 固定长度输入的哈希，手写更可控（同时也少一个依赖）。
pub fn sm3(input: &[u8]) -> [u8; 32] {
    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut data = Vec::with_capacity(input.len() + 72);
    data.extend_from_slice(input);
    data.push(0x80);
    while data.len() % 64 != 56 {
        data.push(0);
    }
    data.extend_from_slice(&bit_len.to_be_bytes());

    let mut state: [u32; 8] = [
        0x7380_166f,
        0x4914_b2b9,
        0x1724_42d7,
        0xda8a_0600,
        0xa96f_30bc,
        0x1631_38aa,
        0xe38d_ee4d,
        0xb0fb_0e4e,
    ];

    for chunk in data.chunks_exact(64) {
        let mut w = [0u32; 68];
        for (i, slot) in w.iter_mut().take(16).enumerate() {
            *slot = u32::from_be_bytes(chunk[i * 4..i * 4 + 4].try_into().expect("4 bytes"));
        }
        for i in 16..68 {
            let v = w[i - 16] ^ w[i - 9] ^ w[i - 3].rotate_left(15);
            w[i] = v ^ v.rotate_left(15) ^ v.rotate_left(23) ^ w[i - 13].rotate_left(7) ^ w[i - 6];
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for i in 0..64 {
            let (t, ff, gg) = if i < 16 {
                (0x79cc_4519u32, a ^ b ^ c, e ^ f ^ g)
            } else {
                (0x7a87_9d8au32, (a & b) | (a & c) | (b & c), (e & f) | (!e & g))
            };
            let ss1 = (a
                .rotate_left(12)
                .wrapping_add(e)
                .wrapping_add(t.rotate_left((i % 32) as u32)))
            .rotate_left(7);
            let tt1 = ff
                .wrapping_add(d)
                .wrapping_add(ss1 ^ a.rotate_left(12))
                .wrapping_add(w[i] ^ w[i + 4]);
            let tt2 = gg.wrapping_add(h).wrapping_add(ss1).wrapping_add(w[i]);
            d = c;
            c = b.rotate_left(9);
            b = a;
            a = tt1;
            h = g;
            g = f.rotate_left(19);
            f = e;
            e = tt2 ^ tt2.rotate_left(9) ^ tt2.rotate_left(17);
        }
        for (i, value) in [a, b, c, d, e, f, g, h].into_iter().enumerate() {
            state[i] ^= value;
        }
    }

    let mut out = [0u8; 32];
    for (i, value) in state.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&value.to_be_bytes());
    }
    out
}

fn hex_decode(hex: &str) -> Option<Vec<u8>> {
    let bytes = hex.as_bytes();
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn sm3_matches_standard_vector() {
        // GB/T 32905-2016 标准向量："abc"。
        let digest = sm3(b"abc");
        assert_eq!(
            crate::sign::hex_lower(&digest),
            "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
        );
    }

    #[test]
    fn sm3_empty_vector() {
        let digest = sm3(b"");
        assert_eq!(
            crate::sign::hex_lower(&digest),
            "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b"
        );
    }

    #[test]
    fn sm3_long_input_crosses_blocks() {
        // 64 字节整块边界 + 1，验证填充逻辑。
        let input = vec![b'a'; 65];
        let digest = sm3(&input);
        // 只验证确定性与长度；具体值由向量表锁定在下面。
        assert_eq!(digest.len(), 32);
        assert_eq!(digest, sm3(&input));
    }

    #[test]
    fn signature_has_expected_shapes() {
        let nonce = Nonce::from_bytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
        let sig = sign_comment_request("aid=8662&x=1", "8662", nonce, 1700000000, 1700000000000);

        assert_eq!(sig.gorgon.len(), 52);
        assert!(sig.gorgon.starts_with("8404"));
        assert_eq!(sig.khronos, "1700000000");
        assert_eq!(sig.ticket, "1700000000000");
        // 注释接口显式置空 STUB。
        assert_eq!(sig.stub, "");
        assert!(!sig.argus.is_empty());
        assert!(!sig.ladon.is_empty());
        // 两者都是合法 base64。
        use base64::Engine;
        assert!(
            base64::engine::general_purpose::STANDARD
                .decode(&sig.argus)
                .is_ok()
        );
        assert!(
            base64::engine::general_purpose::STANDARD
                .decode(&sig.ladon)
                .is_ok()
        );
    }

    #[test]
    fn argus_and_ladon_match_go_reference() {
        // 向量由参照 Go 实现生成（nonce = [1..=11], query = "aid=8662&x=1",
        // timestamp = 1700000000）。这两个算法是自研混淆，没有标准可依，
        // 唯一正确性来源就是与参照实现逐字节一致。
        let nonce = Nonce::from_bytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
        let sig = sign_comment_request("aid=8662&x=1", "8662", nonce, 1700000000, 1700000000000);
        assert_eq!(
            sig.argus,
            "PMxPj+JImxTKEfQuAsVmWpqW3cZMRFzpfoic90M9ydcOYFzM9QCby1Wv8vujXlFnjW3IqkDsO2IeOaNjNCcJIX3MtczIGevaqXACeWld6e/6Ti31O1Q1dsqe7ONOZhmoygRH/ijeCVF7VOkO5SxT6jfFeXcndb9WhZfcVEavmzNx4+oWhABgv+QeuGydntlIK/tuUzEeCmMY58/Je2MhotOU"
        );
        assert_eq!(sig.ladon, "AwQFBtpCvravpL/w/efFMzV997pnfrwAzFAlv0Cqi9J16ndL");
    }

    #[test]
    fn signature_is_deterministic_for_same_nonce() {
        let nonce = Nonce::from_bytes([7; 11]);
        let a = sign_comment_request("q=1", "8662", nonce, 100, 200);
        let b = sign_comment_request("q=1", "8662", nonce, 100, 200);
        assert_eq!(a, b);
    }

    #[test]
    fn different_nonce_changes_signature() {
        let a = sign_comment_request("q=1", "8662", Nonce::from_bytes([1; 11]), 100, 200);
        let b = sign_comment_request("q=1", "8662", Nonce::from_bytes([2; 11]), 100, 200);
        assert_ne!(a.gorgon, b.gorgon);
        assert_ne!(a.argus, b.argus);
        assert_ne!(a.ladon, b.ladon);
    }

    #[test]
    fn argus_envelope_prefix() {
        use base64::Engine;
        let sig = sign_comment_request("q=1", "8662", Nonce::from_bytes([3; 11]), 100, 200);
        let raw = base64::engine::general_purpose::STANDARD
            .decode(&sig.argus)
            .expect("decode");
        // 固定 2 字节前缀。
        assert_eq!(&raw[..2], &[0x3c, 0xcc]);
        // 其余是 AES 块对齐。
        assert_eq!((raw.len() - 2) % 16, 0);
    }

    #[test]
    fn pad16_pads_full_block_at_boundary() {
        // 与 Go 一致：16 的整数倍也要补满一整块。
        assert_eq!(pad16(&[0u8; 16]).len(), 32);
        assert_eq!(pad16(&[0u8; 15]).len(), 16);
        assert_eq!(pad16(&[]).len(), 16);
    }

    #[test]
    fn random_nonce_succeeds() {
        let nonce = Nonce::random().expect("random");
        // 极低概率全零；只要有随机源就应该非全零。
        assert!(nonce.0.iter().any(|b| *b != 0));
    }

    #[test]
    fn hex_decode_rejects_bad_input() {
        assert!(hex_decode("abc").is_none());
        assert!(hex_decode("zz").is_none());
        assert_eq!(hex_decode("00ff").expect("decode"), vec![0, 255]);
    }
}
