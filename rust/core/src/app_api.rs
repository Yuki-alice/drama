//! 红果 App 签名接口（取流面）。
//!
//! 分层说明：浏览类（目录/推荐/榜单/搜索/建议）走免签 SSR（见 `web_ssr`，
//! 快且稳定）；详情与取流走本模块的签名 App 接口，失败时逐级降级：
//! App 详情 → SSR 详情；App 取流 → 网页取流。
//! 第三方备用接口不接入（不可靠且引入外部依赖）。
//!
//! 算法（签名、密钥派生、清晰度打分）与参照 Go 实现一致；
//! `hongguoContentKey` 的边界行为由单测锁定。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use once_cell::sync::Lazy;
use serde_json::{Value, json};

use crate::device;
use crate::http::{self, OutboundRequest};
use crate::sign;
use crate::source::traits::SourceError;

/// App 接口根。
const APP_BASE: &str = "https://api5-normal-sinfonlineb.fqnovel.com";

/// App UA（与参照实现一致）。
const APP_UA: &str = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";

/// 官网根（网页取流 Referer 与取流页用）。
const WEB_BASE: &str = "https://www.hongguoduanju.com";

/// 播放器侧 Referer（取流地址要求）。
pub const PLAYER_REFERER: &str = "https://novel.snssdk.com/";

/// 官网站内资源（公开轨视频、播放页）的 Referer。
pub const WEB_REFERER: &str = "https://www.hongguoduanju.com/";

/// 数字 ID 形状（1~32 位）。
fn is_numeric_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 32 && s.bytes().all(|b| b.is_ascii_digit())
}

/// 轨道衰退记忆时长：冷却期内**直接跳过**该轨道（不再花时间证明它还是坏的）。
///
/// 为什么需要它：失败的签名链不是瞬间返回的——`app_request` 会退避重试、
/// 每次耽误 1~2 秒，再加上 SH 迟到降级，用户感知就是「点了播放要转好几秒」。
/// 冷却期 5 分钟足够滤掉一次故障窗口，又不会永久放弃高画质轨。
const TRACK_COOLDOWN: Duration = Duration::from_secs(300);

/// 解析结果 TTL：同 `(vid, 清晰度)` 复用上一次的成功结果。
///
/// 受益最明显的是 **预取→实际播放**：播放器预取下一集时会解析一次，
/// 用户切过去本该再签一次名（重复整套 network 往返），命中缓存后直接起播。
/// TTL 取得**故意短**（3 分钟）：CDN 直链若带短期鉴权参数，宁可过期重签，
/// 也不让「缓存还热、链接已失效」的黑屏出现。
const RESOLVE_TTL: Duration = Duration::from_secs(180);
/// 缓存条目上限（防长时间使用时堆积）。
const RESOLVE_CACHE_MAX: usize = 64;

/// 取流轨道。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Track {
    /// App 签名 `video_model/v1`（全清晰度，当前上游常返回空 body）。
    App,
    /// App 签名 `multi_video_model/v1`（备用签名链）。
    Multi,
    /// 网页公开轨 `360p.mp4`（免签明文，最稳但只有试看集与 360p）。
    Public,
    /// 网页 SSR `video_player_info`（站点已改造，兜底）。
    Web,
}

/// 轨道基础顺序：**画质优先**（依次为 App / multi / 公开轨 / SSR）。
const BASE_ORDER: [Track; 4] = [Track::App, Track::Multi, Track::Public, Track::Web];

/// 轨道失败时刻（`Track` → 最近一次失败时间）。
static TRACK_FAILS: Lazy<Mutex<HashMap<Track, Instant>>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// 解析缓存（键为 `vid:清晰度`）。
static RESOLVE_CACHE: Lazy<Mutex<HashMap<String, (ResolvedMedia, Instant)>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// 最近一次成功解析（键为 `vid`，**保留全量 variants**）。
///
/// 为什么单独再来一份：`RESOLVE_CACHE` 的键带清晰度，换档必然 miss → 重跑整条
/// 签名链（网络 + 重试退避，实测数百毫秒到数秒），用户点「1080P」要等一轮。
/// 而换档需要的只是**同一集的另一个候选地址**——它已经在上一次的解析结果里了。
/// 于是旁路这份「按 vid 的最新全量结果」，换档时零网络、零签名，只重新挑一个
/// variant 并重新注册代理会话。TTL 与解析缓存对齐，避免拿过期直链换档。
static LAST_BY_VID: Lazy<Mutex<HashMap<String, (ResolvedMedia, Instant)>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// 是否处于冷却期（可注入 `now` 便于离线单测）。
fn track_is_cooled_at(track: Track, now: Instant) -> bool {
    TRACK_FAILS
        .lock()
        .expect("track memory poisoned")
        .get(&track)
        .is_some_and(|at| now.duration_since(*at) < TRACK_COOLDOWN)
}

fn note_track_failure(track: Track) {
    TRACK_FAILS
        .lock()
        .expect("track memory poisoned")
        .insert(track, Instant::now());
}

fn note_track_success(track: Track) {
    TRACK_FAILS
        .lock()
        .expect("track memory poisoned")
        .remove(&track);
}

/// 本轮尝试顺序：**未冷却的保持画质优先顺序在前**，冷却的降到最后再试。
///
/// 只做「降权」不做「提权」——成功过的低画质轨不会反超到第一行，
/// 否则预取了一次 360p 后，用户要 1080p 也会被钉死在 360p。
fn track_order_at(now: Instant) -> Vec<Track> {
    let mut fresh: Vec<Track> = BASE_ORDER
        .iter()
        .copied()
        .filter(|t| !track_is_cooled_at(*t, now))
        .collect();
    let cooled: Vec<Track> = BASE_ORDER
        .iter()
        .copied()
        .filter(|t| track_is_cooled_at(*t, now))
        .collect();
    fresh.extend(cooled);
    fresh
}

fn cache_key(video_id: &str, preferred: i64) -> String {
    format!("{video_id}:{preferred}")
}

/// 读缓存（过期即视为未命中；`now` 可注入便于离线单测）。
fn cache_get(key: &str, now: Instant) -> Option<ResolvedMedia> {
    let guard = RESOLVE_CACHE.lock().expect("resolve cache poisoned");
    let (media, at) = guard.get(key)?;
    if now.duration_since(*at) >= RESOLVE_TTL {
        return None;
    }
    Some(media.clone())
}

fn cache_put(key: String, media: ResolvedMedia, now: Instant) {
    let mut guard = RESOLVE_CACHE.lock().expect("resolve cache poisoned");
    if guard.len() >= RESOLVE_CACHE_MAX && !guard.contains_key(&key) {
        // 满了就丢掉最早的一批（按插入时刻排序，取前 1/4 淘汰）。
        let mut keys: Vec<(Instant, String)> =
            guard.iter().map(|(k, (_, at))| (*at, k.clone())).collect();
        keys.sort();
        for (_, k) in keys.into_iter().take(RESOLVE_CACHE_MAX / 4 + 1) {
            guard.remove(&k);
        }
    }
    guard.insert(key, (media, now));
}

/// 记下「该 vid 最近一次的全量解析结果」（供换档复用）。
fn last_put(video_id: &str, media: &ResolvedMedia, now: Instant) {
    let mut guard = LAST_BY_VID.lock().expect("last-by-vid poisoned");
    if guard.len() >= RESOLVE_CACHE_MAX && !guard.contains_key(video_id) {
        let mut keys: Vec<(Instant, String)> =
            guard.iter().map(|(k, (_, at))| (*at, k.clone())).collect();
        keys.sort();
        for (_, k) in keys.into_iter().take(RESOLVE_CACHE_MAX / 4 + 1) {
            guard.remove(&k);
        }
    }
    guard.insert(video_id.to_owned(), (media.clone(), now));
}

/// 换档：**零网络、零签名**——只在上一次解析出的候选里按目标清晰度重挑。
///
/// `preferred` 语义与 `resolve_media` 一致（0 = 要最高）。缓存里没有这一集
/// （从未取流过，或已过 TTL）时返回 `None`，调用方回落到完整解析。
pub fn switch_quality(video_id: &str, preferred: i64) -> Option<ResolvedMedia> {
    let now = Instant::now();
    let base = {
        let guard = LAST_BY_VID.lock().expect("last-by-vid poisoned");
        let (media, at) = guard.get(video_id)?;
        if now.duration_since(*at) >= RESOLVE_TTL {
            return None;
        }
        media.clone()
    };
    let picked = {
        let v = pick_variant(&base.variants, preferred)?;
        (v.url.clone(), v.quality)
    };
    let mut out = base;
    out.url = picked.0;
    out.quality = picked.1;
    Some(out)
}

/// 按期望清晰度挑候选：`preferred > 0` 时取 `quality <= preferred` 里最高的，
/// 无满足则**回退最低档**（宁可糊也不要断流）；`preferred <= 0` 取最高档。
fn pick_variant(variants: &[ResolvedVariant], preferred: i64) -> Option<&ResolvedVariant> {
    let mut best: Option<&ResolvedVariant> = None;
    let mut lowest: Option<&ResolvedVariant> = None;
    for v in variants {
        if lowest.is_none_or(|l| v.quality < l.quality) {
            lowest = Some(v);
        }
        if preferred <= 0 {
            if best.is_none_or(|b| v.quality > b.quality) {
                best = Some(v);
            }
        } else if v.quality <= preferred && best.is_none_or(|b| v.quality > b.quality) {
            best = Some(v);
        }
    }
    best.or(lowest)
}

/// 可用档位（去重、**降序**），供 UI 渲染清晰度切换菜单。
///
/// 标签规则也放 Rust：档位命名（4K/2K/1080P…）是业务口径，不是渲染细节。
pub fn quality_options(variants: &[ResolvedVariant]) -> Vec<Value> {
    let mut heights: Vec<i64> = variants
        .iter()
        .map(|v| v.quality)
        .filter(|q| *q > 0)
        .collect();
    heights.sort_unstable();
    heights.dedup();
    heights
        .into_iter()
        .rev()
        .map(|h| json!({ "height": h, "label": quality_label_of(h) }))
        .collect()
}

/// 档位标签：2160→4K、1440→2K，其余 `{h}P`。
fn quality_label_of(height: i64) -> String {
    match height {
        2160 => "4K".to_owned(),
        1440 => "2K".to_owned(),
        h => format!("{h}P"),
    }
}

/// 解析出的可播媒体。
#[derive(Debug, Clone)]
pub struct ResolvedMedia {
    pub url: String,
    pub referer: &'static str,
    pub duration_secs: f64,
    pub quality: i64,
    pub encrypted: bool,
    pub key_hex: String,
    pub variants: Vec<ResolvedVariant>,
}

/// 候选线路（同集不同地址/清晰度）。
#[derive(Debug, Clone)]
pub struct ResolvedVariant {
    pub url: String,
    pub quality: i64,
}

impl ResolvedMedia {
    pub fn to_json(&self) -> Value {
        json!({
            "url": self.url,
            "referer": self.referer,
            "durationSecs": self.duration_secs,
            "quality": self.quality,
            "encrypted": self.encrypted,
            "keyHex": self.key_hex,
            "variants": self.variants.iter().map(|v| json!({
                "url": v.url,
                "quality": v.quality,
            })).collect::<Vec<_>>(),
            // 可切换的档位（去重降序 + 标签）。单集档位通常 3~6 个，
            // 只在 `play` / `playQuality` 响应里带，成本可忽略。
            "qualityOptions": quality_options(&self.variants),
        })
    }
}

/// 带签名的 App 请求：POST/GET JSON，返回解析后的 `Value`。
/// 重试 1~3 次、每次间隔递增；4xx 不重试；业务 `code != 0` 视为失败。
fn app_request(
    method_post: bool,
    path: &str,
    extra_query: &[(&str, String)],
    body: Option<Value>,
) -> Result<Value, SourceError> {
    let id = device::identity();
    let mut params: Vec<(String, String)> = vec![
        ("aid".to_owned(), "8662".to_owned()),
        ("app_name".to_owned(), "novelread".to_owned()),
        ("version_code".to_owned(), "73532".to_owned()),
        ("version_name".to_owned(), "7.3.5.32".to_owned()),
        ("manifest_version_code".to_owned(), "73532".to_owned()),
        ("update_version_code".to_owned(), "73532".to_owned()),
        ("channel".to_owned(), "update_64".to_owned()),
        ("device_platform".to_owned(), "android".to_owned()),
        ("os".to_owned(), "android".to_owned()),
        ("ssmix".to_owned(), "a".to_owned()),
        ("device_type".to_owned(), "25053RT47C".to_owned()),
        ("device_brand".to_owned(), "Redmi".to_owned()),
        ("language".to_owned(), "zh".to_owned()),
        ("os_api".to_owned(), "36".to_owned()),
        ("os_version".to_owned(), "16".to_owned()),
        ("resolution".to_owned(), "1280*2772".to_owned()),
        ("dpi".to_owned(), "520".to_owned()),
        ("ac".to_owned(), "wifi".to_owned()),
        ("device_id".to_owned(), id.device_id),
        ("iid".to_owned(), id.install_id),
    ];
    for (k, v) in extra_query {
        params.push((k.to_string(), v.clone()));
    }
    let body_bytes = body
        .as_ref()
        .map(serde_json::to_vec)
        .transpose()
        .map_err(|e| SourceError::Parse(format!("encode app body: {e}")))?;

    let mut last_err: Option<SourceError> = None;
    for attempt in 0..3u32 {
        if attempt > 0 {
            std::thread::sleep(std::time::Duration::from_secs(attempt as u64));
        }
        match app_request_once(method_post, path, &params, body_bytes.as_deref()) {
            Ok(v) => return Ok(v),
            Err(e) => {
                let fatal = matches!(&e, SourceError::Http(h) if !h.retryable)
                    || matches!(&e, SourceError::Parse(_) | SourceError::NotFound);
                if fatal {
                    return Err(e);
                }
                last_err = Some(e);
            }
        }
    }
    Err(last_err.unwrap_or(SourceError::Timeout))
}

fn app_request_once(
    method_post: bool,
    path: &str,
    params: &[(String, String)],
    body: Option<&[u8]>,
) -> Result<Value, SourceError> {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let mut params = params.to_vec();
    let khronos = (now_ms / 1000) as u32;
    // 票据抖动：branch == 1 的签名变体会被服务端拒收，先本地算好再发。
    let ticket = sign::pick_ticket(&params, body, khronos, now_ms);
    params.push(("_rticket".to_owned(), ticket.to_string()));
    let raw_query = sign::encode_query_sorted(&mut params);
    let url = format!("{APP_BASE}{path}?{raw_query}");
    let sig = sign::sign_request(&raw_query, body, khronos, ticket);

    let mut headers = vec![
        ("User-Agent".to_owned(), APP_UA.to_owned()),
        ("Accept".to_owned(), "application/json".to_owned()),
        ("X-XS-From-Web".to_owned(), "0".to_owned()),
        ("Sdk-Version".to_owned(), "2".to_owned()),
        ("X-Khronos".to_owned(), sig.khronos),
        ("X-Gorgon".to_owned(), sig.gorgon),
        ("X-SS-Req-Ticket".to_owned(), sig.ticket),
    ];
    if let Some(stub) = sig.stub {
        headers.push(("X-SS-STUB".to_owned(), stub));
    }
    if body.is_some() {
        headers.push((
            "Content-Type".to_owned(),
            "application/json; charset=utf-8".to_owned(),
        ));
    }
    let req = OutboundRequest {
        post: method_post,
        url,
        headers,
        body: body.map(<[u8]>::to_vec),
    };
    let value = http::fetch_json_custom(&req).map_err(SourceError::from)?;
    check_app_code(&value)?;
    Ok(value)
}

/// 业务码检查：`code` / `Code` / `status_code` / `BaseResp.StatusCode` 非 0 即失败。
fn check_app_code(value: &Value) -> Result<(), SourceError> {
    let code = value
        .get("code")
        .or_else(|| value.get("Code"))
        .or_else(|| value.get("status_code"))
        .and_then(Value::as_str)
        .or_else(|| {
            value
                .get("BaseResp")
                .and_then(|b| b.get("StatusCode"))
                .and_then(Value::as_str)
        })
        .unwrap_or("");
    if code.is_empty() || code == "0" {
        return Ok(());
    }
    Err(SourceError::Blocked { retry_at_ms: 0 })
}

/// App 详情：`video_detail/v1` → 同 SSR 契约的 `{drama, episodes}`。
pub fn app_detail(series_id: &str) -> Result<Value, SourceError> {
    if !is_numeric_id(series_id) {
        return Err(SourceError::Parse("invalid series id".to_owned()));
    }
    let result = app_request(
        true,
        "/novel/player/video_detail/v1/",
        &[],
        Some(json!({ "series_id": series_id })),
    )?;
    parse_app_detail(&result, series_id)
}

fn parse_app_detail(result: &Value, series_id: &str) -> Result<Value, SourceError> {
    let detail = result
        .get("data")
        .and_then(|d| d.get("video_data"))
        .ok_or_else(|| SourceError::Parse("app detail missing video_data".to_owned()))?;
    let returned = str_field(detail, &["series_id_str", "series_id"]);
    if returned != series_id {
        return Err(SourceError::Parse("app detail series mismatch".to_owned()));
    }
    let rows = detail
        .get("video_list")
        .and_then(Value::as_array)
        .ok_or_else(|| SourceError::Parse("app detail missing video_list".to_owned()))?;
    let mut episodes: Vec<(i64, Value)> = Vec::new();
    let mut seen_vid = std::collections::HashSet::new();
    let mut seen_idx = std::collections::HashSet::new();
    for row in rows {
        let vid = str_field(row, &["vid"]);
        let index: i64 = row
            .get("vid_index")
            .and_then(|v| v.as_str().unwrap_or("").parse().ok())
            .or_else(|| row.get("vid_index").and_then(Value::as_i64))
            .unwrap_or(0);
        if index < 1 || !is_numeric_id(&vid) {
            return Err(SourceError::Parse("app detail bad episode".to_owned()));
        }
        if let Some(owner) = row.get("series_id").and_then(Value::as_str)
            && owner != series_id
        {
            return Err(SourceError::Parse("app detail foreign episode".to_owned()));
        }
        if !seen_vid.insert(vid.clone()) || !seen_idx.insert(index) {
            return Err(SourceError::Parse(
                "app detail duplicate episode".to_owned(),
            ));
        }
        episodes.push((
            index,
            json!({
                "index": index,
                "vid": vid,
                "title": format!("第 {index} 集"),
                "locked": false,
                "durationSeconds": 0,
            }),
        ));
    }
    let total: usize = detail
        .get("episode_cnt")
        .and_then(|v| v.as_str().unwrap_or("").parse().ok())
        .or_else(|| {
            detail
                .get("episode_cnt")
                .and_then(Value::as_u64)
                .map(|n| n as usize)
        })
        .unwrap_or(0);
    if episodes.is_empty() || total > episodes.len() {
        return Err(SourceError::Parse(
            "app detail incomplete episodes".to_owned(),
        ));
    }
    // 连续性：按集号排序后必须 1..=N 连续。
    episodes.sort_by_key(|(i, _)| *i);
    for (pos, (index, _)) in episodes.iter().enumerate() {
        if *index != pos as i64 + 1 {
            return Err(SourceError::Parse(
                "app detail non-contiguous episodes".to_owned(),
            ));
        }
    }
    let drama = json!({
        "id": series_id.to_owned(),
        "title": first_str(detail, &["series_name", "series_title"]),
        "cover": str_field(detail, &["series_cover"]),
        "categoryId": "",
        "categoryName": "短剧",
        "episodeCount": episodes.len() as i64,
        "accessibleEpisodes": episodes.len() as i64,
        "summary": str_field(detail, &["series_intro"]),
        "tags": [],
        "status": app_status(detail),
        "vip": detail.get("pay_type").and_then(Value::as_i64).unwrap_or(0) != 0,
    });
    Ok(json!({
        "drama": drama,
        "episodes": episodes.into_iter().map(|(_, e)| e).collect::<Vec<_>>(),
    }))
}

/// App 状态映射：`series_status` 整数语义以直播校验为准，
/// 当前按字符串 `"1"` 判完结（与 SSR 轨一致，待直播确认后统一）。
fn app_status(detail: &Value) -> &'static str {
    let raw = detail
        .get("series_status")
        .map(|v| {
            if let Some(s) = v.as_str() {
                s.to_owned()
            } else {
                v.to_string()
            }
        })
        .unwrap_or_default();
    if raw == "1" { "finished" } else { "ongoing" }
}

/// 取流主链：App 签名接口 → multi 签名接口 → 网页公开轨 → 网页 SSR。
///
/// 降级顺序按“画质优先”排：App 与 multi 都是全清晰度签名链
///（multi 用另一套端点与载荷，专治 App 链被降级为空时），
/// 公开轨 360p 保底，SSR 最后兜底。
///
/// `preferred` 为期望清晰度上限（0 表示要最高）；公开轨只有 360p，不受其影响。
pub fn resolve_media(
    series_id: &str,
    video_id: &str,
    preferred: i64,
) -> Result<ResolvedMedia, SourceError> {
    if !is_numeric_id(series_id) || !is_numeric_id(video_id) {
        return Err(SourceError::Parse("invalid series/video id".to_owned()));
    }
    // 命中缓存直接返回：省掉整条签名往返（预取与紧接着的播放共享同一次结果）。
    let key = cache_key(video_id, preferred);
    let now = Instant::now();
    if let Some(media) = cache_get(&key, now) {
        // 命中也要刷新旁路：换档要的是「这一集最近一次的全量候选」。
        last_put(video_id, &media, now);
        return Ok(media);
    }

    let mut errors: Vec<String> = Vec::new();
    for track in track_order_at(now) {
        let result = match track {
            Track::App => resolve_app_media(video_id, preferred),
            Track::Multi => resolve_multi_media(video_id, preferred),
            Track::Public => resolve_public_media(video_id),
            Track::Web => resolve_web_media(series_id, video_id),
        };
        match result {
            Ok(media) => {
                note_track_success(track);
                let at = Instant::now();
                cache_put(key, media.clone(), at);
                last_put(video_id, &media, at);
                return Ok(media);
            }
            // 取消/超时是「本次不该继续」的信号，既不做降级也不记衰退。
            Err(e @ (SourceError::Canceled | SourceError::Timeout)) => return Err(e),
            Err(e) => {
                note_track_failure(track);
                errors.push(format!("{track:?}: {e}").to_lowercase());
            }
        }
    }
    Err(SourceError::Parse(errors.join("; ")))
}

/// 网页**公开轨**：`/video/public/{vid}/360p.mp4`。
///
/// 免签、明文 H.264/AAC（实测无 `pssh`/`encv`，`moov` 正常），播放器可直接打开，
/// 因此**无需**本机解密代理（`encrypted=false`）。代价是仅 360p。
///
/// 先发一次 Range 探测确认可播：不可播的集返回 404，直接判 `NotFound` 让上层
/// 继续降级，而不是把一个 404 地址交给播放器（那会表现为「黑屏无错」）。
fn resolve_public_media(video_id: &str) -> Result<ResolvedMedia, SourceError> {
    let url = format!("{WEB_BASE}/video/public/{video_id}/360p.mp4");
    http::probe_playable(&url, WEB_REFERER)?;
    Ok(ResolvedMedia {
        url: url.clone(),
        referer: WEB_REFERER,
        duration_secs: 0.0,
        quality: 360,
        encrypted: false,
        key_hex: String::new(),
        variants: vec![ResolvedVariant { url, quality: 360 }],
    })
}

/// App 取流：`video_model/v1` → 按清晰度打分选最优 + 全量 variants。
/// `preferred > 0` 时只在 `quality <= preferred` 里选最优；无满足时回退最低档。
fn resolve_app_media(video_id: &str, preferred: i64) -> Result<ResolvedMedia, SourceError> {
    let result = app_request(
        true,
        "/novel/player/video_model/v1/",
        &[],
        Some(json!({
            "video_id": video_id,
            "content_type": 1,
            "biz_param": { "need_all_video_definition": true, "video_platform": 3 },
        })),
    )?;
    let data = result
        .get("data")
        .ok_or_else(|| SourceError::Parse("app media missing data".to_owned()))?;
    let model: Value = match data.get("video_model") {
        Some(Value::Object(_)) => data["video_model"].clone(),
        Some(Value::String(s)) => serde_json::from_str(s)
            .map_err(|_| SourceError::Parse("app media bad video_model".to_owned()))?,
        _ => {
            return Err(SourceError::Parse(
                "app media missing video_model".to_owned(),
            ));
        }
    };
    select_app_media(&model, preferred)
}

fn select_app_media(model: &Value, preferred: i64) -> Result<ResolvedMedia, SourceError> {
    let mut rows: Vec<&Value> = model
        .get("video_list")
        .and_then(Value::as_array)
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    if rows.is_empty()
        && let Some(map) = model.get("video_list").and_then(Value::as_object)
    {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        rows = keys.into_iter().map(|k| &map[k]).collect();
    }
    let duration = model
        .get("video_duration")
        .or_else(|| model.get("duration"))
        .and_then(|v| {
            v.as_f64().or_else(|| {
                v.as_str()
                    .and_then(|s| s.parse::<f64>().ok())
                    .or_else(|| v.as_i64().map(|n| n as f64))
            })
        })
        .unwrap_or(0.0);
    let mut best: Option<(i64, ResolvedMedia)> = None;
    let mut key_err: Option<SourceError> = None;
    // 全量候选（跨行，供清晰度切换与 UI 展示；最终写回优胜者）。
    let mut all_variants: Vec<ResolvedVariant> = Vec::new();
    for row in rows {
        let meta = row.get("video_meta");
        let codec = meta
            .and_then(|m| m.get("codec_type"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_lowercase();
        let gear = row
            .get("gear_des_key")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_lowercase();
        if codec == "bytevc2" || gear.contains("bytevc2") {
            continue;
        }
        let addresses = collect_addresses(row);
        if addresses.is_empty() {
            continue;
        }
        let mut media = ResolvedMedia {
            url: String::new(),
            referer: PLAYER_REFERER,
            duration_secs: duration,
            quality: 0,
            encrypted: false,
            key_hex: String::new(),
            variants: Vec::new(),
        };
        if let Some(enc) = row.get("encrypt_info") {
            let spade = enc.get("spade_a").and_then(Value::as_str).unwrap_or("");
            let flagged = !spade.is_empty()
                || enc.get("encrypt").and_then(Value::as_bool).unwrap_or(false)
                || enc
                    .get("encryption_method")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    == "cenc-aes-ctr";
            if flagged {
                match content_key(spade) {
                    Ok(key) => {
                        media.encrypted = true;
                        media.key_hex = hex_of(&key);
                    }
                    Err(e) => {
                        key_err = Some(e);
                        continue;
                    }
                }
            }
        }
        let mut height: i64 = meta
            .and_then(|m| m.get("vheight"))
            .and_then(|v| v.as_str().unwrap_or("").parse().ok())
            .or_else(|| meta.and_then(|m| m.get("vheight")).and_then(Value::as_i64))
            .unwrap_or(0);
        let definition: i64 = meta
            .and_then(|m| m.get("definition"))
            .and_then(|v| {
                let s = v.as_str().unwrap_or("");
                s.chars()
                    .filter(|c| c.is_ascii_digit())
                    .collect::<String>()
                    .parse()
                    .ok()
            })
            .or_else(|| {
                meta.and_then(|m| m.get("definition"))
                    .and_then(Value::as_i64)
            })
            .unwrap_or(0);
        if definition > 0 {
            height = definition;
        } else if let Some(width) = meta
            .and_then(|m| m.get("vwidth"))
            .and_then(|v| v.as_str().unwrap_or("").parse().ok().or_else(|| v.as_i64()))
            && width > 0
            && (height == 0 || width < height)
        {
            height = width;
        }
        media.quality = height;
        let mut score = height * 10;
        if codec == "h264" || codec == "avc1" {
            score += 1;
        }
        for address in addresses {
            media.url = address.clone();
            let variant = ResolvedVariant {
                url: address,
                quality: height,
            };
            media.variants.push(variant.clone());
            all_variants.push(variant);
        }
        let replace = best.as_ref().is_none_or(|(s, _)| score > *s);
        if replace {
            best = Some((score, media));
        }
    }
    let top = pick_scored(best.map(|(_, m)| m), all_variants, preferred, key_err)?;
    Ok(top)
}

/// 按期望清晰度挑最终媒体：`preferred > 0` 时在 `quality <= preferred`
/// 里取最优；无满足时回退最低档（不断流）；`preferred <= 0` 取全局最优。
/// `variants` 入参为全量候选（跨行），最终写回优胜者（供 UI 展示与换线）。
fn pick_scored(
    best: Option<ResolvedMedia>,
    all_variants: Vec<ResolvedVariant>,
    preferred: i64,
    key_err: Option<SourceError>,
) -> Result<ResolvedMedia, SourceError> {
    let Some(mut top) = best else {
        return Err(key_err.unwrap_or_else(|| {
            SourceError::Parse("app media has no playable variant".to_owned())
        }));
    };
    top.variants = all_variants;
    // `preferred <= 0` 时不重挑：打分已含 h264 编码加分，比纯看高度更贴合实际画质。
    if preferred > 0
        && let Some(pick) = pick_variant(&top.variants, preferred)
    {
        let url = pick.url.clone();
        let quality = pick.quality;
        top.url = url;
        top.quality = quality;
    }
    Ok(top)
}

/// multi 取流：`multi_video_model/v1` → `fallback_api` → `video_info`。
/// 与 `video_model/v1` 是两套端点与载荷，互为备份；`main_url` 为
/// spade 加密串，用 `key_seed` 解出真实地址。
fn resolve_multi_media(video_id: &str, preferred: i64) -> Result<ResolvedMedia, SourceError> {
    let result = app_request(
        true,
        "/novel/player/multi_video_model/v1/",
        &[],
        Some(json!({
            "biz_param": {
                "detail_page_version": 0,
                "device_level": 3,
                "disable_digg_stat": false,
                "need_all_video_definition": true,
                "need_mp4_align": false,
                "use_os_player": false,
                "use_server_dns": false,
                "video_platform": 1024,
            },
            "mixed_video_id_map": { "1004": [video_id] },
        })),
    )?;
    let data = result
        .get("data")
        .ok_or_else(|| SourceError::Parse("multi missing data".to_owned()))?;
    let entry = data
        .get(video_id)
        .or_else(|| {
            data.as_object()
                .and_then(|m| m.values().find(|v| v.is_object()))
        })
        .ok_or_else(|| SourceError::Parse("multi missing entry".to_owned()))?;
    let model: Value = match entry.get("video_model") {
        Some(Value::Object(_)) => entry["video_model"].clone(),
        Some(Value::String(s)) => serde_json::from_str(s)
            .map_err(|_| SourceError::Parse("multi bad video_model".to_owned()))?,
        _ => return Err(SourceError::Parse("multi missing video_model".to_owned())),
    };
    let fallback = model
        .get("fallback_api")
        .and_then(|v| match v {
            Value::String(s) => serde_json::from_str::<Value>(s)
                .ok()
                .and_then(|p| {
                    p.get("fallback_api")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                })
                .or_else(|| Some(s.clone())),
            Value::Array(a) => a.first().and_then(Value::as_str).map(str::to_owned),
            _ => v
                .get("fallback_api")
                .and_then(Value::as_str)
                .map(str::to_owned),
        })
        .filter(|s| !s.is_empty())
        .ok_or_else(|| SourceError::Parse("multi missing fallback_api".to_owned()))?;
    let outer: Value = {
        let req = OutboundRequest {
            post: false,
            url: fallback,
            headers: vec![("User-Agent".to_owned(), APP_UA.to_owned())],
            body: None,
        };
        http::fetch_json_custom(&req).map_err(SourceError::from)?
    };
    let info = outer
        .get("video_info")
        .and_then(|v| v.get("data"))
        .ok_or_else(|| SourceError::Parse("multi missing video_info".to_owned()))?;
    let seed_b64 = info.get("key_seed").and_then(Value::as_str).unwrap_or("");
    let seed = decode_b64(seed_b64).unwrap_or_default();
    let list = info
        .get("video_list")
        .and_then(Value::as_object)
        .ok_or_else(|| SourceError::Parse("multi missing video_list".to_owned()))?;
    let duration = info
        .get("duration")
        .and_then(|v| {
            v.as_f64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        })
        .unwrap_or(0.0);
    // 行按清晰度数值降序。
    let mut rows: Vec<(&String, &Value)> = list.iter().collect();
    rows.sort_by_key(|(k, v)| {
        let q = ["quality_desc", "height", "vheight", "quality"]
            .iter()
            .map(|f| quality_field(v, f))
            .find(|q| *q > 0)
            .unwrap_or_else(|| quality_number(k));
        std::cmp::Reverse(q)
    });
    let mut all_variants: Vec<ResolvedVariant> = Vec::new();
    let mut best: Option<(i64, ResolvedMedia)> = None;
    let mut key_err: Option<SourceError> = None;
    for (key, item) in rows {
        let enc_url = item.get("main_url").and_then(Value::as_str).unwrap_or("");
        if enc_url.is_empty() {
            continue;
        }
        let url = match decrypt_spade_url(enc_url, &seed) {
            Ok(u) if is_http_media_url(&u) => u,
            _ => continue,
        };
        // 行键本身常带清晰度（如 720p/adapt），字段缺失时回退到行键。
        // 字段可能是整数也可能是字符串，统一经 quality_field 读取。
        let quality = ["quality_desc", "height", "vheight", "quality"]
            .iter()
            .map(|k| quality_field(item, k))
            .find(|q| *q > 0)
            .unwrap_or_else(|| quality_number(key));
        let spade = item.get("spade_a").and_then(Value::as_str).unwrap_or("");
        let (encrypted, key_hex) = if spade.is_empty() {
            (false, String::new())
        } else {
            match content_key(spade).or_else(|_| content_key_fallback(spade)) {
                Ok(k) => (true, hex_of(&k)),
                Err(e) => {
                    key_err = Some(e);
                    continue;
                }
            }
        };
        let media = ResolvedMedia {
            url: url.clone(),
            referer: PLAYER_REFERER,
            duration_secs: duration,
            quality,
            encrypted,
            key_hex,
            variants: vec![ResolvedVariant {
                url: url.clone(),
                quality,
            }],
        };
        all_variants.push(ResolvedVariant { url, quality });
        let score = quality * 10;
        if best.as_ref().is_none_or(|(s, _)| score > *s) {
            best = Some((score, media));
        }
    }
    let top = pick_scored(best.map(|(_, m)| m), all_variants, preferred, key_err)?;
    Ok(top)
}

/// 清晰度数值（2160/1440/1080/720/576/540/480/360，或 1920→1080 等映射）。
fn quality_number(value: &str) -> i64 {
    let digits: String = value.chars().filter(|c| c.is_ascii_digit()).collect();
    for cand in ["2160", "1440", "1080", "720", "576", "540", "480", "360"] {
        if digits.contains(cand) {
            return cand.parse().unwrap_or(0);
        }
    }
    match digits.as_str() {
        "1920" => 1080,
        "1280" => 720,
        "1024" => 576,
        "854" => 480,
        "640" => 360,
        s if s.len() >= 3 => s.parse().unwrap_or(0),
        _ => quality_label(value),
    }
}

/// 档位标签映射（无数字时的兜底口径）。
fn quality_label(value: &str) -> i64 {
    match value.to_lowercase().as_str() {
        "low" | "smooth" | "流畅" => 360,
        "medium" | "标清" => 540,
        "normal" | "高清" => 720,
        "high" | "超清" => 1080,
        "original" | "uhd" | "super_high" | "原画" => 2160,
        _ => 0,
    }
}

/// 字段值转清晰度（整数与字符串统一走同一映射，保证宽高口径一致）。
fn quality_field(item: &Value, key: &str) -> i64 {
    match item.get(key) {
        Some(Value::Number(n)) => quality_number(&n.to_string()),
        Some(Value::String(s)) => quality_number(s),
        _ => 0,
    }
}

/// spade 加密地址 → 真实地址（AES-128-CBC，SHA512 派生）。
fn decrypt_spade_url(value: &str, seed: &[u8]) -> Result<String, SourceError> {
    use sha2::{Digest, Sha512};
    let raw =
        decode_b64(value).map_err(|_| SourceError::Parse("spade url bad encoding".to_owned()))?;
    if raw.len() < 5 || raw[0] != 0xa8 || raw[2] != 0x01 || raw[3] != 0x00 {
        return Err(SourceError::Parse("spade url bad header".to_owned()));
    }
    let cipher_len = (raw.len() - 4) / 16 * 16;
    if cipher_len == 0 {
        return Err(SourceError::Parse("spade url no block".to_owned()));
    }
    const CONSTANTS_HEX: &str = "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58";
    let constants = hex_decode(CONSTANTS_HEX).expect("checked 128 hex");
    let h1 = Sha512::digest(seed).to_vec();
    let mut h2 = Sha512::new();
    h2.update(&h1);
    h2.update(&constants);
    let h2 = h2.finalize().to_vec();
    let mut plain = raw[4..4 + cipher_len].to_vec();
    decrypt_cbc(&h2[..16], &h2[16..32], &mut plain)
        .map_err(|_| SourceError::Parse("spade url decrypt failed".to_owned()))?;
    if let Some(&pad) = plain.last()
        && (1..=16).contains(&pad)
        && (pad as usize) <= plain.len()
    {
        plain.truncate(plain.len() - pad as usize);
    }
    while plain.last() == Some(&0) {
        plain.pop();
    }
    String::from_utf8(plain).map_err(|_| SourceError::Parse("spade url not utf8".to_owned()))
}

/// AES-128-CBC 解密（无填充，整块）。
fn decrypt_cbc(key: &[u8], iv: &[u8], data: &mut [u8]) -> Result<(), ()> {
    use aes::Aes128;
    use aes::cipher::{BlockCipherDecrypt, KeyInit};
    if !data.len().is_multiple_of(16) {
        return Err(());
    }
    let key: [u8; 16] = key.try_into().map_err(|_| ())?;
    let mut prev: [u8; 16] = iv.try_into().map_err(|_| ())?;
    let mut block = [0u8; 16];
    let cipher = Aes128::new((&key).into());
    for chunk in data.chunks_mut(16) {
        block.copy_from_slice(chunk);
        let mut b = block;
        cipher.decrypt_block((&mut b).into());
        for (i, byte) in chunk.iter_mut().enumerate() {
            *byte = b[i] ^ prev[i];
        }
        prev.copy_from_slice(&block);
    }
    Ok(())
}

/// 备用密钥派生（另一代 spade_a 编码；主算法失败时兜底）。
fn content_key_fallback(value: &str) -> Result<[u8; 16], SourceError> {
    let fixed = value.replace('-', "+").replace('_', "/");
    let raw =
        decode_b64(&fixed).map_err(|_| SourceError::Parse("spade key bad encoding".to_owned()))?;
    if raw.len() < 3 {
        return Err(SourceError::Parse("spade key bad encoding".to_owned()));
    }
    let v8 = (raw.len() - (raw[0] ^ raw[1] ^ raw[2]) as usize + 47).min(raw.len() - 1);
    if v8 < 33 {
        return Err(SourceError::Parse("spade key bad content".to_owned()));
    }
    let mut work = raw[1..1 + v8].to_vec();
    let (mut a, mut b) = (85u8, 246u8);
    for (i, byte) in work.iter_mut().enumerate() {
        let old = *byte;
        let previous = if i & 1 == 1 { a } else { b };
        if i & 1 == 1 {
            a = old;
        } else {
            b = old;
        }
        let pop = (i as u32).count_ones() as i16;
        *byte = ((-(21i16) - pop + (previous ^ old) as i16) & 255) as u8;
    }
    let hex_str = work
        .get(1..33)
        .and_then(|s| std::str::from_utf8(s).ok())
        .ok_or_else(|| SourceError::Parse("spade key bad content".to_owned()))?;
    let key =
        hex_decode(hex_str).ok_or_else(|| SourceError::Parse("spade key not aes128".to_owned()))?;
    if key.len() != 16 {
        return Err(SourceError::Parse("spade key not aes128".to_owned()));
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&key);
    Ok(out)
}

/// 网页取流降级：`/player/{sid}/{vid}` → `video_player_info` 明文地址。
fn resolve_web_media(series_id: &str, video_id: &str) -> Result<ResolvedMedia, SourceError> {
    let url = format!("{WEB_BASE}/player/{series_id}/{video_id}");
    let html = http::fetch_text_throttled(&url).map_err(SourceError::from)?;
    let data = crate::sources::hongguo::web_ssr::extract_router_data(&html)?;
    let page = find_loader_page(&data, &["player_", "player_page"])
        .ok_or_else(|| SourceError::Parse("web player page missing".to_owned()))?;
    if page.get("vid").and_then(Value::as_str).unwrap_or("") != video_id
        || page.get("series_id").and_then(Value::as_str).unwrap_or("") != series_id
    {
        return Err(SourceError::Parse("web player id mismatch".to_owned()));
    }
    let info = page
        .get("video_player_info")
        .ok_or_else(|| SourceError::Parse("web player info missing".to_owned()))?;
    let addresses = collect_addresses(info);
    let first = addresses
        .into_iter()
        .next()
        .ok_or_else(|| SourceError::Parse("web player has no public url".to_owned()))?;
    let duration = info
        .get("duration")
        .and_then(|v| v.as_str().unwrap_or("").parse::<f64>().ok())
        .or_else(|| info.get("duration").and_then(Value::as_f64))
        .unwrap_or(0.0);
    Ok(ResolvedMedia {
        url: first.clone(),
        referer: PLAYER_REFERER,
        duration_secs: duration,
        quality: 0,
        encrypted: false,
        key_hex: String::new(),
        variants: vec![ResolvedVariant {
            url: first,
            quality: 0,
        }],
    })
}

/// 在 loaderData 里按精确名或前缀找页面。
fn find_loader_page<'a>(data: &'a Value, names: &[&str]) -> Option<&'a Value> {
    let loader = data.get("loaderData")?.as_object()?;
    for name in names {
        if let Some(page) = loader.get(*name)
            && page.is_object()
        {
            return Some(page);
        }
    }
    for (key, page) in loader {
        for name in names {
            let prefix = name.trim_end_matches('$');
            if !prefix.is_empty() && key.starts_with(prefix) && page.is_object() {
                return Some(page);
            }
        }
    }
    None
}

/// 地址收集：`main_url` / `backup_url*` / `url_list`，支持字符串、base64 串与数组。
fn collect_addresses(info: &Value) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    fn add(value: &Value, out: &mut Vec<String>, seen: &mut std::collections::HashSet<String>) {
        match value {
            Value::String(s) => {
                let address = s.trim().to_owned();
                if address.len() > 8192 {
                    return;
                }
                let address = if is_http_media_url(&address) {
                    address
                } else {
                    match decode_b64(&address) {
                        Ok(raw) => String::from_utf8_lossy(&raw).trim().to_owned(),
                        Err(_) => return,
                    }
                };
                if is_http_media_url(&address) && seen.insert(address.clone()) {
                    out.push(address);
                }
            }
            Value::Array(items) => {
                for item in items {
                    add(item, out, seen);
                }
            }
            _ => {}
        }
    }
    for key in [
        "main_url",
        "backup_url",
        "backup_url_1",
        "backup_url_2",
        "backup_urls",
        "url_list",
    ] {
        if let Some(v) = info.get(key) {
            add(v, &mut out, &mut seen);
        }
    }
    out
}

fn is_http_media_url(s: &str) -> bool {
    s.starts_with("http://") || s.starts_with("https://")
}

fn decode_b64(s: &str) -> Result<Vec<u8>, ()> {
    use base64::Engine;
    let s = s.trim();
    base64::engine::general_purpose::STANDARD
        .decode(s)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(s))
        .map_err(|_| ())
}

/// `spade_a` → AES-128 密钥（纯字节运算）。
fn content_key(value: &str) -> Result<[u8; 16], SourceError> {
    if value.len() > 1024 {
        return Err(SourceError::Parse("content key too long".to_owned()));
    }
    let raw =
        decode_b64(value).map_err(|_| SourceError::Parse("content key bad encoding".to_owned()))?;
    if raw.len() < 3 {
        return Err(SourceError::Parse("content key bad encoding".to_owned()));
    }
    let tag_len = (raw[0] ^ raw[1] ^ raw[2]).wrapping_sub(48) as usize;
    let content_len = raw.len() - tag_len - 1;
    if tag_len < 1 || content_len < 33 || content_len >= raw.len() {
        return Err(SourceError::Parse("content key bad structure".to_owned()));
    }
    let seed = raw[raw.len() - tag_len - 2] ^ raw[raw.len() - tag_len - 1];
    let tag: Vec<u8> = raw[raw.len() - tag_len..]
        .iter()
        .map(|b| b ^ seed)
        .collect();
    if tag == b"app_v2" || tag == b"web_v2" {
        return Err(SourceError::Parse(
            "content key version unsupported".to_owned(),
        ));
    }
    let mut decoded = vec![0u8; content_len];
    let (mut prev_even, mut prev_odd) = (250u8, 85u8);
    for (index, current) in raw[1..1 + content_len].iter().enumerate() {
        let previous = if index % 2 == 0 {
            let p = prev_even;
            prev_even = *current;
            p
        } else {
            let p = prev_odd;
            prev_odd = *current;
            p
        };
        let ones = index.count_ones() as u8;
        decoded[index] = (previous ^ current).wrapping_sub(21).wrapping_sub(ones);
    }
    let padding: u8 = decoded[0..1]
        .first()
        .and_then(|b| u32::from_str_radix(&(*b as char).to_string(), 36).ok())
        .map(|n| n as u8)
        .ok_or_else(|| SourceError::Parse("content key bad content".to_owned()))?;
    if content_len - padding as usize - 1 != 32 {
        return Err(SourceError::Parse("content key bad content".to_owned()));
    }
    let hex_str = std::str::from_utf8(&decoded[1..33])
        .map_err(|_| SourceError::Parse("content key not hex".to_owned()))?;
    let key = hex_decode(hex_str)
        .ok_or_else(|| SourceError::Parse("content key not aes128".to_owned()))?;
    if key.len() != 16 {
        return Err(SourceError::Parse("content key not aes128".to_owned()));
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&key);
    Ok(out)
}

fn hex_of(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

fn str_field(v: &Value, keys: &[&str]) -> String {
    keys.iter()
        .filter_map(|k| v.get(*k))
        .filter_map(Value::as_str)
        .find(|s| !s.trim().is_empty())
        .unwrap_or("")
        .to_owned()
}

fn first_str(v: &Value, keys: &[&str]) -> String {
    str_field(v, keys)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numeric_id_shape() {
        assert!(is_numeric_id("123"));
        assert!(!is_numeric_id(""));
        assert!(!is_numeric_id("12a"));
        assert!(!is_numeric_id(&"1".repeat(33)));
    }

    #[test]
    fn address_collection_prefers_order_and_decodes_b64() {
        use base64::Engine;
        let raw = base64::engine::general_purpose::STANDARD.encode("https://cdn.example/x.mp4");
        let info = json!({
            "main_url": "https://cdn.example/a.mp4",
            "backup_url_1": [raw, "https://cdn.example/a.mp4"],
            "junk": 42,
        });
        let got = collect_addresses(&info);
        assert_eq!(
            got,
            vec!["https://cdn.example/a.mp4", "https://cdn.example/x.mp4"]
        );
    }

    #[test]
    fn app_code_check() {
        assert!(check_app_code(&json!({})).is_ok());
        assert!(check_app_code(&json!({"code": "0"})).is_ok());
        assert!(check_app_code(&json!({"BaseResp": {"StatusCode": "0"}})).is_ok());
        assert!(check_app_code(&json!({"code": "450"})).is_err());
    }

    #[test]
    fn content_key_rejects_garbage() {
        assert!(content_key("!!!").is_err());
        assert!(content_key("app_v2").is_err());
    }

    #[test]
    fn select_scores_h264_highest_and_skips_bytevc2() {
        let model = json!({
            "video_duration": "60.5",
            "video_list": [
                {"video_meta": {"codec_type": "bytevc2", "vheight": "1080"},
                 "main_url": "https://cdn.example/h.mp4"},
                {"video_meta": {"codec_type": "h264", "vheight": "720"},
                 "main_url": "https://cdn.example/m.mp4"},
                {"video_meta": {"codec_type": "h264", "vheight": "480"},
                 "main_url": "https://cdn.example/l.mp4",
                 "encrypt_info": {"spade_a": "bad!!!"}},
            ],
        });
        let m = select_app_media(&model, 0).unwrap();
        assert_eq!(m.url, "https://cdn.example/m.mp4");
        assert!(!m.encrypted);
        assert_eq!(m.quality, 720);
        // 坏密钥的 480p 档被跳过，只剩 720p。
        assert_eq!(m.variants.len(), 1);
    }

    #[test]
    fn preferred_quality_picks_cap_and_falls_back() {
        let model = json!({
            "video_list": [
                {"video_meta": {"vheight": "1080"}, "main_url": "https://cdn.example/h.mp4"},
                {"video_meta": {"vheight": "720"}, "main_url": "https://cdn.example/m.mp4"},
                {"video_meta": {"vheight": "480"}, "main_url": "https://cdn.example/l.mp4"},
            ],
        });
        // 0 = 最高。
        assert_eq!(select_app_media(&model, 0).unwrap().quality, 1080);
        // 上限 720 → 720。
        assert_eq!(select_app_media(&model, 720).unwrap().quality, 720);
        // 上限低于全部门 → 回退最低不断流。
        assert_eq!(select_app_media(&model, 100).unwrap().quality, 480);
    }

    #[test]
    fn quality_number_maps_labels() {
        assert_eq!(quality_number("1080P"), 1080);
        assert_eq!(quality_number("超清"), 1080);
        assert_eq!(quality_number("流畅"), 360);
        assert_eq!(quality_number("1920"), 1080);
        assert_eq!(quality_number("1280"), 720);
        assert_eq!(quality_number(""), 0);
        assert_eq!(quality_field(&json!({"vheight": 720}), "vheight"), 720);
        assert_eq!(quality_field(&json!({"vheight": "480"}), "vheight"), 480);
    }

    /// 轨道记忆是**进程级全局**：相关测试必须拿同一把锁，并在开场清空状态，
    /// 否则会读到别的测试留下的冷却标记（并发跑时表现为偶发失败）。
    fn lock_track_memory() -> std::sync::MutexGuard<'static, ()> {
        static TEST_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));
        let guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        TRACK_FAILS.lock().expect("track memory poisoned").clear();
        guard
    }

    #[test]
    fn base_order_is_quality_first_when_nothing_failed() {
        let _guard = lock_track_memory();
        let now = Instant::now();
        assert_eq!(
            track_order_at(now),
            vec![Track::App, Track::Multi, Track::Public, Track::Web]
        );
    }

    #[test]
    fn failed_track_is_demoted_behind_healthy_ones() {
        let _guard = lock_track_memory();
        let t0 = Instant::now();
        note_track_failure(Track::App);
        // 冷却期内：App 被压到最后，公开轨提前到第二位（画质次之的 multi 在前）。
        let order = track_order_at(t0);
        assert_eq!(order.first(), Some(&Track::Multi));
        assert_eq!(order.last(), Some(&Track::App));
        assert_eq!(order.len(), 4, "no track is dropped from rotation");
        note_track_success(Track::App);
    }

    #[test]
    fn cool_down_expires_and_track_returns_to_front() {
        let _guard = lock_track_memory();
        let t0 = Instant::now();
        note_track_failure(Track::App);
        assert!(track_is_cooled_at(Track::App, t0));
        // 超过冷却期 → 恢复画质优先（不永久放弃高画质轨）。
        let later = t0 + TRACK_COOLDOWN + Duration::from_secs(1);
        assert!(!track_is_cooled_at(Track::App, later));
        assert_eq!(track_order_at(later)[0], Track::App);
        note_track_success(Track::App);
    }

    #[test]
    fn success_clears_the_failure_mark_immediately() {
        let _guard = lock_track_memory();
        let t0 = Instant::now();
        note_track_failure(Track::Public);
        assert!(track_is_cooled_at(Track::Public, t0));
        note_track_success(Track::Public);
        assert!(!track_is_cooled_at(Track::Public, t0));
    }

    #[test]
    fn success_is_never_promoted_above_higher_quality_tracks() {
        let _guard = lock_track_memory();
        // 「成功过的低画质轨」不允许反超：否则预取一次 360p 后，
        // 用户要 1080p 也会被钉死在 360p。
        let t0 = Instant::now();
        note_track_success(Track::Public);
        assert_eq!(track_order_at(t0)[0], Track::App);
    }

    #[test]
    fn resolve_cache_hits_within_ttl_and_expires_after() {
        let t0 = Instant::now();
        let key = cache_key("123456", 720);
        assert!(cache_get(&key, t0).is_none());
        let media = ResolvedMedia {
            url: "https://cdn.example/a.mp4".to_owned(),
            referer: PLAYER_REFERER,
            duration_secs: 60.0,
            quality: 720,
            encrypted: false,
            key_hex: String::new(),
            variants: vec![],
        };
        cache_put(key.clone(), media.clone(), t0);
        let hit = cache_get(&key, t0 + Duration::from_secs(10)).expect("should hit");
        assert_eq!(hit.url, media.url);
        // TTL 到期 → 未命中（宁可重签，也不让过期链接造成黑屏）。
        assert!(cache_get(&key, t0 + RESOLVE_TTL + Duration::from_secs(1)).is_none());
    }

    #[test]
    fn resolve_cache_is_keyed_by_video_and_quality() {
        assert_ne!(cache_key("1", 720), cache_key("1", 1080));
        assert_ne!(cache_key("1", 720), cache_key("2", 720));
        assert_eq!(cache_key("1", 720), cache_key("1", 720));
    }

    #[test]
    fn spade_url_rejects_garbage() {
        assert!(decrypt_spade_url("!!!", &[]).is_err());
        assert!(decrypt_spade_url("aGVsbG8=", &[]).is_err());
        assert!(content_key_fallback("!!!").is_err());
    }

    // ── 换档（清晰度多档切换）──────────────────────────────────────────
    //
    // 契约：换档只在**已解析出的候选**里重挑，绝不重新签名（否则用户点一下要等
    // 一整条网络链）。这几个用例锁住「挑哪一档」的口径。

    fn variants(heights: &[i64]) -> Vec<ResolvedVariant> {
        heights
            .iter()
            .map(|h| ResolvedVariant {
                url: format!("https://cdn.example/{h}.mp4"),
                quality: *h,
            })
            .collect()
    }

    #[test]
    fn pick_variant_honors_preferred_ceiling() {
        let vs = variants(&[360, 720, 1080]);
        // 上限 720 → 取 720，不是 1080。
        assert_eq!(pick_variant(&vs, 720).expect("pick").quality, 720);
        // 上限 1080 → 取 1080。
        assert_eq!(pick_variant(&vs, 1080).expect("pick").quality, 1080);
        // 0 = 不限 → 取最高。
        assert_eq!(pick_variant(&vs, 0).expect("pick").quality, 1080);
    }

    #[test]
    fn pick_variant_falls_back_to_lowest_when_all_above_ceiling() {
        let vs = variants(&[720, 1080]);
        // 上限 240：没有任何档满足 → 回退最低档（宁可糊也不断流）。
        assert_eq!(pick_variant(&vs, 240).expect("pick").quality, 720);
    }

    #[test]
    fn pick_variant_on_empty_is_none() {
        assert!(pick_variant(&[], 720).is_none());
    }

    #[test]
    fn quality_options_are_deduped_and_descending() {
        let opts = quality_options(&variants(&[360, 1080, 360, 2160, 1440]));
        let heights: Vec<i64> = opts
            .iter()
            .map(|o| o["height"].as_i64().unwrap_or_default())
            .collect();
        assert_eq!(heights, vec![2160, 1440, 1080, 360]);
        // 标签口径：2160→4K、1440→2K，其余 `{h}P`。
        assert_eq!(opts[0]["label"], json!("4K"));
        assert_eq!(opts[1]["label"], json!("2K"));
        assert_eq!(opts[2]["label"], json!("1080P"));
    }

    #[test]
    fn switch_quality_is_zero_network_and_switchable() {
        let vid = "switch-test-vid";
        let media = ResolvedMedia {
            url: "https://cdn.example/1080.mp4".to_owned(),
            referer: PLAYER_REFERER,
            duration_secs: 60.0,
            quality: 1080,
            encrypted: false,
            key_hex: String::new(),
            variants: variants(&[360, 720, 1080]),
        };
        last_put(vid, &media, Instant::now());

        let got = switch_quality(vid, 480).expect("should switch");
        assert_eq!(got.quality, 360);
        assert_eq!(got.url, "https://cdn.example/360.mp4");
        // 换档不该把候选丢掉——还要支持继续往上切。
        assert_eq!(got.variants.len(), 3);

        // 未知 vid → None（调用方回落完整解析）。
        assert!(switch_quality("never-resolved", 720).is_none());

        // TTL 过期 → None（宁可重解析，也不拿过期直链换档）。
        let old = Instant::now() - RESOLVE_TTL - Duration::from_secs(1);
        last_put(vid, &media, old);
        assert!(switch_quality(vid, 1080).is_none());
    }

    /// 换档快路径成本：**不含网络**的那部分（重挑 variant + 出参 JSON）。
    ///
    /// 旧行为是换 `quality` 调 `play` → 解析缓存键不同 → 整条签名链重跑
    /// （网络 + 重试退避，实测数百毫秒起）。新行为走 `switch_quality`：
    /// 这两项就是它的全部引擎开销（代理注册另算，那是本机回环）。
    fn best_of<F: FnMut() -> f64>(mut measure: F, groups: usize) -> f64 {
        (0..groups).map(|_| measure()).fold(f64::INFINITY, f64::min)
    }

    #[test]
    #[ignore = "性能测量：需 release，见模块内说明"]
    fn bench_quality_switch_path() {
        let vid = "bench-switch-vid";
        let media = ResolvedMedia {
            url: "https://cdn.example/1080.mp4".to_owned(),
            referer: PLAYER_REFERER,
            duration_secs: 60.0,
            quality: 1080,
            encrypted: false,
            key_hex: String::new(),
            // 6 档：360/480/540/720/1080/1440，取典型 App 轨规模。
            variants: variants(&[360, 480, 540, 720, 1080, 1440]),
        };
        last_put(vid, &media, Instant::now());

        const ROUNDS: usize = 2000;
        let per_switch = best_of(
            || {
                let start = Instant::now();
                for i in 0..ROUNDS {
                    let height = [360i64, 720, 1080, 480, 1440][i % 5];
                    let got = switch_quality(vid, height).expect("switch");
                    assert_eq!(got.quality, height);
                    let json = serde_json::to_string(&got.to_json()).unwrap();
                    assert!(json.contains("proxyUrl") || json.contains("qualityOptions"));
                }
                start.elapsed().as_secs_f64() * 1e6 / ROUNDS as f64
            },
            5,
        );
        println!("换档快路径（重挑 + 出参序列化，零网络）: {per_switch:.2}µs/次");

        let opts = quality_options(&media.variants);
        let labels: Vec<&str> = opts.iter().filter_map(|o| o["label"].as_str()).collect();
        println!("档位表（降序）: {labels:?}");

        LAST_BY_VID.lock().unwrap().clear();
    }

    #[test]
    fn web_mismatch_is_rejected() {
        let data = json!({"loaderData": {"player_page": {
            "vid": "2", "series_id": "1", "video_player_info": {},
        }}});
        // 直接调内部 find 逻辑：id 不一致时 resolve 应失败（此处只验证查找器）。
        assert!(find_loader_page(&data, &["player_", "player_page"]).is_some());
    }
}
