//! 引擎：源注册、op 调度、缓存策略、会话仲裁。
//!
//! ## 职责边界
//!
//! 这里是**唯一**知道全部源的地方。源不认识引擎（不能回头问），
//! 存储不认识源（只认 `DramaId`）。缓存 key、能力协商、取消仲裁都在此汇合。
//!
//! ## 仲裁（session/sequence）
//!
//! 首页会并发打 `catalog`/`recommend`/`ranking`。若共用一个 session，
//! 后发的会立刻把先发的判为「迟到」→ 首页随机空白。
//! 因此仲裁按 **session** 隔离：同 session 内新 sequence 取代旧的；
//! 不同 session 互不影响。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use once_cell::sync::Lazy;
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use drama_rules::{RuleEngine, SourceStore};
use drama_types::{
    Drama, DramaError, EpisodeGroups, Episode, PlayRequest, Request, Response, SourceDescriptor,
    SourceProvider, ok,
};

/// 内置红果源。
const BUILTIN: &str = "hongguo";

/// 读请求的在途登记。
#[derive(Debug)]
struct InFlight {
    sequence: u64,
    cancel: CancellationToken,
}

/// 会话仲裁表。
#[derive(Debug, Default)]
struct Arbitration {
    /// `session` → 在途请求。
    reads: HashMap<String, InFlight>,
}

/// 引擎。
#[derive(Debug)]
pub struct Engine {
    /// 红果内置源。
    builtin: drama_source_hongguo::HongguoProvider,
    /// 规则源仓库。
    store: &'static SourceStore,
    /// 规则源引擎缓存（id → 引擎）。
    rule_engines: Mutex<HashMap<String, Arc<RuleEngine>>>,
    arbitration: Mutex<Arbitration>,
    /// 自增序号（`sequence` 缺省时使用）。
    next_sequence: AtomicU64,
}

static ENGINE: Lazy<Engine> = Lazy::new(Engine::new_global);

/// 全局引擎。
pub fn global() -> &'static Engine {
    &ENGINE
}

impl Engine {
    fn new_global() -> Self {
        // 数据目录由 `init` op 注入；此处只挂源仓库（目录未定时退化为内存）。
        if let Some(dirs) = drama_store::data_dirs() {
            drama_rules::store::global_store().attach(dirs.sources_dir());
            drama_store::cache::global().attach(dirs.catalog_file());
            drama_store::library::global().attach(dirs.library_file());
        }
        // 下载器通过回调拿取流能力（避免 download → source 的依赖环）。
        drama_download::engine::set_resolver(Box::new(resolve_for_download));
        Engine {
            builtin: drama_source_hongguo::HongguoProvider::new(),
            store: drama_rules::store::global_store(),
            rule_engines: Mutex::new(HashMap::new()),
            arbitration: Mutex::new(Arbitration::default()),
            next_sequence: AtomicU64::new(1),
        }
    }

    /// 数据目录切换后重新挂载（`init` op）。
    pub fn reattach(&self) {
        if let Some(dirs) = drama_store::data_dirs() {
            dirs.ensure().ok();
            drama_rules::store::global_store().attach(dirs.sources_dir());
            drama_store::cache::global().attach(dirs.catalog_file());
            drama_store::library::global().attach(dirs.library_file());
            drama_store::settings::global().attach(dirs.settings_file());
        }
        // 规则源集合可能变了，清掉缓存。
        self.rule_engines
            .lock()
            .expect("rule engines poisoned")
            .clear();
    }

    /// 按 id 取源实现。
    fn provider(&self, source: Option<&str>) -> Result<Arc<dyn SourceProvider>, DramaError> {
        let key = source
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(BUILTIN);
        if key == BUILTIN {
            return Ok(Arc::new(self.builtin.clone()) as Arc<dyn SourceProvider>);
        }
        // 规则源：先查缓存。
        if let Some(engine) = self
            .rule_engines
            .lock()
            .expect("rule engines poisoned")
            .get(key)
        {
            return Ok(engine.clone() as Arc<dyn SourceProvider>);
        }
        // 未缓存：从仓库加载清单并构建。
        let manifest = self
            .store
            .manifest(key)
            .map_err(|_| DramaError::NotFound(format!("源 {key} 未安装")))?;
        let engine = RuleEngine::new(manifest).map_err(DramaError::from)?;
        let arc = Arc::new(engine);
        self.rule_engines
            .lock()
            .expect("rule engines poisoned")
            .insert(key.to_owned(), arc.clone());
        Ok(arc as Arc<dyn SourceProvider>)
    }

    /// 全部源描述（内置 + 已启用的规则源）。
    pub fn all_sources(&self) -> Vec<SourceDescriptor> {
        let mut out = vec![self.builtin.descriptor()];
        for record in self.store.list() {
            if !record.enabled {
                continue;
            }
            if let Ok(manifest) = self.store.manifest(&record.id)
                && let Ok(engine) = RuleEngine::new(manifest)
            {
                out.push(drama_types::SourceProvider::descriptor(&engine));
            }
        }
        out
    }

    /// 能力查询（`version` op 用）。
    pub fn caps_of(&self, source: Option<&str>) -> Result<Value, DramaError> {
        Ok(self.provider(source)?.caps().to_json())
    }

    /// 仲裁登记：同 session 更新的 sequence 取代旧的（旧的直接取消）。
    ///
    /// 返回 `Err(Canceled)` 表示该请求是迟到的（sequence 不比在途的新），
    /// 应直接丢弃——**不发网络请求**。
    fn begin_read(
        &self,
        session: Option<&str>,
        sequence: Option<u64>,
    ) -> Result<CancellationToken, DramaError> {
        let Some(session) = session else {
            // 无会话标识：不参与仲裁（兼容 ping/version）。
            return Ok(CancellationToken::new());
        };
        let sequence = sequence.unwrap_or_else(|| {
            self.next_sequence.fetch_add(1, Ordering::Relaxed)
        });
        let mut reads = self.arbitration.lock().expect("arbitration poisoned");
        // 清理已完成标记的陈旧条目。
        reads.reads.retain(|_, in_flight| !in_flight.cancel.is_cancelled());
        if let Some(existing) = reads.reads.get(session) {
            if existing.sequence >= sequence {
                // 迟到请求：直接丢弃。
                return Err(DramaError::Canceled);
            }
            existing.cancel.cancel();
        }
        let token = CancellationToken::new();
        reads.reads.insert(
            session.to_owned(),
            InFlight {
                sequence,
                cancel: token.clone(),
            },
        );
        Ok(token)
    }

    /// 结束在途登记。
    fn end_read(&self, session: Option<&str>) {
        let Some(session) = session else { return };
        self.arbitration
            .lock()
            .expect("arbitration poisoned")
            .reads
            .remove(session);
    }

    /// 取消同 session 的在途读请求。
    fn cancel_read(&self, session: &str, sequence: Option<u64>) -> usize {
        let reads = self.arbitration.lock().expect("arbitration poisoned");
        let mut canceled = 0usize;
        for (key, in_flight) in reads.reads.iter() {
            if key == session
                && sequence.is_none_or(|seq| in_flight.sequence <= seq)
                && !in_flight.cancel.is_cancelled()
            {
                in_flight.cancel.cancel();
                canceled += 1;
            }
        }
        canceled
    }

    /// 入口：处理一次请求信封。
    ///
    /// 任何情况下都返回合法 [`Response`]（不 panic、不返回半截 JSON）。
    pub fn dispatch(&self, input: &str) -> Response {
        let request = match Request::parse(input) {
            Ok(request) => request,
            Err(e) => return Response::err(&e),
        };
        // panic 兜底：源实现里的 bug 不能带崩 FFI 边界。
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.handle(&request)
        }));
        match result {
            Ok(response) => response,
            Err(_) => Response::err(&DramaError::Internal(
                "本地核心处理失败，请重试".to_owned(),
            )),
        }
    }

    /// 分发到具体 op。
    fn handle(&self, request: &Request) -> Response {
        match request.op.as_str() {
            // ── 引擎 / 诊断 ────────────────────────────────────
            "ping" => ok(Value::String("pong".to_owned())),
            "version" => self.op_version(),
            "ops" => ok(drama_types::ops_json()),
            "init" => self.op_init(request),
            "cancelRead" => self.op_cancel_read(request),
            "diagnostics" => self.op_diagnostics(),

            // ── 读类 ──────────────────────────────────────────
            "catalog" => self.op_read(request, |p, params| {
                let category = params.get("category").and_then(Value::as_str).unwrap_or("");
                let page = params.get("page").and_then(Value::as_u64).unwrap_or(0) as u32;
                p.catalog(category, page).map(|page| {
                    serde_json::to_value(CatalogWire::from(page)).unwrap_or_default()
                })
            }),
            "categories" => self.op_read(request, |p, _| {
                p.categories().map(|items| {
                    Value::Array(
                        items
                            .into_iter()
                            .map(|(id, name)| Value::String(format!("{id}\u{1}{name}")))
                            .collect(),
                    )
                })
            }),
            "recommend" => self.op_read(request, |p, _| {
                p.recommend().map(|items| {
                    Value::Array(items.iter().map(Drama::to_wire).collect())
                })
            }),
            "ranking" => self.op_read(request, |p, params| {
                let board = params.get("board").and_then(Value::as_str).unwrap_or("");
                let page = params.get("page").and_then(Value::as_u64).unwrap_or(1) as u32;
                p.ranking(board, page).map(|page| {
                    serde_json::to_value(&page).unwrap_or_default()
                })
            }),
            "rankingBoards" => self.op_ranking_boards(request),
            "search" => self.op_read(request, |p, params| {
                let keyword = params
                    .get("keyword")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .ok_or(DramaError::BadRequest("missing keyword".to_owned()))?;
                p.search(keyword).map(|result| {
                    serde_json::to_value(&result).unwrap_or_default()
                })
            }),
            "suggest" => self.op_read(request, |p, params| {
                let keyword = params
                    .get("keyword")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .ok_or(DramaError::BadRequest("missing keyword".to_owned()))?;
                p.suggest(keyword).map(|items| Value::Array(
                    items.into_iter().map(Value::String).collect(),
                ))
            }),
            "detail" => self.op_read(request, |p, params| {
                let id = params
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .ok_or(DramaError::BadRequest("missing id".to_owned()))?;
                p.detail(id).map(|detail| {
                    serde_json::json!({
                        "drama": detail.drama.to_wire(),
                        "episodes": detail.episodes.iter().map(Episode::to_wire).collect::<Vec<_>>(),
                    })
                })
            }),
            "episodeGroups" => self.op_episode_groups(request),
            "play" => self.op_read(request, |p, params| {
                let play_request = parse_play_request(params)?;
                p.play(play_request).map(|media| {
                    serde_json::to_value(&media).unwrap_or_default()
                })
            }),
            "preload" => self.op_read(request, |p, params| {
                let play_request = parse_play_request(params)?;
                p.preload(play_request).map(|media| {
                    serde_json::to_value(&media).unwrap_or_default()
                })
            }),
            "playQuality" => self.op_read(request, |p, params| {
                let id = str_param(params, "id").ok_or(DramaError::BadRequest("missing id".to_owned()))?;
                let vid = str_param(params, "vid").ok_or(DramaError::BadRequest("missing vid".to_owned()))?;
                let quality = params.get("quality").and_then(Value::as_i64).unwrap_or(0);
                p.play_variant(id, vid, quality).map(|media| {
                    serde_json::to_value(&media).unwrap_or_default()
                })
            }),
            "danmaku" => self.op_read(request, |p, params| {
                let series_id = str_param(params, "id").ok_or(DramaError::BadRequest("missing id".to_owned()))?;
                let vid = str_param(params, "vid").ok_or(DramaError::BadRequest("missing vid".to_owned()))?;
                let start = params.get("startMs").and_then(Value::as_i64).unwrap_or(0);
                let end = params.get("endMs").and_then(Value::as_i64).unwrap_or(30_000);
                p.danmaku(series_id, vid, start, end)
                    .map(|page| serde_json::to_value(&page).unwrap_or_default())
            }),

            // ── 追剧 / 进度 ────────────────────────────────────
            "followPut" => self.op_follow_put(request),
            "followDel" => self.op_follow_del(request),
            "followList" => self.op_follow_list(request),
            "historyPut" => self.op_history_put(request),
            "historyGet" => self.op_history_get(request),
            "historyClear" => self.op_history_clear(request),
            "searchHistoryPut" => self.op_search_put(request),
            "searchHistoryList" => self.op_search_list(request),
            "searchHistoryDel" => self.op_search_del(request),
            "searchHistoryClear" => self.op_search_clear(request),

            // ── 下载 ──────────────────────────────────────────
            "downloadStart" => download_result(drama_download::start(
                request.source.as_deref().unwrap_or(BUILTIN),
                &request.params,
            )),
            "downloadList" => download_result(drama_download::list()),
            "downloadPause" => download_result(drama_download::pause(&request.params)),
            "downloadRetry" => download_result(drama_download::retry(&request.params)),
            "downloadCancel" => download_result(drama_download::cancel(&request.params)),
            "downloadDelete" => download_result(drama_download::delete(&request.params)),
            "downloadSetConcurrency" => {
                download_result(drama_download::set_concurrency(&request.params))
            }
            "playFile" => download_result(drama_download::play_file(&request.params)),
            "playLocal" => download_result(drama_download::play_local(
                request.source.as_deref().unwrap_or(BUILTIN),
                &request.params,
            )),
            "moveDownloads" => download_result(drama_download::move_downloads(&request.params)),
            "storage" => self.op_storage(),

            // ── 缓存 ──────────────────────────────────────────
            "cacheClear" => store_io_result(drama_store::cache::global().clear()),
            "cacheFlush" => store_io_result(drama_store::cache::global().flush()),
            "cacheStats" => {
                let stats = drama_store::cache::global().stats();
                ok(serde_json::to_value(&stats).unwrap_or_default())
            }

            // ── 设置 ──────────────────────────────────────────
            "resourceSettings" => {
                let settings = drama_store::settings::global().resource();
                ok(serde_json::to_value(&settings).unwrap_or_default())
            }
            "saveResourceSettings" => self.op_save_settings(request),

            // ── 扩展源 ────────────────────────────────────────
            "sources" => self.op_sources(),
            "sourceInstall" => self.op_source_install(request),
            "sourceUninstall" => self.op_source_uninstall(request),
            "sourceEnable" => self.op_source_enable(request),
            "sourceValidate" => self.op_source_validate(request),

            _ => Response::err(&DramaError::Unsupported("unknown op")),
        }
    }

    // ── 引擎级 op ─────────────────────────────────────────────

    fn op_version(&self) -> Response {
        let sources: Vec<Value> = self
            .all_sources()
            .iter()
            .map(|s| serde_json::to_value(s).unwrap_or_default())
            .collect();
        ok(serde_json::json!({
            "version": env!("CARGO_PKG_VERSION"),
            "builtinSource": BUILTIN,
            "sources": sources,
        }))
    }

    fn op_init(&self, request: &Request) -> Response {
        match str_param(&request.params, "dataDir") {
            Some(data_dir) if !data_dir.is_empty() => {
                let download_dir = str_param(&request.params, "downloadDir").unwrap_or("");
                let dirs = drama_store::DataDirs::new(data_dir)
                    .with_download_dir(download_dir);
                if let Err(e) = dirs.ensure() {
                    return Response::err(&DramaError::Storage(e.to_string()));
                }
                drama_store::set_data_dirs(dirs);
                drama_source_hongguo::device::set_data_dir(
                    drama_store::data_dirs()
                        .map(|d| d.data_dir.clone())
                        .unwrap_or_default(),
                );
                self.reattach();
                ok(serde_json::json!({
                    "initialized": true,
                    "dataDir": data_dir,
                }))
            }
            _ => Response::err(&DramaError::BadRequest("missing dataDir".to_owned())),
        }
    }

    fn op_cancel_read(&self, request: &Request) -> Response {
        let Some(session) = str_param(&request.params, "session") else {
            return Response::err(&DramaError::BadRequest(
                "cancelRead requires {session, sequence}".to_owned(),
            ));
        };
        let sequence = request.params.get("sequence").and_then(Value::as_u64);
        ok(serde_json::json!({ "canceled": self.cancel_read(session, sequence) }))
    }

    fn op_diagnostics(&self) -> Response {
        let cache = drama_store::cache::global().stats();
        let sources = self.all_sources().len();
        let installed = self.store.list().len();
        ok(serde_json::json!({
            "cache": serde_json::to_value(&cache).unwrap_or_default(),
            "sourceCount": sources,
            "installedRuleSources": installed,
            "inFlightReads": self.arbitration.lock().expect("arbitration poisoned").reads.len(),
        }))
    }

    fn op_ranking_boards(&self, request: &Request) -> Response {
        // 汇总全部源的榜单板。
        let provider = match self.provider(request.source.as_deref()) {
            Ok(provider) => provider,
            Err(e) => return Response::err(&e),
        };
        match provider.ranking_boards() {
            Ok(boards) => ok(Value::Array(
                boards
                    .iter()
                    .map(|b| serde_json::to_value(b).unwrap_or_default())
                    .collect(),
            )),
            Err(e) => Response::err(&e),
        }
    }

    fn op_episode_groups(&self, request: &Request) -> Response {
        let Some(id) = str_param(&request.params, "id") else {
            return Response::err(&DramaError::BadRequest("missing id".to_owned()));
        };
        let group_size = request
            .params
            .get("groupSize")
            .and_then(Value::as_u64)
            .unwrap_or(drama_types::DEFAULT_GROUP_SIZE as u64)
            as u32;
        let provider = match self.provider(request.source.as_deref()) {
            Ok(provider) => provider,
            Err(e) => return Response::err(&e),
        };
        let detail = match provider.detail(id) {
            Ok(detail) => detail,
            Err(e) => return Response::err(&e),
        };
        let episodes: Vec<Value> = detail
            .episodes
            .iter()
            .map(Episode::to_wire)
            .collect();
        let groups = EpisodeGroups::build(episodes, group_size);
        ok(serde_json::to_value(&groups).unwrap_or_default())
    }

    // ── 读类通用包装（缓存 + 仲裁）──────────────────────────

    fn op_read<F>(&self, request: &Request, handler: F) -> Response
    where
        F: Fn(&dyn SourceProvider, &Value) -> Result<Value, DramaError> + Send + Sync + 'static,
    {
        // 能力协商：未声明的能力在进缓存前就拒绝。
        let op = request.op.clone();
        match self.provider(request.source.as_deref()) {
            Ok(provider) => {
                if let Some(allowed) = provider.caps().allows(&op)
                    && !allowed
                {
                    return Response::err(&DramaError::Unsupported("capability"));
                }
            }
            Err(e) => return Response::err(&e),
        }

        // 仲裁登记（迟到请求直接丢弃，不发网络）。
        let token = match self.begin_read(request.session.as_deref(), request.sequence) {
            Ok(token) => token,
            Err(e) => return Response::err(&e),
        };

        // 缓存查询。
        let cache = drama_store::cache::global();
        let cache_key = read_cache_key(request);
        if let Some(hit) = cache.get(&cache_key, drama_store::cache::TTL_CATALOG)
            && !hit.stale
        {
            self.end_read(request.session.as_deref());
            return ok(hit.value);
        }

        // 缓存未命中：并发去重。
        if !cache.begin_inflight(&cache_key) {
            cache.wait_inflight(&cache_key);
            if let Some(hit) = cache.get(&cache_key, drama_store::cache::TTL_CATALOG) {
                self.end_read(request.session.as_deref());
                return ok(hit.value);
            }
        }

        // 执行（带取消）。闭包里自取 provider + 参数，保证 Send。
        let op = request.op.clone();
        let source = request.source.clone();
        let params = request.params.clone();
        let handler = Arc::new(handler);
        let handler_for_task = handler.clone();
        let result = drama_net::block_on(async {
            tokio::select! {
                biased;
                _ = token.cancelled() => Err(DramaError::Canceled),
                out = tokio::task::spawn_blocking(move || {
                    match global().provider(source.as_deref()) {
                        Ok(provider) => handler_for_task(provider.as_ref(), &params),
                        Err(e) => Err(e),
                    }
                }) => out.unwrap_or_else(|e| {
                    let _ = &op;
                    Err(DramaError::Internal(e.to_string()))
                }),
            }
        });

        cache.end_inflight(&cache_key);
        self.end_read(request.session.as_deref());

        match result {
            Ok(value) => {
                cache.note_success(&cache_key);
                let source = request
                    .source
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .unwrap_or(BUILTIN);
                cache.put(&cache_key, source, value.clone());
                ok(value)
            }
            Err(e) if e.code() == drama_types::ErrorCode::Canceled => Response::err(&e),
            Err(e) => {
                cache.note_failure(&cache_key);
                // 失败回退旧值（≤24h）。
                if let Some(hit) = cache.get(&cache_key, drama_store::cache::TTL_FALLBACK) {
                    let mut stale = hit.value;
                    if let Some(map) = stale.as_object_mut() {
                        map.insert("stale".to_owned(), Value::Bool(true));
                    }
                    return ok(stale);
                }
                Response::err(&e)
            }
        }
    }

    // ── 追剧 / 进度 ───────────────────────────────────────────

    fn op_follow_put(&self, request: &Request) -> Response {
        let user = current_user(request);
        let Some(key) = str_param(&request.params, "id") else {
            return Response::err(&DramaError::BadRequest("missing id".to_owned()));
        };
        let follow = drama_store::Follow {
            drama_key: key.to_owned(),
            title: str_param(&request.params, "title").unwrap_or_default().to_owned(),
            cover: str_param(&request.params, "cover").unwrap_or_default().to_owned(),
            episode: request.params.get("episode").and_then(Value::as_u64).unwrap_or(0) as u32,
            position_secs: request.params.get("positionSecs").and_then(Value::as_u64).unwrap_or(0),
            duration_secs: request.params.get("durationSecs").and_then(Value::as_u64).unwrap_or(0),
            total_episode: request.params.get("totalEpisode").and_then(Value::as_u64).unwrap_or(0) as u32,
            known_episodes: request.params.get("knownEpisodes").and_then(Value::as_u64).unwrap_or(0) as u32,
            updated_at_ms: now_ms(),
        };
        store_result(
            drama_store::library::global()
                .follow_put(user, follow)
                .map(Value::Bool),
        )
    }

    fn op_follow_del(&self, request: &Request) -> Response {
        let user = current_user(request);
        match str_param(&request.params, "id") {
            Some(id) => store_result(
                drama_store::library::global()
                    .follow_del(user, id)
                    .map(Value::Bool),
            ),
            None => Response::err(&DramaError::BadRequest("missing id".to_owned())),
        }
    }

    fn op_follow_list(&self, request: &Request) -> Response {
        let user = current_user(request);
        let follows = drama_store::library::global().follow_list(user);
        ok(Value::Array(
            follows
                .iter()
                .map(|f| serde_json::to_value(f).unwrap_or_default())
                .collect(),
        ))
    }

    fn op_history_put(&self, request: &Request) -> Response {
        let user = current_user(request);
        let Some(key) = str_param(&request.params, "id") else {
            return Response::err(&DramaError::BadRequest("missing id".to_owned()));
        };
        let item = drama_store::HistoryItem {
            drama_key: key.to_owned(),
            title: str_param(&request.params, "title").unwrap_or_default().to_owned(),
            cover: str_param(&request.params, "cover").unwrap_or_default().to_owned(),
            episode: request.params.get("episode").and_then(Value::as_u64).unwrap_or(0) as u32,
            position_secs: request.params.get("positionSecs").and_then(Value::as_u64).unwrap_or(0),
            duration_secs: request.params.get("durationSecs").and_then(Value::as_u64).unwrap_or(0),
            total_episode: request.params.get("totalEpisode").and_then(Value::as_u64).unwrap_or(0) as u32,
            updated_at_ms: now_ms(),
        };
        store_result(drama_store::library::global().history_put(user, item).map(|_| Value::Null))
    }

    fn op_history_get(&self, request: &Request) -> Response {
        let user = current_user(request);
        let Some(id) = str_param(&request.params, "id") else {
            return Response::err(&DramaError::BadRequest("missing id".to_owned()));
        };
        match drama_store::library::global().history_get(user, id) {
            Some(item) => ok(serde_json::to_value(&item).unwrap_or_default()),
            None => ok(Value::Null),
        }
    }

    fn op_history_clear(&self, request: &Request) -> Response {
        store_result(
            drama_store::library::global()
                .history_clear(current_user(request))
                .map(|_| Value::Null),
        )
    }

    fn op_search_put(&self, request: &Request) -> Response {
        match str_param(&request.params, "keyword") {
            Some(keyword) => store_result(
                drama_store::library::global()
                    .search_put(current_user(request), keyword)
                    .map(|_| Value::Null),
            ),
            None => Response::err(&DramaError::BadRequest("missing keyword".to_owned())),
        }
    }

    fn op_search_list(&self, request: &Request) -> Response {
        ok(Value::Array(
            drama_store::library::global()
                .search_list(current_user(request))
                .into_iter()
                .map(Value::String)
                .collect(),
        ))
    }

    fn op_search_del(&self, request: &Request) -> Response {
        match str_param(&request.params, "keyword") {
            Some(keyword) => store_result(
                drama_store::library::global()
                    .search_del(current_user(request), keyword)
                    .map(Value::Bool),
            ),
            None => Response::err(&DramaError::BadRequest("missing keyword".to_owned())),
        }
    }

    fn op_search_clear(&self, request: &Request) -> Response {
        store_result(
            drama_store::library::global()
                .search_clear(current_user(request))
                .map(|_| Value::Null),
        )
    }

    // ── 设置 / 扩展源 ─────────────────────────────────────────

    fn op_save_settings(&self, request: &Request) -> Response {
        let Ok(settings) =
            serde_json::from_value::<drama_store::ResourceSettings>(request.params.clone())
        else {
            return Response::err(&DramaError::BadRequest("settings 格式无效".to_owned()));
        };
        match drama_store::settings::global().save_resource(settings) {
            Ok(()) => ok(Value::Bool(true)),
            Err(e) => Response::err(&DramaError::BadRequest(e.0)),
        }
    }

    /// 下载目录占用与剩余空间。
    fn op_storage(&self) -> Response {
        let Some(dir) = drama_download::download_dir() else {
            return Response::err(&DramaError::Storage("下载目录未初始化".to_owned()));
        };
        let mut bytes = 0u64;
        let mut files = 0u64;
        for entry in walkdir(&dir) {
            if let Ok(meta) = entry.metadata()
                && meta.is_file()
            {
                bytes += meta.len();
                files += 1;
            }
        }
        ok(serde_json::json!({
            "directory": dir.to_string_lossy(),
            "bytes": bytes,
            "files": files,
        }))
    }

    fn op_sources(&self) -> Response {
        ok(Value::Array(
            self.all_sources()
                .iter()
                .map(|s| serde_json::to_value(s).unwrap_or_default())
                .collect(),
        ))
    }

    fn op_source_install(&self, request: &Request) -> Response {
        let Some(text) = str_param(&request.params, "manifest") else {
            return Response::err(&DramaError::BadRequest("missing manifest".to_owned()));
        };
        let manifest = match drama_rules::Manifest::from_bytes(text.as_bytes()) {
            Ok(manifest) => manifest,
            Err(e) => return Response::err(&DramaError::RuleInvalid(e.to_string())),
        };
        let origin = str_param(&request.params, "origin").unwrap_or("local");
        match self.store.install(&manifest, origin) {
            Ok(record) => {
                self.rule_engines
                    .lock()
                    .expect("rule engines poisoned")
                    .remove(&record.id);
                ok(serde_json::to_value(&record).unwrap_or_default())
            }
            Err(e) => Response::err(&DramaError::RuleInvalid(e.to_string())),
        }
    }

    fn op_source_uninstall(&self, request: &Request) -> Response {
        match str_param(&request.params, "id") {
            Some(id) => match self.store.uninstall(id) {
                Ok(()) => {
                    self.rule_engines
                        .lock()
                        .expect("rule engines poisoned")
                        .remove(id);
                    ok(Value::Bool(true))
                }
                Err(e) => Response::err(&DramaError::RuleInvalid(e.to_string())),
            },
            None => Response::err(&DramaError::BadRequest("missing id".to_owned())),
        }
    }

    fn op_source_enable(&self, request: &Request) -> Response {
        let Some(id) = str_param(&request.params, "id") else {
            return Response::err(&DramaError::BadRequest("missing id".to_owned()));
        };
        let enabled = request.params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        match self.store.set_enabled(id, enabled) {
            Ok(()) => {
                self.rule_engines
                    .lock()
                    .expect("rule engines poisoned")
                    .remove(id);
                ok(Value::Bool(true))
            }
            Err(e) => Response::err(&DramaError::RuleInvalid(e.to_string())),
        }
    }

    fn op_source_validate(&self, request: &Request) -> Response {
        let Some(text) = str_param(&request.params, "manifest") else {
            return Response::err(&DramaError::BadRequest("missing manifest".to_owned()));
        };
        match drama_rules::Manifest::from_bytes(text.as_bytes()) {
            Ok(manifest) => {
                let errors = drama_rules::validate_default(&manifest);
                ok(serde_json::json!({
                    "valid": errors.is_empty(),
                    "errors": errors.iter().map(std::string::ToString::to_string).collect::<Vec<_>>(),
                    "contentHash": manifest.content_hash().unwrap_or_default(),
                }))
            }
            Err(e) => Response::err(&DramaError::RuleInvalid(e.to_string())),
        }
    }
}

/// 取流回调实现：engine 把「源解析」递给下载器。
///
/// 依赖方向：`engine → source` 与 `engine → download`，
/// 而 `download` 只认识这个函数指针，不认识源。
fn resolve_for_download(
    source: &str,
    series_id: &str,
    episode: u32,
    vid: &str,
    quality: i64,
) -> Result<drama_download::engine::ResolvedRef, DramaError> {
    let provider = global().provider(Some(source))?;
    let vid = if vid.is_empty() {
        let detail = provider.detail(series_id)?;
        detail
            .episodes
            .iter()
            .find(|e| e.index == episode)
            .and_then(|e| e.vid.clone())
            .filter(|v| !v.is_empty())
            .ok_or_else(|| DramaError::Parse("分集缺少视频 ID".to_owned()))?
    } else {
        vid.to_owned()
    };
    let media = provider.play(PlayRequest {
        series_id: series_id.to_owned(),
        episode,
        vid: Some(vid.clone()),
        quality,
    })?;
    Ok(drama_download::engine::ResolvedRef {
        vid,
        url: media.url,
        referer: media.referer,
        key_hex: media.key_hex,
        quality: media.quality,
    })
}

/// 下载结果包装。
fn download_result(result: Result<Value, DramaError>) -> Response {
    match result {
        Ok(value) => ok(value),
        Err(e) => Response::err(&e),
    }
}

/// 目录页的 wire 形态（`items` + `hasMore`）。
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct CatalogWire {
    items: Vec<Value>,
    has_more: bool,
}

impl From<drama_types::CatalogPage> for CatalogWire {
    fn from(page: drama_types::CatalogPage) -> Self {
        CatalogWire {
            items: page.items.iter().map(Drama::to_wire).collect(),
            has_more: page.has_more,
        }
    }
}

/// 取字符串参数。
fn str_param<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// 构造取流请求。
fn parse_play_request(params: &Value) -> Result<PlayRequest, DramaError> {
    let id = str_param(params, "id")
        .ok_or(DramaError::BadRequest("missing id".to_owned()))?;
    Ok(PlayRequest {
        series_id: id.to_owned(),
        episode: params.get("episode").and_then(Value::as_u64).unwrap_or(1) as u32,
        vid: str_param(params, "vid").map(str::to_owned),
        quality: params.get("quality").and_then(Value::as_i64).unwrap_or(0),
    })
}

/// 递归列出目录下的文件（上限 20 万条目，防病态目录卡死）。
fn walkdir(root: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if out.len() > 200_000 {
            break;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => stack.push(path),
                Ok(kind) if kind.is_file() => out.push(path),
                _ => {}
            }
        }
    }
    out
}

/// 单用户标识。
///
/// 本项目**不做多用户**（产品决定）：追剧/进度/搜索历史只有一个归属。
/// 仍保留这个常量而不是把 `user` 参数从存储层删掉，是因为存储层一旦
/// 去掉分区，将来想加就又要迁移一遍数据。
const SINGLE_USER: &str = "local";

/// 当前用户（固定单用户）。
fn current_user(_request: &Request) -> &str {
    SINGLE_USER
}

/// 存储结果包装（`()` / `WriteError` → wire）。
fn store_io_result(result: Result<(), drama_store::atomic::WriteError>) -> Response {
    match result {
        Ok(()) => ok(Value::Null),
        Err(e) => Response::err(&DramaError::Storage(e.to_string())),
    }
}

/// 存储结果包装。
fn store_result(result: Result<Value, String>) -> Response {
    match result {
        Ok(value) => ok(value),
        Err(e) => Response::err(&DramaError::Storage(e)),
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 读类 op 的缓存 key。
fn read_cache_key(request: &Request) -> String {
    let source = request
        .source
        .as_deref()
        .filter(|s| !s.is_empty())
        .unwrap_or(BUILTIN);
    let args = match request.op.as_str() {
        "catalog" => format!(
            ":{}:{}",
            request.params.get("category").and_then(Value::as_str).unwrap_or(""),
            request.params.get("page").and_then(Value::as_u64).unwrap_or(0)
        ),
        "search" | "suggest" => format!(
            ":{}",
            request.params.get("keyword").and_then(Value::as_str).unwrap_or("")
        ),
        "detail" | "episodeGroups" => format!(
            ":{}",
            request.params.get("id").and_then(Value::as_str).unwrap_or("")
        ),
        "ranking" => format!(
            ":{}:{}",
            request.params.get("board").and_then(Value::as_str).unwrap_or(""),
            request.params.get("page").and_then(Value::as_u64).unwrap_or(1)
        ),
        _ => String::new(),
    };
    format!("{source}:{}{args}", request.op)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 这些测试共享进程级全局（引擎、源仓库、缓存、库），必须串行。
    ///
    /// 并行跑会让「一个测试复位数据目录」与「另一个正在写」互相踩，
    /// 表现为随机的 `Invalid argument`（写到被删掉的目录）——
    /// 这类失败与代码无关，但会长期污染 CI。
    fn serial() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn dispatch(op: &str, params: Value) -> Value {
        let envelope = json!({"v": 1, "op": op, "params": params});
        let response = global().dispatch(&envelope.to_string());
        serde_json::to_value(&response).expect("response json")
    }

    fn dispatch_ok(op: &str, params: Value) -> Value {
        let value = dispatch(op, params);
        assert_eq!(value["ok"], true, "expected ok, got {value}");
        value["data"].clone()
    }

    fn dispatch_err(op: &str, params: Value) -> Value {
        let value = dispatch(op, params);
        assert_eq!(value["ok"], false, "expected error, got {value}");
        value["error"].clone()
    }

    #[test]
    fn ping_roundtrip() {
        assert_eq!(dispatch_ok("ping", json!({})), "pong");
    }

    #[test]
    fn wrong_version_is_rejected() {
        let envelope = json!({"v": 2, "op": "ping"});
        let response = global().dispatch(&envelope.to_string());
        assert!(!response.is_ok());
    }

    #[test]
    fn unknown_op_is_unsupported() {
        let error = dispatch_err("noSuchOp", json!({}));
        assert_eq!(error["code"], "UNSUPPORTED");
    }

    #[test]
    fn malformed_json_is_bad_request() {
        let response = global().dispatch("not json at all");
        assert!(!response.is_ok());
    }

    #[test]
    fn oversized_input_is_rejected() {
        let big = "x".repeat(drama_types::MAX_INPUT_BYTES + 1);
        let response = global().dispatch(&big);
        assert!(!response.is_ok());
    }

    #[test]
    fn ops_returns_contract_table() {
        let data = dispatch_ok("ops", json!({}));
        assert!(data.as_array().expect("array").len() >= 40);
        let names: Vec<&str> = data
            .as_array()
            .expect("array")
            .iter()
            .filter_map(|o| o["name"].as_str())
            .collect();
        assert!(names.contains(&"ping"));
        assert!(names.contains(&"catalog"));
        assert!(names.contains(&"sourceInstall"));
    }

    #[test]
    fn version_lists_builtin_source() {
        let _guard = serial();
        let data = dispatch_ok("version", json!({}));
        assert_eq!(data["builtinSource"], "hongguo");
        let sources = data["sources"].as_array().expect("sources");
        assert!(sources.iter().any(|s| s["id"] == "hongguo"));
    }

    #[test]
    fn init_requires_data_dir() {
        let error = dispatch_err("init", json!({}));
        assert_eq!(error["code"], "BAD_REQUEST");
    }

    #[test]
    fn init_with_temp_dir_succeeds() {
        let _guard = serial();
        let dir = std::env::temp_dir().join(format!("drama-engine-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let data = dispatch_ok(
            "init",
            json!({"dataDir": dir.to_string_lossy()}),
        );
        assert_eq!(data["initialized"], true);
        // 幂等。
        dispatch_ok("init", json!({"dataDir": dir.to_string_lossy()}));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unknown_source_is_not_found() {
        // 显式未知源：在能力协商前就拒绝（不发网络）。
        let envelope = json!({"v": 1, "op": "catalog", "source": "no-such", "params": {"page": 0}});
        let response = global().dispatch(&envelope.to_string());
        let value = serde_json::to_value(&response).expect("json");
        assert_eq!(value["error"]["code"], "NOT_FOUND");

        // 未注册的源在 detail 的能力协商前就 NOT_FOUND：
        // 用 detail 缺 id 的场景对照——BAD_REQUEST 说明已通过源解析。
        let error = dispatch_err("detail", json!({}));
        assert_eq!(error["code"], "BAD_REQUEST", "缺 id 应是参数错误");
    }

    #[test]
    fn catalog_requires_category_param_tolerated() {
        // category 缺省 = 全部。
        let data = dispatch_ok("catalog", json!({"page": 0}));
        assert!(data.is_object());
    }

    #[test]
    fn search_without_keyword_is_bad_request() {
        let error = dispatch_err("search", json!({}));
        assert_eq!(error["code"], "BAD_REQUEST");
    }

    #[test]
    fn detail_without_id_is_bad_request() {
        let error = dispatch_err("detail", json!({}));
        assert_eq!(error["code"], "BAD_REQUEST");
    }

    #[test]
    fn arbitration_supersedes_stale_sequence() {
        // 同 session 先发 sequence 2，再发 sequence 1 → 迟到直接 CANCELED。
        let token = global()
            .begin_read(Some("test:catalog"), Some(2))
            .expect("begin");
        let stale = global().begin_read(Some("test:catalog"), Some(1));
        assert!(matches!(stale, Err(DramaError::Canceled)));
        assert!(!token.is_cancelled());
        global().end_read(Some("test:catalog"));
    }

    #[test]
    fn arbitration_cancel_read_cancels_in_flight() {
        let token = global()
            .begin_read(Some("cancel:catalog"), Some(1))
            .expect("begin");
        assert!(!token.is_cancelled());
        let canceled = global().cancel_read("cancel:catalog", None);
        assert_eq!(canceled, 1);
        assert!(token.is_cancelled());
        global().end_read(Some("cancel:catalog"));
    }

    #[test]
    fn arbitration_is_session_scoped() {
        // 不同 session 互不影响——首页并发的三路请求不该互相取消。
        let token_a = global().begin_read(Some("scope-a:catalog"), Some(1)).expect("a");
        let token_b = global().begin_read(Some("scope-b:catalog"), Some(1)).expect("b");
        // b 的新请求**只取消 b**（同 session 新序取代旧序）。
        let _ = global().begin_read(Some("scope-b:catalog"), Some(2)).expect("b2");
        assert!(!token_a.is_cancelled(), "a 不应被 b 的新请求波及");
        assert!(token_b.is_cancelled(), "b 的新序应取消 b 的旧序");
        global().end_read(Some("scope-a:catalog"));
        global().end_read(Some("scope-b:catalog"));
    }

    #[test]
    fn follow_roundtrip_through_dispatch() {
        let _guard = serial();
        let data = dispatch_ok(
            "followPut",
            json!({"id": "hongguo:1", "title": "测试剧", "episode": 3}),
        );
        assert_eq!(data, true, "首次应是新增");
        let list = dispatch_ok("followList", json!({}));
        assert!(!list.as_array().expect("list").is_empty());
        dispatch_ok("followDel", json!({"id": "hongguo:1"}));
    }

    #[test]
    fn history_roundtrip_through_dispatch() {
        let _guard = serial();
        dispatch_ok(
            "historyPut",
            json!({"id": "hongguo:2", "title": "进度", "episode": 5,
                   "positionSecs": 30, "durationSecs": 120}),
        );
        let item = dispatch_ok("historyGet", json!({"id": "hongguo:2"}));
        assert_eq!(item["episode"], 5);
        dispatch_ok("historyClear", json!({}));
    }

    #[test]
    fn search_history_roundtrip() {
        let _guard = serial();
        dispatch_ok("searchHistoryPut", json!({"keyword": "都市"}));
        let list = dispatch_ok("searchHistoryList", json!({}));
        assert!(list.as_array().expect("list").contains(&json!("都市")));
        dispatch_ok("searchHistoryDel", json!({"keyword": "都市"}));
        assert!(dispatch_ok("searchHistoryList", json!({}))
            .as_array()
            .expect("list")
            .is_empty());
    }

    #[test]
    fn cache_stats_op() {
        let _guard = serial();
        let data = dispatch_ok("cacheStats", json!({}));
        assert!(data["entries"].is_u64());
    }

    #[test]
    fn settings_roundtrip() {
        let _guard = serial();
        let settings = dispatch_ok("resourceSettings", json!({}));
        assert_eq!(settings["proxyMode"], "auto");
        // 非法值被拒绝。
        let error = dispatch_err(
            "saveResourceSettings",
            json!({"proxyMode": "auto", "catalogConcurrency": 99}),
        );
        assert_eq!(error["code"], "BAD_REQUEST");
    }

    #[test]
    fn source_validate_reports_errors() {
        let _guard = serial();
        // 可解析但语义非法 → valid=false + 错误清单。
        let bad_manifest = "schema: 2\nid: BAD\nname: x\nbase: nope\n";
        let data = dispatch_ok("sourceValidate", json!({"manifest": bad_manifest}));
        assert_eq!(data["valid"], false);
        assert!(!data["errors"].as_array().expect("errors").is_empty());

        // 不可解析 → RULE_INVALID 错误。
        let error = dispatch_err("sourceValidate", json!({"manifest": "{not yaml"}));
        assert_eq!(error["code"], "RULE_INVALID");
    }

    #[test]
    fn source_install_and_uninstall() {
        let _guard = serial();
        // 前置：挂到一个干净的临时目录（进程内共享 store，必须先复位）。
        let dir = std::env::temp_dir().join(format!("drama-engine-src-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        drama_rules::SourceStore::shared().reset();
        drama_rules::SourceStore::shared().attach(dir.join("sources"));
        global().reattach();

        let manifest = r#"
schema: 1
id: enginetest
name: 引擎测试源
base: https://engine.test
ops:
  catalog:
    request:
      url: "{{base}}/list"
    items: "data.list"
"#;
        let record = dispatch_ok(
            "sourceInstall",
            json!({"manifest": manifest, "origin": "local"}),
        );
        assert_eq!(record["id"], "enginetest");

        // 出现在 sources 列表。
        let sources = dispatch_ok("sources", json!({}));
        assert!(sources.as_array().expect("list").iter().any(|s| s["id"] == "enginetest"));

        // 启停。
        dispatch_ok("sourceEnable", json!({"id": "enginetest", "enabled": false}));
        dispatch_ok("sourceEnable", json!({"id": "enginetest", "enabled": true}));

        // 卸载。
        dispatch_ok("sourceUninstall", json!({"id": "enginetest"}));
        let sources = dispatch_ok("sources", json!({}));
        assert!(
            !sources.as_array().expect("list").iter().any(|s| s["id"] == "enginetest")
        );

        // 清理：复位共享 store，避免污染后续测试。
        drama_rules::SourceStore::shared().reset();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cannot_install_reserved_id() {
        let _guard = serial();
        let manifest = r#"
schema: 1
id: hongguo
name: 冒充内置
base: https://fake.test
ops: {}
"#;
        let error = dispatch_err("sourceInstall", json!({"manifest": manifest}));
        assert_eq!(error["code"], "RULE_INVALID");
    }

    #[test]
    fn diagnostics_snapshot() {
        let _guard = serial();
        let data = dispatch_ok("diagnostics", json!({}));
        assert!(data["sourceCount"].is_u64());
        assert!(data["inFlightReads"].is_u64());
    }

    #[test]
    fn cache_key_includes_source_and_args() {
        let request = Request::parse(
            r#"{"v":1,"op":"catalog","source":"wuguo","params":{"category":"hot","page":2}}"#,
        )
        .expect("parse");
        assert_eq!(read_cache_key(&request), "wuguo:catalog:hot:2");

        let request = Request::parse(r#"{"v":1,"op":"search","params":{"keyword":"都市"}}"#)
            .expect("parse");
        assert_eq!(read_cache_key(&request), "hongguo:search:都市");
    }
}
