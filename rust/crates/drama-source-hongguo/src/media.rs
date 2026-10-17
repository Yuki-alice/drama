//! 取流：三级降级 + 媒体地址提取 + CENC 密钥解码。
//!
//! ## 三级降级
//!
//! 1. **App 签名接口** `video_model/v1`：全清晰度，但上游常返回空 body；
//! 2. **网页公开轨** `/video/public/{vid}/360p.mp4`：免签明文，覆盖试看集；
//! 3. **网页 SSR** `/player/{sid}/{vid}`：站点已改保护播放，保留兜底。
//!
//! 顺序是「画质优先」。但每条轨道有**冷却记忆**：刚失败过的轨道在冷却期内
//! 直接跳过，不再花时间证明它还是坏的——用户感知是「点了播放要转好几秒」。
//!
//! ## 密钥
//!
//! 上游把 AES-128 密钥藏在 `spade_a` 里：base64 → 标签/奇偶链解混淆 →
//! base-36 填充长度校验 → hex 解码。任何一步不对就报错，**绝不返回猜的密钥**
//! （错误的密钥解出乱码，比直接报错更糟）。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::Value;

use drama_types::ResolvedMedia;

/// 轨道失败记忆时长：冷却期内直接跳过该轨道。
pub const TRACK_COOLDOWN: Duration = Duration::from_secs(300);
/// 解析结果 TTL：同 `(vid, 清晰度)` 复用。
///
/// 取得**故意短**（3 分钟）：CDN 直链若带短期鉴权参数，宁可过期重签，
/// 也不让「缓存还热、链接已失效」的黑屏出现。
pub const RESOLVE_TTL: Duration = Duration::from_secs(180);
/// 缓存条目上限。
const CACHE_MAX: usize = 64;

/// 取流轨道。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Track {
    /// App 签名 `video_model/v1`（全清晰度）。
    App,
    /// 网页公开轨 `360p.mp4`（免签明文，只有试看集）。
    Public,
    /// 网页 SSR `video_player_info`（站点已改造，兜底）。
    Web,
}

/// 轨道基础顺序：画质优先。
const BASE_ORDER: [Track; 3] = [Track::App, Track::Public, Track::Web];

impl Track {
    pub fn as_str(self) -> &'static str {
        match self {
            Track::App => "app",
            Track::Public => "public",
            Track::Web => "web",
        }
    }
}

/// 轨道失败记忆。
static TRACK_FAILS: once_cell::sync::Lazy<Mutex<HashMap<Track, Instant>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(HashMap::new()));

/// 解析缓存（键 `vid:quality`）。
static RESOLVE_CACHE: once_cell::sync::Lazy<Mutex<HashMap<String, (ResolvedMedia, Instant)>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(HashMap::new()));

/// 最近一次成功解析（键 `vid`，保留全量 variants）。
///
/// 换档需要的只是「同一集的另一个候选地址」——它已经在上一轮解析结果里了。
/// 于是旁路这份按 vid 的最新全量结果，换档时零网络、零签名。
static LAST_BY_VID: once_cell::sync::Lazy<Mutex<HashMap<String, (ResolvedMedia, Instant)>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(HashMap::new()));

fn track_is_cooled(track: Track, now: Instant) -> bool {
    TRACK_FAILS
        .lock()
        .expect("track memory poisoned")
        .get(&track)
        .is_some_and(|at| now.duration_since(*at) < TRACK_COOLDOWN)
}

pub fn note_track_failure(track: Track) {
    TRACK_FAILS
        .lock()
        .expect("track memory poisoned")
        .insert(track, Instant::now());
}

pub fn note_track_success(track: Track) {
    TRACK_FAILS
        .lock()
        .expect("track memory poisoned")
        .remove(&track);
}

/// 本轮尝试顺序：未冷却的保持画质优先顺序在前，冷却的降到最后再试。
///
/// **只做降权不做提权**——成功过的低画质轨不会反超到第一行，
/// 否则预取了一次 360p 后，用户要 1080p 也会被钉死在 360p。
pub fn track_order() -> Vec<Track> {
    let now = Instant::now();
    let mut fresh: Vec<Track> = BASE_ORDER
        .iter()
        .copied()
        .filter(|t| !track_is_cooled(*t, now))
        .collect();
    let cooled: Vec<Track> = BASE_ORDER
        .iter()
        .copied()
        .filter(|t| track_is_cooled(*t, now))
        .collect();
    fresh.extend(cooled);
    fresh
}

/// 读缓存。
pub fn cache_get(video_id: &str, quality: i64) -> Option<ResolvedMedia> {
    let key = format!("{video_id}:{quality}");
    let guard = RESOLVE_CACHE.lock().expect("resolve cache poisoned");
    let (media, at) = guard.get(&key)?;
    if at.elapsed() >= RESOLVE_TTL {
        return None;
    }
    Some(media.clone())
}

/// 写缓存。
pub fn cache_put(video_id: &str, quality: i64, media: &ResolvedMedia) {
    let key = format!("{video_id}:{quality}");
    let mut guard = RESOLVE_CACHE.lock().expect("resolve cache poisoned");
    if guard.len() >= CACHE_MAX && !guard.contains_key(&key) {
        evict_oldest(&mut guard);
    }
    guard.insert(key, (media.clone(), Instant::now()));
    drop(guard);

    let mut last = LAST_BY_VID.lock().expect("last-by-vid poisoned");
    if last.len() >= CACHE_MAX && !last.contains_key(video_id) {
        evict_oldest(&mut last);
    }
    last.insert(video_id.to_owned(), (media.clone(), Instant::now()));
}

fn evict_oldest<T>(map: &mut HashMap<String, (T, Instant)>) {
    let mut keys: Vec<(Instant, String)> = map.iter().map(|(k, (_, at))| (*at, k.clone())).collect();
    keys.sort();
    for (_, k) in keys.into_iter().take(map.len() / 4 + 1) {
        map.remove(&k);
    }
}

/// 换档：**零网络、零签名**，只在上一次解析出的候选里按目标清晰度重挑。
///
/// 返回 `None` 表示缓存里没有这一集（从未取流过，或已过 TTL），
/// 调用方应回落到完整解析。
pub fn switch_quality(video_id: &str, preferred: i64) -> Option<ResolvedMedia> {
    let base = {
        let guard = LAST_BY_VID.lock().expect("last-by-vid poisoned");
        let (media, at) = guard.get(video_id)?;
        if at.elapsed() >= RESOLVE_TTL {
            return None;
        }
        media.clone()
    };
    let picked = ResolvedMedia::pick(&base.variants, preferred)?.clone();
    Some(base.with_variant(&picked))
}

/// 清空解析缓存（设置变更、切源后调用）。
pub fn clear_cache() {
    RESOLVE_CACHE
        .lock()
        .expect("resolve cache poisoned")
        .clear();
    LAST_BY_VID.lock().expect("last-by-vid poisoned").clear();
    TRACK_FAILS
        .lock()
        .expect("track memory poisoned")
        .clear();
}

// ── 密钥解码 ────────────────────────────────────────────────

/// 解码 `spade_a` 里的 AES-128 密钥。
///
/// 结构：
/// ```text
/// raw = base64(spade_a)
/// tag_len     = raw[0] ^ raw[1] ^ raw[2] - 48
/// content_len = len(raw) - tag_len - 1
/// seed        = raw[len-tag_len-2] ^ raw[len-tag_len-1]
/// tag         = raw[len-tag_len..] ^ seed        // 版本标签
/// decoded[i]  = (prev ^ raw[1+i]) - 21 - popcount(i)
/// padding     = base36(decoded[0])
/// key_hex     = decoded[1..33]
/// ```
///
/// `prev` 是**奇偶分离**的上一个字节：偶数位看偶数链，奇数位看奇数链，
/// 初值分别是 `250` 和 `85`。
pub fn decode_content_key(value: &str) -> Result<[u8; 16], String> {
    if value.len() > 1024 {
        return Err("红果媒体密钥数据过长".to_owned());
    }
    let raw = decode_base64(value).ok_or_else(|| "红果媒体密钥编码无效".to_owned())?;
    if raw.len() < 3 {
        return Err("红果媒体密钥编码无效".to_owned());
    }

    let tag_length = (i32::from(raw[0]) ^ i32::from(raw[1]) ^ i32::from(raw[2])) - 48;
    if tag_length < 1 {
        return Err("红果媒体密钥结构无效".to_owned());
    }
    let tag_length = tag_length as usize;
    if raw.len() <= tag_length + 1 {
        return Err("红果媒体密钥结构无效".to_owned());
    }
    let content_length = raw.len() - tag_length - 1;
    if content_length < 33 || content_length >= raw.len() {
        return Err("红果媒体密钥结构无效".to_owned());
    }

    let seed = raw[raw.len() - tag_length - 2] ^ raw[raw.len() - tag_length - 1];
    let tag: Vec<u8> = raw[raw.len() - tag_length..]
        .iter()
        .map(|b| b ^ seed)
        .collect();
    if tag == b"app_v2" || tag == b"web_v2" {
        return Err("红果媒体密钥版本暂不支持".to_owned());
    }

    // 奇偶分离的差分链：偶数位看偶数链，奇数位看奇数链，初值 250 / 85。
    // 每一位用**更新前**的链值参与运算，再把当前字节写回对应链。
    let mut decoded = vec![0u8; content_length];
    let mut even = 250u8;
    let mut odd = 85u8;
    for (index, current) in raw[1..1 + content_length].iter().enumerate() {
        let previous = if index % 2 == 0 {
            let prev = even;
            even = *current;
            prev
        } else {
            let prev = odd;
            odd = *current;
            prev
        };
        let popcount = index.count_ones() as i32;
        let value = i32::from(previous ^ current) - 21 - popcount;
        decoded[index] = (value & 0xff) as u8;
    }

    let padding_char = decoded[0] as char;
    let padding = padding_char
        .to_digit(36)
        .ok_or_else(|| "红果媒体密钥内容无效".to_owned())? as usize;
    if content_length.checked_sub(padding + 1) != Some(32) {
        return Err("红果媒体密钥内容无效".to_owned());
    }

    let hex_str = std::str::from_utf8(&decoded[1..33])
        .map_err(|_| "红果媒体密钥不是有效的 AES-128 密钥".to_owned())?;
    let key = hex_decode(hex_str).ok_or_else(|| "红果媒体密钥不是有效的 AES-128 密钥".to_owned())?;
    if key.len() != 16 {
        return Err("红果媒体密钥不是有效的 AES-128 密钥".to_owned());
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&key);
    Ok(out)
}

/// base64 解码：先标准（严格），再标准（宽松），最后 URL-safe。
fn decode_base64(value: &str) -> Option<Vec<u8>> {
    let engine = base64::engine::general_purpose::STANDARD;
    if let Ok(bytes) = engine.decode(value) {
        return Some(bytes);
    }
    if let Ok(bytes) = base64::engine::general_purpose::STANDARD_NO_PAD.decode(value) {
        return Some(bytes);
    }
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .ok()
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

// ── 媒体地址 ────────────────────────────────────────────────

/// 从 `video_meta`/`video_player_info` 提取可播地址。
///
/// 按固定顺序取字段，值可以是字符串或（递归的）数组；不是 http(s) 的
/// 会先尝试 base64 解码一次（上游有时会把地址编码）。
pub fn media_addresses(info: &Value) -> Vec<String> {
    let mut addresses = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for key in [
        "main_url",
        "backup_url",
        "backup_url_1",
        "backup_url_2",
        "backup_urls",
        "url_list",
    ] {
        if let Some(value) = info.get(key) {
            collect_addresses(value, &mut addresses, &mut seen);
        }
    }
    addresses
}

fn collect_addresses(
    value: &Value,
    out: &mut Vec<String>,
    seen: &mut std::collections::HashSet<String>,
) {
    match value {
        Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.len() > 8192 {
                return;
            }
            let mut address = trimmed.to_owned();
            if !is_http_url(&address) {
                let Some(decoded) = decode_base64(address.trim()) else {
                    return;
                };
                address = String::from_utf8_lossy(&decoded).trim().to_owned();
            }
            if is_http_url(&address) && seen.insert(address.clone()) {
                out.push(address);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_addresses(item, out, seen);
            }
        }
        _ => {}
    }
}

/// 是否是合法的 http(s) 媒体地址（有 scheme、有 host、无 userinfo）。
pub fn is_http_url(raw: &str) -> bool {
    let Ok(parsed) = url::Url::parse(raw) else {
        return false;
    };
    if !matches!(parsed.scheme(), "http" | "https") {
        return false;
    }
    if parsed.host_str().is_none_or(str::is_empty) {
        return false;
    }
    // 带 userinfo 的地址通常是钓鱼/错误数据。
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return false;
    }
    true
}

/// 从 `video_meta.definition`/`vheight`/`vwidth` 推导清晰度（画面高度）。
pub fn quality_of(meta: &Value) -> i64 {
    // 先看 definition（"720p"/"1080P"），取第一段数字。
    if let Some(definition) = meta.get("definition").and_then(Value::as_str) {
        let digits: String = definition.chars().take_while(char::is_ascii_digit).collect();
        if let Ok(value) = digits.parse::<i64>()
            && value > 0
        {
            return value;
        }
    }
    let height = meta
        .get("vheight")
        .and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok()))
        .unwrap_or(0);
    if height > 0 {
        return height;
    }
    let width = meta
        .get("vwidth")
        .and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok()))
        .unwrap_or(0);
    width.max(0)
}

/// 编码判断：`bytevc2` 是 H.266，播放器普遍不支持，必须跳过。
pub fn is_unsupported_codec(meta: &Value, variant: &Value) -> bool {
    let codec = meta
        .get("codec_type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    if codec == "bytevc2" {
        return true;
    }
    variant
        .get("gear_des_key")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase()
        .contains("bytevc2")
}

/// 评分：高度为主，H.264 在同高度下优先。
pub fn score_of(height: i64, meta: &Value) -> i64 {
    let codec = meta
        .get("codec_type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    let bonus = if codec == "h264" || codec == "avc1" {
        1
    } else {
        0
    };
    height * 10 + bonus
}

/// 是否加密（任一信号成立）。
pub fn is_encrypted(encrypt_info: &Value) -> bool {
    let spade = encrypt_info
        .get("spade_a")
        .and_then(Value::as_str)
        .unwrap_or("");
    if !spade.is_empty() {
        return true;
    }
    if encrypt_info.get("encrypt").and_then(Value::as_bool) == Some(true) {
        return true;
    }
    encrypt_info
        .get("encryption_method")
        .and_then(Value::as_str)
        .is_some_and(|m| m == "cenc-aes-ctr")
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use drama_types::Variant;
    use serde_json::json;

    #[test]
    fn http_url_validation() {
        assert!(is_http_url("https://cdn/x.mp4"));
        assert!(is_http_url("http://1.2.3.4/a"));
        assert!(!is_http_url("ftp://x/y"));
        assert!(!is_http_url("not a url"));
        assert!(!is_http_url("https://user:pass@cdn/x"));
        assert!(!is_http_url(""));
    }

    #[test]
    fn media_addresses_in_order_and_deduped() {
        let info = json!({
            "main_url": "https://cdn/main.mp4",
            "backup_url": "https://cdn/main.mp4",
            "backup_url_1": ["https://cdn/b1.mp4", "https://cdn/b2.mp4"],
            "url_list": ["https://cdn/b1.mp4", "https://cdn/l.mp4"]
        });
        let addresses = media_addresses(&info);
        assert_eq!(
            addresses,
            vec![
                "https://cdn/main.mp4",
                "https://cdn/b1.mp4",
                "https://cdn/b2.mp4",
                "https://cdn/l.mp4"
            ]
        );
    }

    #[test]
    fn media_addresses_decodes_base64() {
        let raw = "https://cdn/encoded.mp4";
        let encoded = base64::engine::general_purpose::STANDARD.encode(raw);
        let info = json!({ "main_url": encoded });
        assert_eq!(media_addresses(&info), vec![raw]);
    }

    #[test]
    fn media_addresses_skips_garbage() {
        let info = json!({
            "main_url": 42,
            "backup_url": "",
            "backup_url_1": "not a url and not base64!!!",
            "url_list": ["ftp://x/y"]
        });
        assert!(media_addresses(&info).is_empty());
    }

    #[test]
    fn quality_from_definition_first() {
        assert_eq!(quality_of(&json!({"definition": "720p", "vheight": 480})), 720);
        assert_eq!(quality_of(&json!({"definition": "1080P"})), 1080);
        assert_eq!(quality_of(&json!({"vheight": 540})), 540);
        assert_eq!(quality_of(&json!({"vwidth": 640})), 640);
        assert_eq!(quality_of(&json!({})), 0);
    }

    #[test]
    fn bytevc2_is_rejected() {
        assert!(is_unsupported_codec(
            &json!({"codec_type": "bytevc2"}),
            &json!({})
        ));
        assert!(is_unsupported_codec(
            &json!({}),
            &json!({"gear_des_key": "xxx_bytevc2_yyy"})
        ));
        assert!(!is_unsupported_codec(
            &json!({"codec_type": "h264"}),
            &json!({})
        ));
    }

    #[test]
    fn h264_wins_at_equal_height() {
        let h264 = score_of(720, &json!({"codec_type": "h264"}));
        let hevc = score_of(720, &json!({"codec_type": "hevc"}));
        assert!(h264 > hevc);
        // 但更高分辨率永远更优。
        assert!(score_of(1080, &json!({"codec_type": "hevc"})) > h264);
    }

    #[test]
    fn encryption_signals() {
        assert!(is_encrypted(&json!({"spade_a": "abc"})));
        assert!(is_encrypted(&json!({"encrypt": true})));
        assert!(is_encrypted(&json!({"encryption_method": "cenc-aes-ctr"})));
        assert!(!is_encrypted(&json!({"encrypt": false})));
        assert!(!is_encrypted(&json!({})));
    }

    #[test]
    fn track_order_puts_cooled_last() {
        clear_cache();
        let order = track_order();
        assert_eq!(order[0], Track::App);

        note_track_failure(Track::App);
        let order = track_order();
        // 失败的轨道降权，但**仍在列表里**（只是最后再试）。
        assert_eq!(order[0], Track::Public);
        assert_eq!(order[2], Track::App);

        note_track_success(Track::App);
        assert_eq!(track_order()[0], Track::App);
        clear_cache();
    }

    #[test]
    fn switch_quality_reuses_last_resolution() {
        clear_cache();
        let media = ResolvedMedia {
            url: "https://cdn/360.mp4".to_owned(),
            referer: crate::PLAYER_REFERER.to_owned(),
            duration_secs: 60.0,
            quality: 360,
            encrypted: false,
            key_hex: String::new(),
            variants: vec![
                Variant {
                    url: "https://cdn/360.mp4".to_owned(),
                    quality: 360,
                    encrypted: false,
                },
                Variant {
                    url: "https://cdn/1080.mp4".to_owned(),
                    quality: 1080,
                    encrypted: false,
                },
            ],
            danmaku_vid: "1".to_owned(),
        };
        cache_put("vid1", 360, &media);

        let switched = switch_quality("vid1", 1080).expect("switch");
        assert_eq!(switched.url, "https://cdn/1080.mp4");
        assert_eq!(switched.quality, 1080);
        // 未知 vid → None（调用方回落到完整解析）。
        assert!(switch_quality("unknown", 1080).is_none());
        clear_cache();
    }

    #[test]
    fn cache_hit_returns_same_media() {
        clear_cache();
        let media = ResolvedMedia {
            url: "u".to_owned(),
            referer: String::new(),
            duration_secs: 0.0,
            quality: 720,
            encrypted: false,
            key_hex: String::new(),
            variants: Vec::new(),
            danmaku_vid: String::new(),
        };
        cache_put("v", 720, &media);
        assert_eq!(cache_get("v", 720).expect("hit").url, "u");
        // 不同清晰度是不同 key。
        assert!(cache_get("v", 1080).is_none());
        clear_cache();
    }

    #[test]
    fn content_key_matches_go_reference() {
        // 向量由参照 Go 实现的 hongguoContentKey 生成并回读验证：
        // 载荷结构为 [tag_len 编码][奇偶链内容 34 字节][tag "zz1"]。
        // 这是自研混淆，唯一正确性来源就是与参照实现一致。
        let spade = "nLwT+lu9EvRZvRL2X7oR9EG5DvZfpibfXaYm3VuhJd+lo9QNDUY=";
        let key = decode_content_key(spade).expect("decode");
        assert_eq!(
            key.iter().map(|b| format!("{b:02x}")).collect::<String>(),
            "00112233445566778899aabbccddeeff"
        );
    }

    #[test]
    fn content_key_rejects_garbage() {
        assert!(decode_content_key("").is_err());
        assert!(decode_content_key("!!!notbase64!!!").is_err());
        // 超长直接拒绝（防内存放大）。
        assert!(decode_content_key(&"A".repeat(2000)).is_err());
    }

    #[test]
    fn decode_base64_variants() {
        assert_eq!(decode_base64("aGk=").expect("std"), b"hi".to_vec());
        assert_eq!(decode_base64("aGk").expect("nopad"), b"hi".to_vec());
        assert!(decode_base64("!!!").is_none());
    }
}
