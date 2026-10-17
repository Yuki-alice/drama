//! 红果源实现：把签名、SSR、取流、弹幕装配成 [`SourceProvider`]。
//!
//! ## 取流三级降级
//!
//! 1. **App 签名** `video_model/v1`（全清晰度）；
//! 2. **网页公开轨** `/video/public/{vid}/360p.mp4`（免签明文，试看集）；
//! 3. **网页 SSR** `/player/{sid}/{vid}`（站点已改保护播放，兜底）。
//!
//! 失败文案会**汇总三级各自的原因**——只报最后一级会把「上游接口空 body」
//! 误报成「网页取流失败」，排障时完全误导。

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

use drama_types::{
    Caps, CatalogPage, DanmakuPage, Drama, DramaDetail, PlayRequest, RankingBoard, RankingPage,
    RankingItem, ResolvedMedia, SearchResult, SourceDescriptor, SourceId, SourceKind,
    SourceProvider, Variant,
};

use crate::ssr;
use crate::{PLAYER_REFERER, SOURCE_ID, WEB_BASE, WEB_REFERER};

/// 分类定义：`(key, App scene, 展示名)`。
pub const GENRES: [(&str, &str, &str); 3] = [
    ("short_play", "default", "真人剧"),
    ("comic_series", "comic_series", "漫剧"),
    ("ai_series", "ai_series", "AI剧"),
];

/// 榜单板定义：`(board id, 展示名, 描述, 站内路由)`。
pub const BOARDS: [(&str, &str, &str, &str); 4] = [
    (
        "hongguo-hot",
        "总热播榜",
        "红果观看、互动等综合热度；每日更新。",
        "hot-drama",
    ),
    (
        "hongguo-real",
        "真人剧榜",
        "红果真人剧热播榜；每日更新。",
        "hot-real-drama",
    ),
    (
        "hongguo-comic",
        "漫剧榜",
        "红果漫剧热播榜；每日更新。",
        "hot-comic-drama",
    ),
    ("hongguo-ai", "AI剧榜", "红果 AI 剧热播榜；每日更新。", "hot-ai-drama"),
];

/// 红果源。
#[derive(Debug, Default, Clone)]
pub struct HongguoProvider;

impl HongguoProvider {
    pub fn new() -> Self {
        HongguoProvider
    }

    /// 封面地址换成本机代理（由 engine 注入的 [`crate::media`] 层完成；
    /// 这里只负责把相对路径补全为绝对 URL）。
    fn absolutize(drama: &mut Drama) {
        if !drama.cover.is_empty()
            && !drama.cover.starts_with("http://")
            && !drama.cover.starts_with("https://")
        {
            drama.cover = ssr::absolutize_cover(&drama.cover);
        }
    }

    /// 网页取流（SSR）：`/player/{sid}/{vid}`。
    fn resolve_web(&self, series_id: &str, vid: &str) -> Result<ResolvedMedia, String> {
        let url = format!("{WEB_BASE}/player/{series_id}/{vid}");
        let html = drama_net::fetch_text_throttled(&url).map_err(|e| e.to_string())?;
        let data = ssr::extract_router_data(&html).map_err(|e| e.to_string())?;
        let page = ssr::find_payload_by_prefix(&data, "player_")
            .ok_or_else(|| "红果网页播放页缺少负载".to_owned())?;

        // 身份校验：站点在拿不到目标集时会给别的集。
        let returned_vid = page.get("vid").and_then(Value::as_str).unwrap_or("");
        let returned_sid = page.get("series_id").and_then(Value::as_str).unwrap_or("");
        if (!returned_vid.is_empty() && returned_vid != vid)
            || (!returned_sid.is_empty() && returned_sid != series_id)
        {
            return Err("红果未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限".to_owned());
        }

        let info = page.get("video_player_info").cloned().unwrap_or(Value::Null);
        let addresses = crate::media::media_addresses(&info);
        if addresses.is_empty() {
            return Err(
                "红果该集未提供公开播放地址，可能需要登录或 App 授权；不会将试看集冒充该集下载"
                    .to_owned(),
            );
        }
        let duration = info
            .get("duration")
            .and_then(Value::as_str)
            .and_then(|s| s.parse::<f64>().ok())
            .or_else(|| info.get("duration").and_then(Value::as_f64))
            .unwrap_or(0.0);
        let variants = addresses
            .iter()
            .map(|url| Variant {
                url: url.clone(),
                quality: 0,
                encrypted: false,
            })
            .collect();
        Ok(ResolvedMedia {
            url: addresses[0].clone(),
            referer: format!("{WEB_BASE}/"),
            duration_secs: duration,
            quality: 0,
            encrypted: false,
            key_hex: String::new(),
            variants,
            danmaku_vid: vid.to_owned(),
        })
    }

    /// 网页公开轨：`/video/public/{vid}/360p.mp4`。
    ///
    /// 免签明文，覆盖每部剧前 `accessible_episode_cnt` 集（实测 3 集），
    /// 其余集 404。下发前先 `Range: bytes=0-1` 探测——把 404 地址交给播放器
    /// 的表现是**黑屏无错**，用户不知道发生了什么。
    fn resolve_public(&self, vid: &str) -> Result<ResolvedMedia, String> {
        let url = format!("{WEB_BASE}/video/public/{vid}/360p.mp4");
        drama_net::probe_playable(&url, WEB_REFERER).map_err(|e| e.to_string())?;
        Ok(ResolvedMedia {
            url,
            referer: WEB_REFERER.to_owned(),
            duration_secs: 0.0,
            quality: 360,
            encrypted: false,
            key_hex: String::new(),
            variants: Vec::new(),
            danmaku_vid: vid.to_owned(),
        })
    }

    /// App 签名取流：`video_model/v1`。
    fn resolve_app(&self, vid: &str) -> Result<ResolvedMedia, String> {
        let body = serde_json::json!({
            "video_id": vid,
            "content_type": 1,
            "biz_param": {
                "need_all_video_definition": true,
                "video_platform": 3,
            },
        });
        let request = crate::app_api::build_request(true, "/novel/player/video_model/v1/", &[], Some(&body))?;
        let spec = drama_net::RequestSpec::post(request.url, SOURCE_ID)
            .headers_vec(request.headers)
            .body(request.body.unwrap_or_default());
        let value = drama_net::fetch_json_custom(spec).map_err(|e| e.to_string())?;
        crate::app_api::check_app_code(&value)?;

        let model = value
            .get("data")
            .and_then(|d| d.get("video_model"))
            .cloned()
            .ok_or_else(|| "红果 App 播放信息格式异常".to_owned())?;
        let model = match model {
            Value::Object(_) => model,
            Value::String(s) => serde_json::from_str(&s)
                .map_err(|_| "红果 App 播放信息格式异常".to_owned())?,
            _ => return Err("红果 App 播放信息格式异常".to_owned()),
        };
        parse_app_video_model(&model, vid)
    }
}

/// 解析 `video_model`：逐条评估画质/编码，选出最优并保留全部候选。
///
/// 评分 = 高度×10，H.264 同高度下 +1（同清晰度优先选兼容性更好的编码）。
/// `bytevc2`（H.266）直接跳过——播放器普遍不支持，选了就是黑屏。
pub fn parse_app_video_model(model: &Value, vid: &str) -> Result<ResolvedMedia, String> {
    let duration = model
        .get("video_duration")
        .or_else(|| model.get("duration"))
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<f64>().ok())
        .or_else(|| {
            model
                .get("video_duration")
                .or_else(|| model.get("duration"))
                .and_then(Value::as_f64)
        })
        .unwrap_or(0.0);

    let rows = match model.get("video_list") {
        Some(Value::Array(list)) => list.clone(),
        Some(Value::Object(map)) => {
            // 对象形态：key 是档位名，值是元数据。按键名升序遍历保证确定性。
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            keys.iter().map(|k| map[*k].clone()).collect()
        }
        _ => Vec::new(),
    };

    let mut choices: Vec<(ResolvedMedia, i64)> = Vec::new();
    let mut key_error: Option<String> = None;

    for row in &rows {
        let meta = row.get("video_meta").cloned().unwrap_or(Value::Null);
        if crate::media::is_unsupported_codec(&meta, row) {
            continue;
        }
        let addresses = crate::media::media_addresses(row);
        if addresses.is_empty() {
            continue;
        }

        let encrypt_info = row.get("encrypt_info").cloned().unwrap_or(Value::Null);
        let (key_hex, encrypted) = if crate::media::is_encrypted(&encrypt_info) {
            let spade = encrypt_info
                .get("spade_a")
                .and_then(Value::as_str)
                .unwrap_or("");
            match crate::media::decode_content_key(spade) {
                Ok(key) => (
                    key.iter().map(|b| format!("{b:02x}")).collect::<String>(),
                    true,
                ),
                Err(e) => {
                    key_error = Some(e);
                    continue;
                }
            }
        } else {
            (String::new(), false)
        };

        let height = crate::media::quality_of(&meta);
        let score = crate::media::score_of(height, &meta);
        let variants: Vec<Variant> = addresses
            .iter()
            .map(|url| Variant {
                url: url.clone(),
                quality: height,
                encrypted,
            })
            .collect();
        let media = ResolvedMedia {
            url: addresses[0].clone(),
            referer: PLAYER_REFERER.to_owned(),
            duration_secs: duration,
            quality: height,
            encrypted,
            key_hex: key_hex.clone(),
            variants,
            danmaku_vid: vid.to_owned(),
        };
        choices.push((media, score));
    }

    if choices.is_empty() {
        return match key_error {
            Some(e) => Err(format!("红果 App 媒体密钥不可用: {e}")),
            None => Err("红果 App 未返回兼容的媒体，已跳过不支持的编码".to_owned()),
        };
    }

    // 评分降序；稳定排序保证同分时保持上游顺序。
    choices.sort_by_key(|(_, score)| std::cmp::Reverse(*score));
    let mut variants: Vec<Variant> = Vec::new();
    for (media, _) in &choices {
        for variant in &media.variants {
            variants.push(variant.clone());
        }
    }
    let mut best = choices.remove(0).0;
    best.variants = variants;
    Ok(best)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

impl SourceProvider for HongguoProvider {
    fn id(&self) -> &SourceId {
        static ID: once_cell::sync::Lazy<SourceId> =
            once_cell::sync::Lazy::new(|| SourceId::new(SOURCE_ID));
        &ID
    }

    fn name(&self) -> &str {
        "红果短剧"
    }

    fn kind(&self) -> SourceKind {
        SourceKind::Builtin
    }

    fn caps(&self) -> Caps {
        Caps::all()
    }

    fn descriptor(&self) -> SourceDescriptor {
        SourceDescriptor {
            id: SourceId::new(SOURCE_ID),
            name: "红果短剧".to_owned(),
            kind: SourceKind::Builtin,
            caps: Caps::all().to_json(),
            version: String::new(),
            author: "内置".to_owned(),
            enabled: true,
            base_url: WEB_BASE.to_owned(),
        }
    }

    fn categories(&self) -> drama_types::Result<Vec<(String, String)>> {
        let mut out = vec![("".to_owned(), "全部".to_owned())];
        out.extend(
            GENRES
                .iter()
                .map(|(key, _, name)| ((*key).to_owned(), (*name).to_owned())),
        );
        Ok(out)
    }

    fn catalog(&self, category: &str, page: u32) -> drama_types::Result<CatalogPage> {
        // 分类目录走**网页 SSR**：免签、稳定、分页清晰。
        // App 目录接口带会话游标，适合「整库拉取」这类后台任务，
        // 浏览场景没必要引入那套状态机。
        let route = if category.is_empty() {
            "real-drama"
        } else {
            GENRES
                .iter()
                .find(|(key, _, _)| *key == category)
                .map(|(_, _, _)| ssr_route_for(category))
                .ok_or_else(|| drama_types::DramaError::BadRequest("红果分类无效".to_owned()))?
        };
        let url = if page == 0 {
            format!("{WEB_BASE}/category/{route}")
        } else {
            format!("{WEB_BASE}/category/{route}?page={}", page + 1)
        };
        let html = drama_net::fetch_text_throttled(&url).map_err(map_error)?;
        let data = ssr::extract_router_data(&html).map_err(map_error)?;
        let parsed = ssr::parse_catalog(&data).map_err(map_error)?;
        let mut items = parsed.items;
        items.iter_mut().for_each(Self::absolutize);
        Ok(CatalogPage {
            items,
            has_more: parsed.has_more,
            warning: String::new(),
            local_search: false,
        })
    }

    fn recommend(&self) -> drama_types::Result<Vec<Drama>> {
        let html = drama_net::fetch_text_throttled(WEB_BASE).map_err(map_error)?;
        let data = ssr::extract_router_data(&html).map_err(map_error)?;
        let mut items = ssr::parse_recommend(&data).map_err(map_error)?;
        items.iter_mut().for_each(Self::absolutize);
        Ok(items)
    }

    fn ranking_boards(&self) -> drama_types::Result<Vec<RankingBoard>> {
        Ok(BOARDS
            .iter()
            .map(|(id, name, description, route)| RankingBoard {
                id: (*id).to_owned(),
                source: SourceId::new(SOURCE_ID),
                name: (*name).to_owned(),
                description: (*description).to_owned(),
                route: (*route).to_owned(),
            })
            .collect())
    }

    fn ranking(&self, board: &str, page: u32) -> drama_types::Result<RankingPage> {
        if !(1..=500).contains(&page) {
            return Err(drama_types::DramaError::BadRequest("榜单页码无效".to_owned()));
        }
        let board_def = BOARDS
            .iter()
            .find(|(id, _, _, _)| *id == board)
            .ok_or_else(|| drama_types::DramaError::NotFound(format!("榜单不存在: {board}")))?;
        let route = board_def.3;
        let url = if page == 1 {
            format!("{WEB_BASE}/rank/{route}")
        } else {
            format!("{WEB_BASE}/rank/{route}?page={page}")
        };
        let html = drama_net::fetch_text_throttled(&url).map_err(map_error)?;
        // 两条路：先试 loaderData（站点结构完整时最省事），
        // 失败则回落到渲染后的 DOM——实测榜单的 `content` 常是空对象，
        // 条目只存在于 HTML 里。
        let rows = match ssr::extract_router_data(&html)
            .map_err(|e| e.to_string())
            .and_then(|data| ssr::parse_ranking(&data, route, page).map_err(|e| e.to_string()))
        {
            Ok(rows) => rows,
            Err(_) => ssr::parse_ranking_html(&html, page).map_err(map_error)?,
        };

        let items = rows
            .iter()
            .map(|row| {
                let mut drama = ssr::ranking_row_to_drama(row);
                Self::absolutize(&mut drama);
                RankingItem {
                    rank: row.rank,
                    drama: drama.to_wire(),
                    metric: row.heat.clone(),
                }
            })
            .collect();
        Ok(RankingPage {
            board_id: board_def.0.to_owned(),
            page,
            items,
            has_more: rows.len() == 20,
            total_pages: None,
            updated_text: String::new(),
            fetched_at_ms: now_ms(),
            stale: false,
            warning: String::new(),
        })
    }

    fn search(&self, keyword: &str) -> drama_types::Result<SearchResult> {
        let keyword = normalize_keyword(keyword)
            .map_err(drama_types::DramaError::BadRequest)?;
        let url = format!(
            "{WEB_BASE}/search/{}",
            url::form_urlencoded::Serializer::new(String::new())
                .append_pair("kw", &keyword)
                .finish()
                .trim_start_matches("kw=")
                .to_owned()
        );
        let html = drama_net::fetch_text_throttled(&url).map_err(map_error)?;
        let data = ssr::extract_router_data(&html).map_err(map_error)?;
        let parsed = ssr::parse_search(&data, &keyword).map_err(map_error)?;
        let mut items = parsed.items;
        items.iter_mut().for_each(Self::absolutize);
        Ok(SearchResult {
            items,
            total: parsed.total,
            limited: false,
            warning: String::new(),
        })
    }

    fn suggest(&self, keyword: &str) -> drama_types::Result<Vec<String>> {
        let keyword = normalize_keyword(keyword)
            .map_err(drama_types::DramaError::BadRequest)?;
        let url = format!(
            "{WEB_BASE}/incent_resource/suggestion?app_id=8662&query={}&count=10",
            url::form_urlencoded::Serializer::new(String::new())
                .append_pair("kw", &keyword)
                .finish()
                .trim_start_matches("kw=")
                .to_owned()
        );
        let spec = drama_net::RequestSpec::get(url, SOURCE_ID)
            .header("Accept", "application/json")
            .header("Referer", format!("{WEB_BASE}/"));
        let value = drama_net::fetch_json_custom(spec).map_err(map_error)?;
        Ok(ssr::parse_suggest(&value, 10))
    }

    fn detail(&self, series_id: &str) -> drama_types::Result<DramaDetail> {
        if !crate::is_numeric_id(series_id) {
            return Err(drama_types::DramaError::BadRequest("红果剧集 ID 无效".to_owned()));
        }
        // 详情走**网页 SSR**：`/detail?series_id=`。
        // App 详情接口的 `video_detail/v1` 当前常返回空 body，作为后续降级补充。
        let url = format!(
            "{WEB_BASE}/detail?series_id={}",
            url::form_urlencoded::Serializer::new(String::new())
                .append_pair("id", series_id)
                .finish()
                .trim_start_matches("id=")
                .to_owned()
        );
        let html = drama_net::fetch_text_throttled(&url).map_err(map_error)?;
        let data = ssr::extract_router_data(&html).map_err(map_error)?;
        let parsed = ssr::parse_detail(&data, series_id).map_err(map_error)?;
        let mut detail = parsed.drama;
        Self::absolutize(&mut detail);
        Ok(DramaDetail {
            drama: detail,
            episodes: parsed.episodes,
            warning: String::new(),
        })
    }

    fn play(&self, request: PlayRequest) -> drama_types::Result<ResolvedMedia> {
        let vid = match &request.vid {
            Some(vid) if !vid.is_empty() => vid.clone(),
            _ => {
                // 没给 vid：先查详情拿分集列表。
                let detail = self.detail(&request.series_id)?;
                let episode = detail
                    .episodes
                    .iter()
                    .find(|e| e.index == request.episode)
                    .ok_or_else(|| drama_types::DramaError::NotFound("集数不存在".to_owned()))?;
                episode
                    .vid
                    .clone()
                    .ok_or_else(|| drama_types::DramaError::NotFound("分集缺少视频 ID".to_owned()))?
            }
        };
        if !crate::is_numeric_id(&vid) {
            return Err(drama_types::DramaError::BadRequest("红果视频 ID 无效".to_owned()));
        }

        // 缓存命中直接复用（预取 → 实际播放的常见路径）。
        if let Some(cached) = crate::media::cache_get(&vid, request.quality) {
            return Ok(cached);
        }

        let mut failures: Vec<String> = Vec::new();
        for track in crate::media::track_order() {
            let result = match track {
                crate::media::Track::App => self.resolve_app(&vid),
                crate::media::Track::Public => self.resolve_public(&vid),
                crate::media::Track::Web => self.resolve_web(&request.series_id, &vid),
            };
            match result {
                Ok(mut media) => {
                    crate::media::note_track_success(track);
                    // 公开轨固定 360p：不参与「要最高」的选择，但保留为候选。
                    if media.quality == 0
                        && request.quality > 0
                        && let Some(picked) =
                            ResolvedMedia::pick(&media.variants, request.quality).cloned()
                    {
                        media = media.with_variant(&picked);
                    }
                    crate::media::cache_put(&vid, request.quality, &media);
                    return Ok(media);
                }
                Err(e) => {
                    crate::media::note_track_failure(track);
                    failures.push(format!("{}取流失败：{e}", track_label(track)));
                }
            }
        }
        Err(drama_types::DramaError::Parse(failures.join("；")))
    }

    fn play_variant(
        &self,
        series_id: &str,
        vid: &str,
        quality: i64,
    ) -> drama_types::Result<ResolvedMedia> {
        let _ = series_id;
        crate::media::switch_quality(vid, quality)
            .ok_or(drama_types::DramaError::NotFound("该集没有可切换的清晰度记录".to_owned()))
    }

    fn preload(&self, request: PlayRequest) -> drama_types::Result<ResolvedMedia> {
        // 预取与 play 走同一条链（解析结果会进缓存），只是标记为后台优先级。
        self.play(request)
    }

    fn danmaku(
        &self,
        series_id: &str,
        vid: &str,
        start_ms: i64,
        end_ms: i64,
    ) -> drama_types::Result<DanmakuPage> {
        crate::danmaku::validate(series_id, vid, start_ms, end_ms)
            .map_err(|e| drama_types::DramaError::BadRequest(e.to_string()))?;

        if let Some(hit) = crate::danmaku::cache_get(series_id, vid, start_ms, end_ms) {
            if let Some(page) = hit.cached_page() {
                return Ok(page);
            }
            return Err(drama_types::DramaError::Parse(
                hit.cached_error().unwrap_or_else(|| "弹幕请求失败".to_owned()),
            ));
        }

        let body = crate::danmaku::request_body(series_id, vid, start_ms, end_ms);
        let nonce = crate::comment_sign::Nonce::random()
            .map_err(drama_types::DramaError::Internal)?;
        let path = format!("/novel/commentapi/comment/list/{vid}/v1/");
        // 注释签名需要 aid 参数参与 Ladon 计算。
        let request = crate::app_api::build_request(
            true,
            &path,
            &[("aid", "8662".to_owned())],
            Some(&body),
        )
        .map_err(drama_types::DramaError::Internal)?;
        let sig = crate::comment_sign::sign_comment_request(
            &request.raw_query,
            "8662",
            nonce,
            unix_secs(),
            unix_millis(),
        );
        let mut headers = request.headers;
        headers.extend([
            ("Comment-Source".to_owned(), "601".to_owned()),
            ("Server-Channel".to_owned(), "1000".to_owned()),
            ("X-Khronos".to_owned(), sig.khronos.clone()),
            ("X-Gorgon".to_owned(), sig.gorgon.clone()),
            ("X-SS-Req-Ticket".to_owned(), sig.ticket.clone()),
            ("X-SS-STUB".to_owned(), sig.stub.clone()),
            ("X-Argus".to_owned(), sig.argus.clone()),
            ("X-Ladon".to_owned(), sig.ladon.clone()),
        ]);

        let spec = drama_net::RequestSpec::post(request.url, SOURCE_ID)
            .headers_vec(headers)
            .body(request.body.unwrap_or_default());
        let result = match drama_net::fetch_json_custom(spec) {
            Ok(value) => match crate::danmaku::parse(&value, vid, start_ms, end_ms) {
                Ok(page) => Ok(page),
                Err(e) => Err(e.to_string()),
            },
            Err(e) => Err(e.to_string()),
        };
        crate::danmaku::cache_put(series_id, vid, start_ms, end_ms, &result);
        result.map_err(drama_types::DramaError::Parse)
    }
}

fn unix_secs() -> u32 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as u32)
        .unwrap_or(0)
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn track_label(track: crate::media::Track) -> &'static str {
    match track {
        crate::media::Track::App => "App",
        crate::media::Track::Public => "公开轨",
        crate::media::Track::Web => "网页",
    }
}

/// 分类 key → 站内路由。
fn ssr_route_for(category: &str) -> &'static str {
    match category {
        "short_play" => "real-drama",
        "comic_series" => "comic-drama",
        "ai_series" => "ai-drama",
        _ => "comic",
    }
}

/// 搜索词归一化：NFKC + 去空白 + 1..=80 字符 + 无控制字符。
///
/// 站点对超长词返回空结果，对控制字符返回 400；在这里拦住能给出明确文案。
fn normalize_keyword(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("请输入 1 至 80 个字符的搜索词".to_owned());
    }
    // NFKC 归一（全角转半角等）。
    let normalized = unicode_normalization(trimmed);
    if normalized.chars().count() > 80 {
        return Err("请输入 1 至 80 个字符的搜索词".to_owned());
    }
    if normalized.chars().any(char::is_control) {
        return Err("搜索词不能包含控制字符".to_owned());
    }
    Ok(normalized)
}

/// NFKC 归一化的最小实现：覆盖中文搜索最常见的全角/半角差异。
///
/// 完整的 NFKC 表太大；这里只处理实际会出现的兼容字符
/// （全角 ASCII、全角标点）。遇到其他字符原样保留——
/// 搜索是「尽力而为」的场景，漏一个罕见兼容字符不会让结果错误。
fn unicode_normalization(input: &str) -> String {
    input
        .chars()
        .map(|c| {
            let code = c as u32;
            // 全角 ASCII（U+FF01..U+FF5E）→ 半角。
            if (0xFF01..=0xFF5E).contains(&code) {
                return char::from_u32(code - 0xFEE0).unwrap_or(c);
            }
            // 全角空格 → 半角空格。
            if code == 0x3000 {
                return ' ';
            }
            c
        })
        .collect()
}

fn map_error(e: impl std::fmt::Display) -> drama_types::DramaError {
    drama_types::DramaError::Parse(e.to_string())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod live_tests {
    use super::*;

    /// 实网：目录页可解析。默认忽略（CI 无外网时不应失败）。
    #[test]
    #[ignore = "requires network"]
    fn live_catalog_parses() {
        let provider = HongguoProvider::new();
        let page = provider.catalog("short_play", 0).expect("catalog");
        assert!(!page.items.is_empty(), "catalog should return items");
        let first = &page.items[0];
        assert!(!first.id.source_id.is_empty());
        assert!(!first.title.is_empty());
    }

    #[test]
    #[ignore = "requires network"]
    fn live_search_parses() {
        let provider = HongguoProvider::new();
        let result = provider.search("都市").expect("search");
        assert!(!result.items.is_empty(), "search should return items");
    }

    #[test]
    #[ignore = "requires network"]
    fn live_suggest_parses() {
        let provider = HongguoProvider::new();
        let items = provider.suggest("都市").expect("suggest");
        assert!(!items.is_empty(), "suggest should return items");
    }
}

    #[test]
    #[ignore = "requires network"]
    fn live_detail_and_play_chain() {
        let provider = HongguoProvider::new();
        // 从目录取一个真实 id。
        let page = provider.catalog("short_play", 0).expect("catalog");
        let target = &page.items[0];
        let detail = provider.detail(&target.id.source_id).expect("detail");
        assert!(!detail.episodes.is_empty(), "detail should have episodes");

        // 试看集应能解析出播放地址（前 accessible_episodes 集）。
        let accessible = detail
            .drama
            .accessible_episodes
            .max(1)
            .min(detail.episodes.len() as u32);
        let request = PlayRequest {
            series_id: target.id.source_id.clone(),
            episode: 1,
            vid: detail.episodes[0].vid.clone(),
            quality: 0,
        };
        let media = provider.play(request).expect("play");
        assert!(!media.url.is_empty(), "play should resolve a URL");
        println!(
            "detail ok: episodes={} accessible={accessible} play track url host={}",
            detail.episodes.len(),
            url::Url::parse(&media.url).map(|u| u.host_str().unwrap_or("").to_owned()).unwrap_or_default()
        );
    }
