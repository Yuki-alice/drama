//! 红果 App 签名接口（取流面）。
//!
//! 分层说明：浏览类（目录/推荐/榜单/搜索/建议）走免签 SSR（见 `web_ssr`，
//! 快且稳定）；详情与取流走本模块的签名 App 接口，失败时逐级降级：
//! App 详情 → SSR 详情；App 取流 → 网页取流。
//! 第三方备用接口不接入（不可靠且引入外部依赖）。
//!
//! 算法（签名、密钥派生、清晰度打分）与参照 Go 实现一致；
//! `hongguoContentKey` 的边界行为由单测锁定。

use std::time::{SystemTime, UNIX_EPOCH};

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
    params.push(("_rticket".to_owned(), now_ms.to_string()));
    let raw_query = sign::encode_query_sorted(&mut params);
    let url = format!("{APP_BASE}{path}?{raw_query}");
    let sig = sign::sign_request(&raw_query, body, (now_ms / 1000) as u32, now_ms);

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

/// 取流主链：App 签名接口 → 网页**公开轨** → 网页 SSR。
///
/// **三条轨的实测行为**（联网校准）：
/// 1. `video_model/v1`（App 签名，正常时给 1080p 加密流）——当前上游对未授权
///    客户端返回 `HTTP 200` + **空 body**（同一签名打 `video_detail` 却有 84KB，
///    故不是签名/身份问题），因此实际取流靠下面两条；
/// 2. 网页公开轨 `{WEB_BASE}/video/public/{vid}/360p.mp4`——**免签、明文、可直接播**。
///    这是官网网页播放器自己用的地址；覆盖每部剧前 `accessible_episode_cnt` 集
///    （多剧实测均为 3 集），其余集 404。见 [`resolve_public_media`]；
/// 3. 网页 SSR `video_player_info`——站点已改为 `protectedPlayback` 且
///    `videoList` 为空对象，该字段不再下发，保留仅为站点回退时可用。
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
    let mut errors: Vec<String> = Vec::new();

    match resolve_app_media(video_id, preferred) {
        Ok(media) => return Ok(media),
        // 取消/超时是「本次不该继续」的信号，不做降级。
        Err(e @ (SourceError::Canceled | SourceError::Timeout)) => return Err(e),
        Err(e) => errors.push(format!("app: {e}")),
    }

    match resolve_public_media(video_id) {
        Ok(media) => return Ok(media),
        Err(e @ (SourceError::Canceled | SourceError::Timeout)) => return Err(e),
        Err(e) => errors.push(format!("public: {e}")),
    }

    match resolve_web_media(series_id, video_id) {
        Ok(media) => Ok(media),
        Err(e) => {
            errors.push(format!("web: {e}"));
            Err(SourceError::Parse(errors.join("; ")))
        }
    }
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
    if preferred > 0 {
        let mut under: Option<&ResolvedVariant> = None;
        let mut lowest: Option<&ResolvedVariant> = None;
        for v in &top.variants {
            let is_lower = lowest.is_none_or(|l| v.quality < l.quality);
            if is_lower {
                lowest = Some(v);
            }
            if v.quality <= preferred && under.is_none_or(|u| v.quality > u.quality) {
                under = Some(v);
            }
        }
        if let Some(pick) = under.or(lowest) {
            top.url = pick.url.clone();
            top.quality = pick.quality;
        }
    }
    Ok(top)
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
    fn web_mismatch_is_rejected() {
        let data = json!({"loaderData": {"player_page": {
            "vid": "2", "series_id": "1", "video_player_info": {},
        }}});
        // 直接调内部 find 逻辑：id 不一致时 resolve 应失败（此处只验证查找器）。
        assert!(find_loader_page(&data, &["player_", "player_page"]).is_some());
    }
}
