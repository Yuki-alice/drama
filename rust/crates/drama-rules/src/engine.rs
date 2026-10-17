//! 规则执行引擎：把声明式清单跑起来。
//!
//! ## 管线
//!
//! ```text
//! 变量上下文 → 模板渲染 → 鉴权步骤 → HTTP 请求 → 响应解析
//!   → 条目提取 → 字段映射+过滤器 → 领域模型
//! ```
//!
//! ## 与内置源的关系
//!
//! [`RuleEngine`] 实现 [`drama_types::SourceProvider`]，因此对 engine 层
//! 完全透明——调度器不区分「内置红果」和「规则装的伍果」。

use std::collections::BTreeMap;

use scraper::Html;

use drama_types::{
    CatalogPage, Drama, DramaDetail, DramaError, DramaStatus, Episode, ResolvedMedia, SearchResult,
    SourceDescriptor, SourceId, SourceKind, SourceProvider, Variant, VipState,
};

use crate::extract;
use crate::manifest::{Auth, HashAlgo, Manifest, Method, Operation, Pagination, RequestSpec};

/// manifest 能力位 → wire 能力位。
fn to_wire_caps(caps: crate::manifest::Caps) -> drama_types::Caps {
    drama_types::Caps {
        catalog: caps.catalog,
        search: caps.search,
        suggest: caps.suggest,
        recommend: false,
        ranking: caps.ranking,
        detail: caps.detail,
        playback: caps.playback,
        danmaku: caps.danmaku,
        encrypted_media: false,
    }
}
use crate::template;
use crate::transform;

/// 规则执行错误。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RuleError {
    #[error("模板变量缺失: {0}")]
    MissingVariable(String),
    #[error("请求构造失败: {0}")]
    Request(String),
    #[error("响应解析失败: {0}")]
    Parse(String),
    #[error("未找到条目: {0}")]
    NoItems(String),
    #[error("鉴权失败: {0}")]
    Auth(String),
    #[error("分页未前进")]
    StalledPagination,
}

impl From<RuleError> for DramaError {
    fn from(e: RuleError) -> Self {
        match e {
            RuleError::MissingVariable(_) | RuleError::Request(_) | RuleError::Auth(_) => {
                DramaError::BadRequest(e.to_string())
            }
            RuleError::Parse(_) | RuleError::NoItems(_) | RuleError::StalledPagination => {
                DramaError::Parse(e.to_string())
            }
        }
    }
}

/// 一个待映射的条目。
///
/// 三种上下文对应三类站源：
/// - `Json`：REST API 的一行记录；
/// - `Element`：HTML 列表里的一个卡片（**元素级取值**，MacCMS 主要形态）；
/// - `Document`：整篇文档（详情页只有一条记录，或裸文本页面）。
///
/// `Element` 持有**元素序列化后的小文档**而不是 `ElementRef`：
/// `ElementRef` 借用了整篇文档，跨函数返回值会因生命周期而不可用；
/// 每卡片几百字节的序列化开销，远小于为此把文档搬来搬去的复杂度。
#[derive(Debug, Clone)]
enum Item {
    Json(serde_json::Value),
    Element(Html),
    Document(Html),
}

/// 请求时注入的运行期变量。
#[derive(Debug, Clone, Default)]
pub struct RequestContext<'a> {
    pub page: u32,
    pub query: &'a str,
    pub id: &'a str,
    pub vid: &'a str,
    pub episode: u32,
    pub category: &'a str,
}

impl RequestContext<'_> {
    /// 展开成模板上下文（所有值都转成字符串）。
    pub fn vars(&self) -> Vec<(&str, String)> {
        vec![
            ("page", self.page.to_string()),
            ("query", self.query.to_owned()),
            ("id", self.id.to_owned()),
            ("vid", self.vid.to_owned()),
            ("episode", self.episode.to_string()),
            ("category", self.category.to_owned()),
        ]
    }
}

/// 规则引擎。
#[derive(Debug)]
pub struct RuleEngine {
    manifest: Manifest,
    source_id: SourceId,
    /// base 的解析结果（相对地址补全用）。
    base_url: url::Url,
    /// 登录 token 缓存：`(值, 过期时刻毫秒)`。
    token_cache: std::sync::Mutex<Option<(String, i64)>>,
    /// 跨请求 cookie（`cookie_jar: on` 时生效）。
    cookies: drama_net::CookieJar,
    /// 最近一次取流拿到的 cookie（交给网关去回源媒体）。
    media_cookies: std::sync::Mutex<Option<String>>,
}

impl RuleEngine {
    /// 从清单构建。
    pub fn new(manifest: Manifest) -> Result<Self, RuleError> {
        let base_url = url::Url::parse(&manifest.base)
            .map_err(|e| RuleError::Request(format!("base 地址无效: {e}")))?;
        Ok(RuleEngine {
            source_id: SourceId::new(manifest.id.clone()),
            manifest,
            base_url,
            token_cache: std::sync::Mutex::new(None),
            cookies: drama_net::CookieJar::new(),
            media_cookies: std::sync::Mutex::new(None),
        })
    }

    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// 取流时捕获到的 cookie（供网关回源时带上）。
    ///
    /// 只有声明了 `cookie_jar: on` 的源才有值；剧果的 CloudFront
    /// 签名就靠这条链路传给媒体请求。
    pub fn media_cookie(&self) -> Option<String> {
        self.media_cookies
            .lock()
            .expect("media cookies poisoned")
            .clone()
    }

    /// 渲染模板：静态变量 + 运行期变量 + base。
    fn render(&self, text: &str, ctx: &RequestContext<'_>) -> String {
        let runtime = ctx.vars();
        let mut vars: Vec<(&str, &str)> = vec![("base", self.manifest.base.as_str())];
        vars.extend(runtime.iter().map(|(k, v)| (*k, v.as_str())));
        template::render(text, &vars)
    }

    /// 执行鉴权步骤，返回需要追加的请求头。
    fn apply_auth(
        &self,
        extra_query: &mut Vec<(String, String)>,
    ) -> Result<Vec<(String, String)>, RuleError> {
        let mut headers = Vec::new();
        for step in &self.manifest.auth {
            match step {
                Auth::StaticHeaders { headers: map } => {
                    for (name, value) in map {
                        headers.push((
                            name.clone(),
                            template::render(value, &[("base", self.manifest.base.as_str())]),
                        ));
                    }
                }
                Auth::Sign {
                    algo,
                    template: tpl,
                    secret,
                    output,
                } => {
                    let rendered = self.render(tpl, &RequestContext::default());
                    let signed = hash_hex(*algo, format!("{rendered}{secret}").as_bytes());
                    match output {
                        crate::manifest::Output::Header(name) => {
                            headers.push((name.clone(), signed));
                        }
                        crate::manifest::Output::Query(name) => {
                            extra_query.push((name.clone(), signed));
                        }
                    }
                }
                Auth::Hmac { algo, key, data, output } => {
                    let key_bytes = self.render(key, &RequestContext::default()).into_bytes();
                    let data_bytes = self.render(data, &RequestContext::default()).into_bytes();
                    let signed = hmac_hex(*algo, &key_bytes, &data_bytes);
                    match output {
                        crate::manifest::Output::Header(name) => headers.push((name.clone(), signed)),
                        crate::manifest::Output::Query(name) => extra_query.push((name.clone(), signed)),
                    }
                }
                Auth::Login {
                    request,
                    extract: path,
                    cache_ttl_s,
                    header,
                } => {
                    let token = self.login_token(request, path, *cache_ttl_s)?;
                    headers.push((
                        header
                            .split(':')
                            .next()
                            .unwrap_or("Authorization")
                            .trim()
                            .to_owned(),
                        template::render(header, &[("token", token.as_str())]),
                    ));
                }
                Auth::Aes { .. } | Auth::Base64 { .. } | Auth::RuneMap { .. } | Auth::UriKey { .. } => {
                    // 响应侧变换在 `decode_response` 里处理；请求侧无事可做。
                }
            }
        }
        Ok(headers)
    }

    /// 登录并缓存 token。
    fn login_token(
        &self,
        request: &RequestSpec,
        path: &str,
        ttl_secs: u64,
    ) -> Result<String, RuleError> {
        {
            let guard = self.token_cache.lock().expect("token cache poisoned");
            if let Some((token, expires_ms)) = guard.as_ref()
                && *expires_ms > now_ms()
            {
                return Ok(token.clone());
            }
        }
        let url = self.render(&request.url, &RequestContext::default());
        let spec = build_spec(request, &url, Vec::new(), &self.manifest)
            .map_err(RuleError::Request)?;
        let value = drama_net::fetch_json_custom(spec).map_err(|e| RuleError::Auth(e.to_string()))?;
        let token = extract::json_string(&value, path)
            .ok_or_else(|| RuleError::Auth(format!("登录响应缺少 {path}")))?;
        *self.token_cache.lock().expect("token cache poisoned") =
            Some((token.clone(), now_ms() + ttl_secs as i64 * 1000));
        Ok(token)
    }

    /// 发起请求并返回解析后的 JSON（或 HTML 文本）。
    fn fetch(
        &self,
        spec: &RequestSpec,
        ctx: &RequestContext<'_>,
    ) -> Result<(String, String), RuleError> {
        let url = self.render(&spec.url, ctx);
        let mut extra_query = Vec::new();
        let auth_headers = self.apply_auth(&mut extra_query)?;
        let url = append_query(&url, &extra_query);
        let mut headers = auth_headers;
        // cookie 罐开启时：把已有 cookie 带上。
        if self.manifest.cookie_jar == crate::manifest::CookieJar::On
            && let Some(cookie) = self.cookies.header_value()
        {
            headers.push(("Cookie".to_owned(), cookie));
        }
        let out_spec = build_spec(spec, &url, headers, &self.manifest)
            .map_err(|e| RuleError::Request(e.to_string()))?;
        let response =
            drama_net::client::client().execute(out_spec).map_err(|e| RuleError::Request(e.to_string()))?;
        // 吸收新下发的 cookie。
        if self.manifest.cookie_jar == crate::manifest::CookieJar::On && !response.set_cookies.is_empty()
        {
            self.cookies.absorb(&response.set_cookies);
            // 取流请求的 cookie 要交给网关（媒体请求在另一条链上）。
            if let Some(cookie) = self.cookies.header_value() {
                *self.media_cookies.lock().expect("media cookies poisoned") = Some(cookie);
            }
        }
        Ok((response.text(), response.content_type))
    }

    /// 从响应提取条目列表。
    ///
    /// 返回 [`Item`] 而不是裸 `Value`：HTML 源的字段必须**在元素上下文里**取值
    /// （同一个 `.title` 选择器在每个卡片里指向不同文字），
    /// 只传一个 JSON 值做不到这件事。
    fn extract_items(&self, op: &Operation, body: &str) -> Result<Vec<Item>, RuleError> {
        // `items` 为空 = 整个响应就是单条（detail 常见形态）。
        if op.items.is_empty() {
            // 详情页可能是 JSON 也可能是 HTML：按首个非空白字符判断。
            if body.trim_start().starts_with('{') || body.trim_start().starts_with('[') {
                let value: serde_json::Value = serde_json::from_str(body)
                    .map_err(|e| RuleError::Parse(format!("响应不是有效 JSON: {e}")))?;
                return Ok(vec![Item::Json(value)]);
            }
            return Ok(vec![Item::Document(Html::parse_document(body))]);
        }
        if op.items.starts_with("css:") || op.items.starts_with("html:") {
            let document = Html::parse_document(body);
            let elements = extract::items_from_html(&document, &op.items)
                .map_err(|e| RuleError::Parse(e.to_string()))?;
            // 每个元素单独序列化成小文档：后续字段取值都在自己的卡片里找，
            // 不会误取到隔壁卡片的标题。
            return Ok(elements
                .into_iter()
                .map(|element| Item::Element(Html::parse_fragment(&element.html())))
                .collect());
        }
        let value: serde_json::Value = serde_json::from_str(body)
            .map_err(|e| RuleError::Parse(format!("响应不是有效 JSON: {e}")))?;
        let items = extract::json_array(&value, &op.items)
            .ok_or_else(|| RuleError::NoItems(op.items.clone()))?;
        Ok(items.iter().cloned().map(Item::Json).collect())
    }

    /// 字段映射：条目 → Drama。
    ///
    /// `from` 表达式的两种语义：
    /// - 元素/文档上下文（HTML 源）：无 `@` 时按 CSS 选择器取文本，
    ///   `sel@attr` 取属性，`regex(...)` 取正则组；
    /// - JSON 上下文：点路径，支持 `|` 别名回退。
    fn map_drama(
        &self,
        op: &Operation,
        item: &Item,
        ctx: &RequestContext<'_>,
    ) -> Result<Drama, RuleError> {
        let get = |expr: &str| -> Option<String> {
            // `{{id}}` 这类模板：详情页的 id 就是请求参数，不在响应里。
            // 渲染后若不再含 `{{`，说明它是纯模板，直接返回渲染结果。
            if expr.contains("{{") {
                let rendered = self.render(expr, ctx);
                if !rendered.contains("{{") {
                    return Some(rendered);
                }
            }
            match item {
                Item::Json(value) => extract::value_from_json(value, expr),
                Item::Element(document) | Item::Document(document) => {
                    extract::value_from_document(document, expr, Some(&self.base_url))
                }
            }
        };
        let field = |name: &str| -> String {
            op.map
                .get(name)
                .and_then(|map| {
                    get(&map.from).map(|raw| {
                        transform::apply_chain(&raw, &map.filters, Some(&self.base_url))
                            .unwrap_or_default()
                    })
                })
                .or_else(|| op.map.get(name).map(|m| m.default.clone()))
                .unwrap_or_default()
        };

        let source_id = field("id");
        if source_id.is_empty() {
            return Err(RuleError::NoItems("id 字段为空".to_owned()));
        }
        let episodes_text = field("episodes");
        let status_text = field("status");
        Ok(Drama {
            id: drama_types::DramaId::new(self.source_id.clone(), source_id),
            title: field("title"),
            cover: field("cover"),
            category_id: field("categoryId"),
            category_name: field("categoryName"),
            episode_count: episodes_text.parse().unwrap_or(0),
            accessible_episodes: 0,
            summary: field("summary"),
            tags: field("tags")
                .split('|')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect(),
            status: DramaStatus::from_series_status(Some(if status_text == "ongoing" { 1 } else { 0 })),
            vip: match field("vip").as_str() {
                "true" => VipState::Vip,
                "false" => VipState::Free,
                _ => VipState::Unknown,
            },
            metric: field("metric"),
        })
    }

    /// 提取分集列表（JSON 或 HTML）。
    fn extract_chapters(
        &self,
        chapters: &crate::manifest::ChapterSpec,
        body: &str,
    ) -> Result<Vec<Item>, RuleError> {
        if chapters.items.starts_with("css:") || chapters.items.starts_with("html:") {
            let document = Html::parse_document(body);
            let elements = extract::items_from_html(&document, &chapters.items)
                .map_err(|e| RuleError::Parse(e.to_string()))?;
            return Ok(elements
                .into_iter()
                .map(|element| Item::Element(Html::parse_fragment(&element.html())))
                .collect());
        }
        let value: serde_json::Value = serde_json::from_str(body)
            .map_err(|e| RuleError::Parse(format!("分集响应不是有效 JSON: {e}")))?;
        let rows = extract::json_array(&value, &chapters.items).ok_or_else(|| {
            RuleError::Parse(format!("分集列表 {} 不存在", chapters.items))
        })?;
        Ok(rows.iter().cloned().map(Item::Json).collect())
    }

    /// 判断分页是否还有下一页。
    fn has_more(&self, op: &Operation, body: &str, item_count: usize) -> Result<bool, RuleError> {
        match &op.pagination {
            Pagination::Page { size, .. } => Ok(item_count >= *size as usize),
            Pagination::Flag { path, invert } => {
                let value: serde_json::Value = serde_json::from_str(body)
                    .map_err(|e| RuleError::Parse(e.to_string()))?;
                let flag = extract::json_path(&value, path)
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                Ok(if *invert { !flag } else { flag })
            }
            Pagination::Cursor { .. } => {
                // 游标模式由调用方读取游标后判断。
                Ok(item_count > 0)
            }
            Pagination::Single => Ok(false),
        }
    }
}

impl SourceProvider for RuleEngine {
    fn id(&self) -> &SourceId {
        &self.source_id
    }

    fn name(&self) -> &str {
        &self.manifest.name
    }

    fn kind(&self) -> SourceKind {
        SourceKind::Rule
    }

    fn caps(&self) -> drama_types::Caps {
        to_wire_caps(self.manifest.effective_caps())
    }

    fn descriptor(&self) -> SourceDescriptor {
        SourceDescriptor {
            id: self.source_id.clone(),
            name: self.manifest.name.clone(),
            kind: SourceKind::Rule,
            caps: to_wire_caps(self.manifest.effective_caps()).to_json(),
            version: self.manifest.version.clone(),
            author: self.manifest.author.clone(),
            enabled: true,
            base_url: self.manifest.base.clone(),
        }
    }

    fn catalog(&self, category: &str, page: u32) -> drama_types::Result<CatalogPage> {
        let Some(op) = self.manifest.ops.catalog.clone() else {
            return Err(DramaError::Unsupported("catalog"));
        };
        let ctx = RequestContext {
            page: page + op.pagination_start(),
            query: "",
            id: "",
            vid: "",
            episode: 0,
            category,
        };
        let (body, _) = self.fetch(&op.request, &ctx)?;
        let items = self.extract_items(&op, &body)?;
        let mut dramas = Vec::with_capacity(items.len());
        for item in &items {
            match self.map_drama(&op, item, &ctx) {
                Ok(drama) => dramas.push(drama),
                // 单条失败不影响整页。
                Err(RuleError::NoItems(_)) => continue,
                Err(e) => return Err(e.into()),
            }
        }
        let has_more = self.has_more(&op, &body, dramas.len())?;
        Ok(CatalogPage {
            items: dramas,
            has_more,
            warning: String::new(),
            local_search: false,
        })
    }

    fn search(&self, keyword: &str) -> drama_types::Result<SearchResult> {
        let Some(op) = self.manifest.ops.search.clone() else {
            return Err(DramaError::Unsupported("search"));
        };
        let ctx = RequestContext {
            page: op.pagination_start(),
            query: keyword,
            id: "",
            vid: "",
            episode: 0,
            category: "",
        };
        let (body, _) = self.fetch(&op.request, &ctx)?;
        let items = self.extract_items(&op, &body)?;
        let mut dramas = Vec::with_capacity(items.len());
        for item in &items {
            match self.map_drama(&op, item, &ctx) {
                Ok(drama) => dramas.push(drama),
                Err(RuleError::NoItems(_)) => continue,
                Err(e) => return Err(e.into()),
            }
        }
        Ok(SearchResult {
            total: dramas.len(),
            items: dramas,
            limited: false,
            warning: String::new(),
        })
    }

    fn detail(&self, series_id: &str) -> drama_types::Result<DramaDetail> {
        let Some(op) = self.manifest.ops.detail.clone() else {
            return Err(DramaError::Unsupported("detail"));
        };
        let ctx = RequestContext {
            page: op.pagination_start(),
            query: "",
            id: series_id,
            vid: "",
            episode: 0,
            category: "",
        };
        let (body, _) = self.fetch(&op.request, &ctx)?;
        let items = self.extract_items(&op, &body)?;
        let item = items
            .first()
            .ok_or_else(|| DramaError::NotFound(format!("未找到剧集 {series_id}")))?;
        let mut drama = self.map_drama(&op, item, &ctx).map_err(DramaError::from)?;
        // 身份校验：站点在拿不到目标时会给「默认推荐」。
        if op.identity_check && drama.id.source_id != series_id {
            return Err(DramaError::Parse(format!(
                "详情返回的是 {}，与请求的 {series_id} 不符",
                drama.id.source_id
            )));
        }
        if drama.title.is_empty() {
            drama.title = series_id.to_owned();
        }

        // 分集。
        let chapters = op
            .chapters
            .as_ref()
            .ok_or(DramaError::Unsupported("detail.chapters"))?;
        // 分集同样支持 JSON 与 HTML（MacCMS 的分集是 `<a>` 列表）。
        let chapter_items = self.extract_chapters(chapters, &body)?;
        let episodes = chapter_items
            .iter()
            .enumerate()
            .map(|(index, item)| {
                let get = |spec: &crate::manifest::FieldSpec| -> Option<String> {
                    let expr = spec.from_expr();
                    if expr.is_empty() {
                        return None;
                    }
                    let raw = match item {
                        Item::Json(value) => extract::value_from_json(value, expr),
                        Item::Element(document) | Item::Document(document) => {
                            extract::value_from_document(document, expr, Some(&self.base_url))
                        }
                    }?;
                    // 分集字段同样应用过滤器（`re:` 常在 filters 里）。
                    let filters = spec.filters();
                    if filters.is_empty() {
                        Some(raw)
                    } else {
                        Some(
                            transform::apply_chain(&raw, filters, Some(&self.base_url))
                                .unwrap_or(raw),
                        )
                    }
                };
                let vid = get(&chapters.vid).unwrap_or_default();
                let url = get(&chapters.url).unwrap_or_default();
                let number = get(&chapters.index)
                    .and_then(|text| text.trim().parse::<u32>().ok())
                    .filter(|n| *n > 0)
                    .unwrap_or(index as u32 + 1);
                Episode {
                    index: number,
                    title: if chapters.title_template.is_empty() {
                        format!("第{number}集")
                    } else {
                        template::render(
                            &chapters.title_template,
                            &[("index", number.to_string().as_str())],
                        )
                    },
                    vid: if vid.is_empty() { None } else { Some(vid) },
                    duration_seconds: 0,
                    locked: false,
                    url,
                }
            })
            .collect();
        Ok(DramaDetail {
            drama,
            episodes,
            warning: String::new(),
        })
    }

    fn play(&self, request: drama_types::PlayRequest) -> drama_types::Result<ResolvedMedia> {
        let playback = self
            .manifest
            .ops
            .playback
            .as_ref()
            .ok_or(DramaError::Unsupported("playback"))?;
        let spec = playback
            .request
            .as_ref()
            .ok_or(DramaError::Unsupported("playback.request"))?;
        let ctx = RequestContext {
            page: 1,
            query: "",
            id: &request.series_id,
            vid: request.vid.as_deref().unwrap_or(""),
            episode: request.episode,
            category: "",
        };
        let (body, _) = self.fetch(spec, &ctx)?;

        // 取流响应可能是 JSON，也可能是 HTML（Mplayer/player_aaaa 嵌在页面里）。
        // 按内容判断而不是按配置猜——站点经常两种都返回。
        let trimmed = body.trim_start();
        let (value, document) = if trimmed.starts_with('{') || trimmed.starts_with('[') {
            let value: serde_json::Value = serde_json::from_str(&body)
                .map_err(|e| DramaError::Parse(format!("取流响应不是有效 JSON: {e}")))?;
            (Some(value), None)
        } else {
            (None, Some(Html::parse_document(&body)))
        };

        // `extract` 支持三种写法：JSON 点路径 / `re:` 正则 / `css:` 选择器。
        let url = match &playback.extract {
            Some(crate::manifest::Extract::Json { path }) => match (&value, &document) {
                (Some(value), _) => extract::json_string(value, path),
                (None, Some(document)) => {
                    extract::value_from_document(document, path, Some(&self.base_url))
                }
                _ => None,
            },
            Some(crate::manifest::Extract::Regex { pattern, group }) => {
                extract::value_from_document(
                    document.as_ref().unwrap_or(&Html::parse_document("")),
                    &format!("re:{pattern}:{group}"),
                    Some(&self.base_url),
                )
            }
            Some(crate::manifest::Extract::Html { css }) => document
                .as_ref()
                .and_then(|d| extract::value_from_document(d, &format!("css:{css}"), Some(&self.base_url))),
            Some(crate::manifest::Extract::HtmlAttr { css, attr }) => document.as_ref().and_then(|d| {
                extract::value_from_document(d, &format!("css:{css}@{attr}"), Some(&self.base_url))
            }),
            Some(crate::manifest::Extract::Text) => Some(body.clone()),
            None => return Err(DramaError::Unsupported("playback.extract")),
        }
        .ok_or_else(|| DramaError::Parse("取流地址不存在或格式已变化".to_owned()))?;

        // 清洗：站源常把地址嵌在 JS 字符串里（`https:\/\/…`）或带上尾随标点。
        let url = clean_media_url(&url);
        if !url.starts_with("http") {
            return Err(DramaError::Parse(format!(
                "取流地址不是 http(s): {}",
                truncate_for_message(&url)
            )));
        }

        let mut variants = Vec::new();
        if let Some(variants_spec) = &playback.variants
            && let Some(value) = &value
            && let Some(rows) = extract::json_array(value, &variants_spec.path)
        {
            for row in rows {
                let Some(variant_url) = extract::json_string(row, &variants_spec.url) else {
                    continue;
                };
                let quality = extract::json_int(row, &variants_spec.quality).unwrap_or(0);
                variants.push(Variant {
                    url: clean_media_url(&variant_url),
                    quality: quality.max(0),
                    encrypted: false,
                });
            }
        }
        if variants.is_empty() {
            variants.push(Variant {
                url: url.clone(),
                quality: 0,
                encrypted: false,
            });
        }

        Ok(ResolvedMedia {
            url,
            referer: if playback.referer.is_empty() {
                format!("{}/", self.manifest.base)
            } else {
                self.render(&playback.referer, &ctx)
            },
            duration_secs: 0.0,
            quality: 0,
            encrypted: false,
            key_hex: String::new(),
            variants,
            danmaku_vid: String::new(),
        })
    }
}

// ── 辅助 ────────────────────────────────────────────────────

/// 清洗媒体地址。
///
/// 真实站源里出现过的脏数据：
/// - `https:\\/\\/host\\/path`（JSON/JS 转义）；
/// - `https://…/index.m3u8,`（尾随逗号，正则贪婪匹配带出来的）；
/// - `"https://…"`（残留引号）；
/// - 前后空白。
///
/// 这些交给播放器就是「黑屏无错」，必须在这里清干净。
fn clean_media_url(raw: &str) -> String {
    let mut value = extract::unescape_js_string(raw.trim());
    value = value.trim().to_owned();
    // 去掉包裹的引号/反斜杠。
    value = value.trim_matches(|c| c == '"' || c == '\\').trim().to_owned();
    // 从第一个 `http` 起截断，丢掉前面可能的 `url":"` 之类残留。
    if let Some(start) = value.find("http") {
        value = value[start..].to_owned();
    }
    // 尾随标点。
    while value.ends_with([',', ';', ')', '"', '\'', '>', '}']) {
        value.pop();
    }
    value
}

/// 错误信息里截断长地址（避免把带签名的 URL 全打出来）。
fn truncate_for_message(value: &str) -> String {
    value.chars().take(120).collect()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn hash_hex(algo: HashAlgo, data: &[u8]) -> String {
    use sha2::Digest;
    match algo {
        HashAlgo::Md5 => md5::compute(data)
            .0
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
        HashAlgo::Sha1 => sha1::Sha1::digest(data)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
        HashAlgo::Sha256 => sha2::Sha256::digest(data)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
    }
}

fn hmac_hex(algo: HashAlgo, key: &[u8], data: &[u8]) -> String {
    let digest: Vec<u8> = match algo {
        // MD5-HMAC（RFC 2104），手写：sha2 crate 不含 MD5。
        HashAlgo::Md5 => hmac_md5(key, data).to_vec(),
        HashAlgo::Sha1 => hmac_sha256(key, data).to_vec(),
        HashAlgo::Sha256 => hmac_sha256(key, data).to_vec(),
    };
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// MD5-HMAC。
fn hmac_md5(key: &[u8], message: &[u8]) -> [u8; 16] {
    const BLOCK: usize = 64;
    let mut key_block = [0u8; BLOCK];
    if key.len() > BLOCK {
        key_block[..16].copy_from_slice(&md5::compute(key).0);
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }
    let mut inner_pad = [0x36u8; BLOCK];
    let mut outer_pad = [0x5cu8; BLOCK];
    for i in 0..BLOCK {
        inner_pad[i] ^= key_block[i];
        outer_pad[i] ^= key_block[i];
    }
    let mut inner = Vec::with_capacity(BLOCK + message.len());
    inner.extend_from_slice(&inner_pad);
    inner.extend_from_slice(message);
    let inner_digest = md5::compute(&inner);
    let mut outer = Vec::with_capacity(BLOCK + 16);
    outer.extend_from_slice(&outer_pad);
    outer.extend_from_slice(&inner_digest.0);
    md5::compute(&outer).0
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    const BLOCK: usize = 64;
    let mut key_block = [0u8; BLOCK];
    if key.len() > BLOCK {
        key_block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }
    let mut inner_pad = [0x36u8; BLOCK];
    let mut outer_pad = [0x5cu8; BLOCK];
    for i in 0..BLOCK {
        inner_pad[i] ^= key_block[i];
        outer_pad[i] ^= key_block[i];
    }
    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(message);
    let inner_digest = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner_digest);
    let mut out = [0u8; 32];
    out.copy_from_slice(&outer.finalize());
    out
}

/// 在 URL 后追加 query（保留已有的）。
fn append_query(url: &str, extra: &[(String, String)]) -> String {
    if extra.is_empty() {
        return url.to_owned();
    }
    let encoded: Vec<String> = extra
        .iter()
        .map(|(k, v)| {
            url::form_urlencoded::Serializer::new(String::new())
                .append_pair(k, v)
                .finish()
        })
        .collect();
    let separator = if url.contains('?') { "&" } else { "?" };
    format!("{url}{separator}{}", encoded.join("&"))
}

/// 构造 drama-net 请求。
fn build_spec(
    spec: &RequestSpec,
    url: &str,
    extra_headers: Vec<(String, String)>,
    manifest: &Manifest,
) -> Result<drama_net::RequestSpec, String> {
    let mut headers = Vec::new();
    // 清单级默认头。
    for (name, value) in &manifest.headers {
        headers.push((
            name.clone(),
            template::render(value, &[("base", manifest.base.as_str())]),
        ));
    }
    headers.extend(extra_headers);
    // UA 由清单决定（未显式给 User-Agent 时注入）。
    if !headers.iter().any(|(k, _)| k.eq_ignore_ascii_case("user-agent")) {
        headers.push(("User-Agent".to_owned(), manifest.user_agent.value().to_owned()));
    }
    headers.push(("Referer".to_owned(), format!("{}/", manifest.base)));

    let timeout = std::time::Duration::from_millis(spec.timeout_ms);
    let base = match spec.method {
        Method::Get => drama_net::RequestSpec::get(url, manifest.id.clone()),
        Method::Post => drama_net::RequestSpec::post(url, manifest.id.clone()),
    };
    // 有 body 就必须有 Content-Type：很多站（剧果就是）对缺失的请求
    // 直接返回 415，而报错信息里看不出是 header 的问题。
    if let Some(body) = &spec.body
        && !headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("content-type"))
    {
        let content_type = if body.trim_start().starts_with('{')
            || body.trim_start().starts_with('[')
        {
            "application/json"
        } else {
            "application/x-www-form-urlencoded"
        };
        headers.push(("Content-Type".to_owned(), content_type.to_owned()));
    }
    let mut out = base.headers_vec(headers).timeout(timeout);
    if let Some(body) = &spec.body {
        out = out.body(template::render(body, &[("base", manifest.base.as_str())]).into_bytes());
    }
    Ok(out)
}

/// 分页起始页（清单里配置）。
trait PaginationStart {
    fn pagination_start(&self) -> u32;
}

impl PaginationStart for Operation {
    fn pagination_start(&self) -> u32 {
        match &self.pagination {
            Pagination::Page { start, .. } => *start,
            _ => 1,
        }
    }
}

/// 字段映射的便捷构造（测试用）。
#[allow(dead_code)]
fn field_map(from: &str, filters: &[&str]) -> crate::manifest::FieldMap {
    crate::manifest::FieldMap {
        from: from.to_owned(),
        filters: filters.iter().map(|s| s.to_string()).collect(),
        default: String::new(),
    }
}

/// 请求头构造的便捷形式（测试用）。
#[allow(dead_code)]
fn headers_map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    const YAML: &str = r#"
schema: 1
id: testsrc
name: 测试源
version: 1.0.0
author: tester
base: {BASE}
headers:
  X-Extra: "1"
ops:
  catalog:
    request:
      url: "{{base}}/catalog?page={{page}}"
    items: "data.list"
    map:
      id:
        from: "vid"
      title:
        from: "title"
      cover:
        from: "cover"
        filters: ["absolutize"]
      episodes:
        from: "count"
      summary:
        from: "desc"
      tags:
        from: "tags"
        filters: ["split_tags:,"]
      status:
        from: "status"
    pagination:
      type: page
      size: 2
  search:
    request:
      url: "{{base}}/search?kw={{query}}"
    items: "data.list"
    map:
      id:
        from: "vid"
      title:
        from: "title"
  detail:
    request:
      url: "{{base}}/detail?id={{id}}"
    identity_check: true
    map:
      id:
        from: "id"
      title:
        from: "title"
    chapters:
      items: "data.episodes"
      index: "no"
      vid: "vid"
      title_template: "第{{index}}集"
"#;

    fn catalog_page(ids: &[&str]) -> String {
        let list: Vec<String> = ids
            .iter()
            .map(|id| {
                serde_json::json!({
                    "vid": id,
                    "title": format!("剧 {id}"),
                    "cover": "/img/x.jpg",
                    "count": 12,
                    "desc": "简介",
                    "tags": "都市,甜宠",
                    "status": "ongoing"
                })
                .to_string()
            })
            .collect();
        let joined = list.join(",");
        format!(r#"{{"data":{{"list":[{joined}]}}}}"#)
    }

    /// 起一个本地 HTTP 服务器，返回注册的路由响应。
    fn spawn_server(
        routes: std::collections::HashMap<String, String>,
    ) -> (String, std::sync::Arc<std::sync::atomic::AtomicBool>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let done_clone = done.clone();
        let routes = std::sync::Arc::new(routes);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                if done_clone.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                let Ok(mut stream) = stream else { break };
                let mut buffer = [0u8; 4096];
                let Ok(n) = stream.read(&mut buffer) else { break };
                let request = String::from_utf8_lossy(&buffer[..n]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|l| l.split_whitespace().nth(1))
                    .unwrap_or("")
                    .to_owned();
                let body = routes
                    .get(&path)
                    .cloned()
                    .unwrap_or_else(|| r#"{"error":"not found"}"#.to_owned());
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
            }
        });
        (format!("http://{addr}"), done)
    }

    fn manifest_with(base: &str) -> Manifest {
        Manifest::from_yaml(&YAML.replace("{BASE}", base)).expect("load")
    }

    #[test]
    fn renders_templates_with_base_and_runtime() {
        let manifest = manifest_with("https://x.test");
        let engine = RuleEngine::new(manifest).expect("engine");
        let ctx = RequestContext {
            page: 2,
            query: "都市",
            id: "42",
            vid: "",
            episode: 1,
            category: "hot",
        };
        assert_eq!(
            engine.render("{{base}}/c/{{category}}?p={{page}}&q={{query}}&id={{id}}", &ctx),
            "https://x.test/c/hot?p=2&q=都市&id=42"
        );
    }

    #[test]
    fn hash_hex_algorithms() {
        assert_eq!(
            hash_hex(HashAlgo::Md5, b"hello"),
            "5d41402abc4b2a76b9719d911017c592"
        );
        assert_eq!(
            hash_hex(HashAlgo::Sha256, b"hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn hmac_sha256_matches_rfc_vector() {
        // RFC 4231 Test Case 2。
        assert_eq!(
            hmac_sha256(b"Jefe", b"what do ya want for nothing?"),
            [
                0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e, 0x6a, 0x04, 0x24, 0x26, 0x08, 0x95,
                0x75, 0xc7, 0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83, 0x9d, 0xec, 0x58, 0xb9,
                0x64, 0xec, 0x38, 0x43,
            ]
        );
    }

    #[test]
    fn hmac_md5_matches_known_vector() {
        // RFC 2202 Test Case 1：key = 0x0b*16, data = "Hi There"。
        let key = [0x0bu8; 16];
        let expected = "9294727a3638bb1c13f48ef8158bfc9d";
        assert_eq!(hmac_md5(&key, b"Hi There").iter().map(|b| format!("{b:02x}")).collect::<String>(), expected);
    }

    #[test]
    fn append_query_preserves_existing() {
        assert_eq!(
            append_query("https://x/a?b=1", &[("c".to_owned(), "2".to_owned())]),
            "https://x/a?b=1&c=2"
        );
        assert_eq!(
            append_query("https://x/a", &[("k".to_owned(), "v v".to_owned())]),
            "https://x/a?k=v+v"
        );
        assert_eq!(append_query("https://x/a", &[]), "https://x/a");
    }

    #[test]
    fn live_catalog_via_local_server() {
        let routes = std::collections::HashMap::from([
            (
                "/catalog?page=1".to_owned(),
                catalog_page(&["1", "2"]),
            ),
        ]);
        let (base, done) = spawn_server(routes);
        let engine = RuleEngine::new(manifest_with(&base)).expect("engine");
        let page = engine.catalog("", 0).expect("catalog");
        assert_eq!(page.items.len(), 2);
        // 分页 size=2，取满 2 条 → 认为还有更多。
        assert!(page.has_more);
        let first = &page.items[0];
        assert_eq!(first.title, "剧 1");
        assert_eq!(first.episode_count, 12);
        assert_eq!(first.tags, vec!["都市", "甜宠"]);
        // absolutize 把相对封面补全了。
        assert_eq!(first.cover, format!("{base}/img/x.jpg"));
        done.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    #[test]
    fn live_search_via_local_server() {
        let routes = std::collections::HashMap::from([
            (
                "/search?kw=%E9%83%BD%E5%B8%82".to_owned(),
                catalog_page(&["9"]),
            ),
        ]);
        let (base, done) = spawn_server(routes);
        let engine = RuleEngine::new(manifest_with(&base)).expect("engine");
        let result = engine.search("都市").expect("search");
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].id.source_id, "9");
        done.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    #[test]
    fn live_detail_via_local_server() {
        let detail = r#"{"id":"42","title":"测试剧","data":{"episodes":[
            {"no":1,"vid":"v1"},{"no":2,"vid":"v2"},{"no":3,"vid":"v3"}
        ]}}"#;
        let routes = std::collections::HashMap::from([
            ("/detail?id=42".to_owned(), detail.to_owned()),
        ]);
        let (base, done) = spawn_server(routes);
        let engine = RuleEngine::new(manifest_with(&base)).expect("engine");
        let detail = engine.detail("42").expect("detail");
        assert_eq!(detail.episodes.len(), 3);
        assert_eq!(detail.episodes[0].index, 1);
        assert_eq!(detail.episodes[0].vid.as_deref(), Some("v1"));
        assert_eq!(detail.episodes[2].title, "第3集");
        done.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    #[test]
    fn detail_identity_check_rejects_wrong_drama() {
        // 详情返回的 id 与请求不符 → 身份校验拒绝。
        let detail = r#"{"id":"999","title":"别的剧","data":{"episodes":[{"no":1,"vid":"v1"}]}}"#;
        let routes = std::collections::HashMap::from([
            ("/detail?id=42".to_owned(), detail.to_owned()),
        ]);
        let (base, done) = spawn_server(routes);
        let engine = RuleEngine::new(manifest_with(&base)).expect("engine");
        let err = engine.detail("42").unwrap_err();
        assert!(
            matches!(err, DramaError::Parse(_)),
            "got {err:?}"
        );
        done.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    #[test]
    fn unsupported_capability_is_an_error() {
        let manifest = manifest_with("https://x.test");
        let engine = RuleEngine::new(manifest).expect("engine");
        // 清单没有 playback → UNSUPPORTED。
        assert!(matches!(
            engine.play(drama_types::PlayRequest {
                series_id: "1".to_owned(),
                episode: 1,
                vid: None,
                quality: 0,
            }),
            Err(DramaError::Unsupported("playback"))
        ));
    }

    #[test]
    fn caps_reflect_manifest_ops() {
        let manifest = manifest_with("https://x.test");
        let engine = RuleEngine::new(manifest).expect("engine");
        let caps = drama_types::SourceProvider::caps(&engine);
        assert!(caps.catalog);
        assert!(caps.search);
        assert!(caps.detail);
        assert!(!caps.playback, "清单没有 playback");
    }

    #[test]
    fn empty_id_item_is_skipped() {
        let routes = std::collections::HashMap::from([
            (
                "/catalog?page=1".to_owned(),
                r#"{"data":{"list":[{"vid":"","title":"无 id"},{"vid":"ok","title":"有 id"}]}}"#.to_owned(),
            ),
        ]);
        let (base, done) = spawn_server(routes);
        let engine = RuleEngine::new(manifest_with(&base)).expect("engine");
        let page = engine.catalog("", 0).expect("catalog");
        assert_eq!(page.items.len(), 1, "空 id 条目应被跳过");
        assert_eq!(page.items[0].id.source_id, "ok");
        done.store(true, std::sync::atomic::Ordering::Relaxed);
    }
}
