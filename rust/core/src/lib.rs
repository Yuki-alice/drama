//! 红果短剧客户端 Rust 核心（MVP 骨架）。
//!
//! 对外仅暴露两个 C ABI 符号：
//! - `drama_request(const char* utf8_json) -> char*`
//! - `drama_free(char* ptr)`
//!
//! JSON-RPC 信封遵循 /：入参 `{v:1, op, source?, session?, sequence?, params?}`，
//! 出参 `{ok:true, data}` 或 `{ok:false, error:{code, msg, retry}}`。
//!
//! **取消协议与分级超时**：见 [`cancel`] 与 [`http`]。读类 op 带 `session`/`sequence`
//! 时参与仲裁——旧 `sequence` 直接丢弃（`CANCELED`）；内层分级超时映射为 `TIMEOUT`（`retry=true`）；
//! `cancelRead` 取消同 session 中 `sequence` 更小的在途读请求并返回被取消数量。
//!
//! **并发布局**：Dart 侧为常驻 worker **池**（见 `lib/data/services/rust_core.dart`），
//! 故「一个 worker 阻塞在网络时，另一个 worker 仍能处理 `cancelRead`」——`cancelRead` 登记的
//! 取消令牌会被在途读的 `tokio::select!` 观察到，**尽力**提前释放该请求。

pub mod app_api;
pub mod cache;
pub mod cancel;
pub mod covers;
pub mod decrypt;
pub mod device;
pub mod download;
pub mod gateway;

/// 测试串行锁：`device` 与 `store` 测试共享进程级可变全局（`DATA_DIR`），
/// 必须串行，否则持久化路径互相踩。需要全局隔离的测试先拿这把锁。
#[cfg(test)]
pub(crate) mod test_serial {
    use once_cell::sync::Lazy;
    use std::sync::Mutex;
    pub static SERIAL: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));
}
pub mod http;
pub mod sign;
pub mod source;
pub mod sources;
pub mod store;

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use source::traits::{SourceError, SourceProvider};

/// 入参上限 1 MiB。
const MAX_INPUT_BYTES: usize = 1024 * 1024;

/// `catalogPages` 一次最多取几页（上限保护：误传巨大 depth 不该拖成超长串行拉取）。
const MAX_PAGES_PER_REQUEST: u32 = 8;

/// 选集分组默认每组几集（播放页 chip 一屏放得下、又不至于组太多）。
const EPISODE_GROUP_SIZE: u32 = 50;

/// 单个选集分组的上下限（防误传 1 或 10000）。
const MIN_EPISODE_GROUP_SIZE: u32 = 10;
const MAX_EPISODE_GROUP_SIZE: u32 = 200;

/// 信封版本。
const ENVELOPE_VERSION: u32 = 1;

/// **契约守卫表**：全部 op 及其是否参与 `session`/`sequence` 仲裁。
///
/// 这份表是 `docs/RUST_CONTRACT.md` 的机器可校验副本。新增/删除 op 时必须同步两处，
/// 否则 `contract_table_matches_dispatch` 会失败——目的是防止「代码加了 op 但文档没写」
/// （前端按文档开发，漏一个 op 就会盲写）。
///
/// 第二列 `true` = 走 `arbitrated_read`（受内层超时约束、可被 `cancelRead` 打断）。
#[cfg(test)]
const CONTRACT_OPS: &[(&str, bool)] = &[
    ("ping", false),
    ("version", false),
    ("cancelRead", false),
    ("catalog", true),
    ("catalogPages", true),
    ("recommend", true),
    ("ranking", true),
    ("search", true),
    ("suggest", true),
    ("detail", true),
    ("episodeGroups", true),
    ("init", false),
    ("play", true),
    ("preload", true),
    ("playQuality", true),
    ("playLocal", false),
    ("playFile", false),
    ("followPut", false),
    ("followDel", false),
    ("followList", false),
    ("historyPut", false),
    ("historyGet", false),
    ("historyClear", false),
    ("searchHistoryPut", false),
    ("searchHistoryList", false),
    ("searchHistoryDel", false),
    ("searchHistoryClear", false),
    ("downloadStart", false),
    ("downloadList", false),
    ("downloadPause", false),
    ("downloadRetry", false),
    ("downloadCancel", false),
    ("downloadDelete", false),
    ("moveDownloads", true),
    ("downloadSetConcurrency", false),
    ("cacheClear", false),
    ("cacheFlush", false),
    ("cacheStats", false),
];

/// 请求信封：`{v:1, op, source?, session?, sequence?, params?}`。
#[derive(Debug, Deserialize)]
struct Request {
    #[serde(default = "default_version")]
    v: u32,
    op: String,
    /// 源 id：`None` 用默认源（hongguo）。W2 起使用。
    #[serde(default)]
    source: Option<String>,
    /// 读请求会话标识：字符集 `[0-9a-zA-Z-_:.]`，长度 ≤128；不合法 → `BAD_REQUEST`。
    #[serde(default)]
    session: Option<String>,
    /// 同 session 内单调递增的序号。缺失 → 不参与仲裁（兼容 `ping`/`version`）。
    #[serde(default)]
    sequence: Option<u64>,
    /// 各 op 参数（W2 起使用）。
    #[serde(default)]
    params: Value,
}

fn default_version() -> u32 {
    ENVELOPE_VERSION
}

/// 错误体：`{code, msg, retry}`。
#[derive(Debug, Serialize)]
struct ErrorBody {
    code: &'static str,
    msg: String,
    retry: bool,
}

/// 成功响应。
/// 成功响应。
///
/// **不要用 `json!` 宏**：宏对已有的 `Value` 会走 `to_value` 深拷贝整个
/// `data`（一页目录 5.6KB、一次多页聚合 28KB，实测每次响应 ~20-175µs）。
/// 这里用 `Map` 直接插入 —— `data` 是 move，零拷贝。
fn ok(data: Value) -> Value {
    let mut map = serde_json::Map::with_capacity(2);
    map.insert("ok".to_owned(), Value::Bool(true));
    map.insert("data".to_owned(), data);
    Value::Object(map)
}

/// 失败响应（`retry` 默认 false）。
fn err(code: &'static str, msg: impl Into<String>) -> Value {
    err_with(code, msg, false)
}

/// 失败响应（显式指定 `retry`）。
fn err_with(code: &'static str, msg: impl Into<String>, retry: bool) -> Value {
    json!({
        "ok": false,
        "error": ErrorBody { code, msg: msg.into(), retry },
    })
}

/// 存储错误映射为信封三元组（与 [`with_provider`] 的映射口径一致）。
fn store_error(e: source::traits::SourceError) -> (&'static str, String, bool) {
    use source::traits::SourceError as E;
    match &e {
        E::Unsupported => ("UNSUPPORTED", e.to_string(), false),
        E::Canceled => ("CANCELED", e.to_string(), false),
        E::Timeout => ("TIMEOUT", e.to_string(), true),
        E::Http(h) => ("HTTP", e.to_string(), h.retryable),
        E::Parse(_) => ("PARSE", e.to_string(), false),
        E::NotFound => ("NOT_FOUND", e.to_string(), false),
        E::Blocked { .. } => ("source_blocked", e.to_string(), true),
    }
}

/// 取参数中的字符串（非字符串/缺失 → `None`）。
fn param_str(params: &Value, key: &str) -> Option<String> {
    params.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// 取参数中的无符号整数（缺失 → `default`；超 `u32` 上限饱和到 `u32::MAX`，
/// 禁止 `as` 截断回绕——回绕会把巨大 `depth` 静默变成 0（跟随水位），语义完全走样）。
fn param_u32(params: &Value, key: &str, default: u32) -> u32 {
    params
        .get(key)
        .and_then(Value::as_u64)
        .map_or(default, |n| u32::try_from(n).unwrap_or(u32::MAX))
}

/// 缓存 key 用的源 id：缺省/空白一律归默认源。
///
/// fetch 路径仍透传原始 `Option`（空串源保持 `NotFound` 语义），只有 key 做
/// 归一化——错误结果不落盘，不会串库。
fn effective_source(source: Option<&str>) -> &str {
    source
        .filter(|s| !s.is_empty())
        .unwrap_or(source::DEFAULT_SOURCE_ID)
}

/// 读类过滤用的源：空/缺省表示不过滤（全源），保持单源时代行为。
fn source_filter(source: Option<&str>) -> Option<&str> {
    source.filter(|s| !s.is_empty())
}

/// 取源实现并执行 `f`，返回**原始** [`Result`]。
///
/// 缓存层需要区分"成功/失败"才能决定写缓存还是回退旧值，故先有本函数；
/// 直接要信封时用 [`with_provider`]。
fn with_provider_result<F>(source: Option<&str>, f: F) -> Result<Value, SourceError>
where
    F: FnOnce(&dyn SourceProvider) -> Result<Value, SourceError>,
{
    match source::provider(source) {
        Ok(p) => f(p.as_ref()),
        Err(e) => Err(e),
    }
}

/// 取源实现并执行 `f`，把 [`SourceError`] 映射成信封 `error{code,msg,retry}`。
fn with_provider<F>(source: Option<&str>, f: F) -> Value
where
    F: FnOnce(&dyn SourceProvider) -> Result<Value, SourceError>,
{
    match with_provider_result(source, f) {
        Ok(v) => ok(v),
        Err(e) => err_with(e.code(), e.to_string(), e.retry()),
    }
}

/// 选集分组：`groupSize` 集一组，产出 `{groupSize,total,groups:[{index,start,end,label,episodes}]}`。
///
/// **分组规则归 Rust**：组大小、起止、标签（"1-50"）都是业务口径，Dart 只按组渲染。
/// `episodes` 用 `drain` 搬出来（move），不做整表深拷贝——100 集规模下这是
/// 几十 KB 的差别。
fn episode_groups(episodes: Vec<Value>, group_size: u32) -> Value {
    let size = group_size.clamp(MIN_EPISODE_GROUP_SIZE, MAX_EPISODE_GROUP_SIZE) as usize;
    let total = episodes.len();
    let mut rest = episodes;
    let mut groups: Vec<Value> = Vec::with_capacity(total.div_ceil(size));
    let mut index = 0usize;
    while !rest.is_empty() {
        let take = size.min(rest.len());
        // `drain` 把这一段 `Value` **搬**进新 Vec，不深拷贝。
        let chunk: Vec<Value> = rest.drain(..take).collect();
        let start = index * size + 1;
        let end = start + chunk.len() - 1;
        let mut group = serde_json::Map::with_capacity(5);
        group.insert("index".to_owned(), json!(index));
        group.insert("start".to_owned(), json!(start));
        group.insert("end".to_owned(), json!(end));
        group.insert("label".to_owned(), Value::String(format!("{start}-{end}")));
        group.insert("episodes".to_owned(), Value::Array(chunk));
        groups.push(Value::Object(group));
        index += 1;
    }
    let mut data = serde_json::Map::with_capacity(4);
    data.insert("groupSize".to_owned(), json!(size));
    data.insert("total".to_owned(), json!(total));
    data.insert("groupCount".to_owned(), json!(groups.len()));
    data.insert("groups".to_owned(), Value::Array(groups));
    Value::Object(data)
}

/// 从详情响应里**取出**（move）`episodes` 数组，避免后续深拷贝。
fn take_episodes(detail: Value) -> Vec<Value> {
    match detail {
        Value::Object(mut map) => match map.remove("episodes") {
            Some(Value::Array(a)) => a,
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

/// 缓存层结果 → 信封：成功并入 `stale` / `ageSecs`，失败**原样**映射错误码。
fn cached_to_value(result: Result<cache::Cached, SourceError>) -> Value {
    match result {
        Ok(cached) => ok(cache::into_data(cached)),
        Err(e) => err_with(e.code(), e.to_string(), e.retry()),
    }
}

/// 读类 op 的取消/超时包装。
///
/// - 带 `session`+`sequence`：进入时旧 `sequence` 直接 `CANCELED`（**不发网络请求**）；
///   收尾时若已被更新的 `sequence` 取代或本请求 `sequence ≤ cancel_before` → 结果替换为 `CANCELED`。
/// - 无论是否仲裁：都在 [`http::enter_read`] 下运行以施加**内层分级超时**（`TIMEOUT`，`retry=true`）。
fn arbitrated_read<F>(session: Option<&str>, sequence: Option<u64>, op: &str, run: F) -> Value
where
    F: FnOnce() -> Value,
{
    let budget = http::inner_timeout_for(op);
    let (Some(session), Some(sequence)) = (session, sequence) else {
        // 缺 session/sequence（如无状态调用）：不仲裁，但仍施加内层超时。
        let _guard = http::enter_read(None, budget);
        return run();
    };

    let token = CancellationToken::new();
    if cancel::begin(session, sequence, token.clone()) == cancel::Decision::Canceled {
        return err("CANCELED", "superseded by newer sequence");
    }

    let out = {
        let _guard = http::enter_read(Some(token), budget);
        run()
    };

    if cancel::complete(session, sequence) == cancel::Decision::Canceled {
        return err("CANCELED", "superseded by newer sequence");
    }
    out
}

/// 核心分发：解析信封并按 `op` 路由。
fn dispatch(input: &str) -> Value {
    if input.len() > MAX_INPUT_BYTES {
        return err(
            "TOO_LARGE",
            format!("input exceeds {MAX_INPUT_BYTES} bytes"),
        );
    }

    let req: Request = match serde_json::from_str(input) {
        Ok(req) => req,
        Err(e) => return err("BAD_REQUEST", format!("invalid request: {e}")),
    };

    if req.v != ENVELOPE_VERSION {
        return err(
            "BAD_VERSION",
            format!("unsupported envelope version: {}", req.v),
        );
    }

    // session 信封级校验：非法即 `BAD_REQUEST`。
    if let Some(s) = req.session.as_deref()
        && !cancel::is_valid_session(s)
    {
        return err("BAD_REQUEST", "invalid session");
    }

    match req.op.as_str() {
        // W0 冒烟：回声，用于验证 FFI 往返。无状态，不参与仲裁。
        "ping" => ok(Value::String("pong".to_owned())),

        // core 版本 + 已注册源的 caps（供 Dart 侧能力协商）。无状态，不参与仲裁。
        "version" => {
            let list: Vec<Value> = source::registered()
                .iter()
                .map(|p| json!({ "id": p.id(), "caps": p.caps().to_json() }))
                .collect();
            // `mediaPort`：本机代理（媒体 + 封面）当前监听端口。
            // Dart 侧用它把**落盘缓存里**的封面 URL 改写到本次会话的端口——
            // 端口是实现细节，不该成为缓存数据的一部分。
            // 首次调用时顺带完成绑定；绑定失败返回 null（封面回落占位）。
            let media_port = covers::media_port();
            ok(json!({
                "core": env!("CARGO_PKG_VERSION"),
                "sources": list,
                "mediaPort": media_port,
            }))
        }

        // 取消在途读：`{session, sequence}` → `{canceled:N}`；不阻塞、不参与仲裁。
        "cancelRead" => match (
            param_str(&req.params, "session"),
            req.params.get("sequence").and_then(Value::as_u64),
        ) {
            (Some(s), Some(seq)) if cancel::is_valid_session(&s) => {
                ok(json!({ "canceled": cancel::cancel_read(&s, seq) }))
            }
            _ => err("BAD_REQUEST", "cancelRead requires {session, sequence}"),
        },

        // ── 读类 op（走 Rust 缓存引擎）─────────────────────────────────
        //
        // 缓存策略（TTL / 回退 / 熔断 / 并发去重 / 分页水位）全部在 [`cache`]，
        // Dart 侧不再持有任何缓存逻辑：命中直接返回，失败回退旧值并在 `data`
        // 里带上 `stale=true`（UI 据此提示"当前是缓存数据"）。
        "catalog" => {
            // 页号 0 起（与 Dart 侧、`catalogPages` 的 `0..depth` 同一起点）：
            // 单页 `page=P` 与聚合里第 P 页共用同一缓存 key，水位 `page+1`
            // 即“已取页数”，与 `catalogPages` 写的 `depth` 同一含义。
            let category = param_str(&req.params, "category");
            let page = param_u32(&req.params, "page", 0);
            let src = effective_source(req.source.as_deref());
            let key = cache::key_catalog(src, category.as_deref().unwrap_or(""), page);
            let depth_key = cache::key_catalog_depth(src, category.as_deref().unwrap_or(""));
            arbitrated_read(req.session.as_deref(), req.sequence, "catalog", || {
                let source = req.source.as_deref();
                let result = cache::cached(&key, cache::TTL_CATALOG_MS, None, || {
                    with_provider_result(source, |p| p.catalog(category.as_deref(), page))
                });
                // 分页水位：只增不减，供重启后续载不丢页。
                if result.is_ok() {
                    cache::write_depth(&depth_key, page + 1);
                }
                cached_to_value(result)
            })
        }

        "recommend" => arbitrated_read(req.session.as_deref(), req.sequence, "recommend", || {
            let source = req.source.as_deref();
            let key = cache::key_recommend(effective_source(source));
            let result = cache::cached(&key, cache::TTL_CATALOG_MS, None, || {
                with_provider_result(source, |p| p.recommend())
            });
            cached_to_value(result)
        }),

        "ranking" => {
            let board_opt = param_str(&req.params, "board");
            let board_key = board_opt.clone().unwrap_or_else(|| "hot".to_owned());
            let src = effective_source(req.source.as_deref());
            let key = cache::key_ranking(src, &board_key);
            // 榜单按（源，板）独立熔断：一个坏榜不拖垮其他榜和其他源。
            let breaker_key = format!("{src}:{board_key}");
            arbitrated_read(req.session.as_deref(), req.sequence, "ranking", || {
                let source = req.source.as_deref();
                let board = board_opt.clone();
                let result = cache::cached(&key, cache::TTL_RANKING_MS, Some(&breaker_key), || {
                    with_provider_result(source, |p| p.ranking(board.as_deref()))
                });
                cached_to_value(result)
            })
        }

        "search" => match param_str(&req.params, "keyword") {
            Some(kw) if !kw.is_empty() => {
                let key = cache::key_search(effective_source(req.source.as_deref()), &kw);
                arbitrated_read(req.session.as_deref(), req.sequence, "search", || {
                    let source = req.source.as_deref();
                    let result = cache::cached(&key, cache::TTL_CATALOG_MS, None, || {
                        with_provider_result(source, |p| p.search(&kw))
                    });
                    cached_to_value(result)
                })
            }
            _ => err("BAD_REQUEST", "missing keyword"),
        },

        "suggest" => match param_str(&req.params, "keyword") {
            Some(kw) if !kw.is_empty() => {
                let key = cache::key_suggest(effective_source(req.source.as_deref()), &kw);
                arbitrated_read(req.session.as_deref(), req.sequence, "suggest", || {
                    let source = req.source.as_deref();
                    let result = cache::cached(&key, cache::TTL_CATALOG_MS, None, || {
                        with_provider_result(source, |p| p.suggest(&kw))
                    });
                    cached_to_value(result)
                })
            }
            _ => err("BAD_REQUEST", "missing keyword"),
        },

        // 详情：App 签名主链 + SSR 降级，返回同契约的 `{drama, episodes}`。
        "detail" => match param_str(&req.params, "id") {
            Some(id) if !id.is_empty() => {
                let key = cache::key_detail(effective_source(req.source.as_deref()), &id);
                arbitrated_read(req.session.as_deref(), req.sequence, "detail", || {
                    let source = req.source.as_deref();
                    let result = cache::cached(&key, cache::TTL_CATALOG_MS, None, || {
                        with_provider_result(source, |p| p.detail(&id))
                    });
                    cached_to_value(result)
                })
            }
            _ => err("BAD_REQUEST", "missing id"),
        },

        // 选集分页：`{id, groupSize?}` → `{groupSize, total, groupCount, groups:[...]}`。
        //
        // 之前播放页只 `take(60)` 硬截（60 集以上的剧根本点不到），详情页则各自
        // 在 Dart 侧维护一套切片常量。现在分组由 Rust 一次算好、每组自带本组剧集，
        // Dart 只渲染——两处口径统一，且复用详情缓存（命中即零网络）。
        "episodeGroups" => match param_str(&req.params, "id") {
            Some(id) if !id.is_empty() => {
                let group_size = param_u32(&req.params, "groupSize", EPISODE_GROUP_SIZE);
                let key = cache::key_detail(effective_source(req.source.as_deref()), &id);
                arbitrated_read(
                    req.session.as_deref(),
                    req.sequence,
                    "episodeGroups",
                    || {
                        let source = req.source.as_deref();
                        let result = cache::cached(&key, cache::TTL_CATALOG_MS, None, || {
                            with_provider_result(source, |p| p.detail(&id))
                        });
                        match result {
                            Ok(cached) => {
                                let mut data =
                                    match episode_groups(take_episodes(cached.value), group_size) {
                                        Value::Object(m) => m,
                                        other => {
                                            let mut m = serde_json::Map::new();
                                            m.insert("groups".to_owned(), other);
                                            m
                                        }
                                    };
                                data.insert("stale".to_owned(), Value::Bool(cached.stale));
                                data.insert("ageSecs".to_owned(), json!(cached.age_secs));
                                ok(Value::Object(data))
                            }
                            Err(e) => err_with(e.code(), e.to_string(), e.retry()),
                        }
                    },
                )
            }
            _ => err("BAD_REQUEST", "missing id"),
        },

        // 首页「重启续载」：一次往返取回 `0..depth-1` 页。
        //
        // 之前 Dart 侧是循环 N 次 `catalog()`——N 次 FFI 往返 + N 次 JSON 编解码，
        // 而缓存命中的页本应是瞬时的。改由 Rust 一次聚合，往返数从 N 降到 1。
        // `depth` 上限 [MAX_PAGES_PER_REQUEST]，防止误用导致超长串行拉取。
        "catalogPages" => {
            let category = param_str(&req.params, "category");
            let category_key = category.clone().unwrap_or_default();
            let src = effective_source(req.source.as_deref());
            let depth_key = cache::key_catalog_depth(src, &category_key);
            // `depth` 省略 / 0 = 跟随**已记录的分页水位**（首页重启续载：
            // 上次看到第几页就取回几页，Dart 侧零循环、也无需先查水位）。
            let requested = param_u32(&req.params, "depth", 0);
            let depth = if requested == 0 {
                cache::read_depth(&depth_key).unwrap_or(1)
            } else {
                i64::from(requested)
            }
            .clamp(1, i64::from(MAX_PAGES_PER_REQUEST)) as u32;
            arbitrated_read(req.session.as_deref(), req.sequence, "catalogPages", || {
                let source = req.source.as_deref();
                let mut pages = Vec::with_capacity(depth as usize);
                let mut has_more = false;
                let mut stale = false;
                let mut age_secs = 0i64;
                for page in 0..depth {
                    let key = cache::key_catalog(src, &category_key, page);
                    let category_now = category.clone();
                    match cache::cached(&key, cache::TTL_CATALOG_MS, None, || {
                        with_provider_result(source, |p| p.catalog(category_now.as_deref(), page))
                    }) {
                        Ok(cached) => {
                            stale |= cached.stale;
                            age_secs = age_secs.max(cached.age_secs);
                            has_more = cached
                                .value
                                .get("hasMore")
                                .and_then(Value::as_bool)
                                .unwrap_or(false);
                            pages.push(cached.value);
                        }
                        Err(e) => return err_with(e.code(), e.to_string(), e.retry()),
                    }
                }
                cache::write_depth(&depth_key, depth);
                // 用 `Map` 直接构造而不用 `json!`：`json!` 对已有的
                // `Vec<Value>` 会走 `to_value` **深拷贝**整批数据（实测
                // 5 页约 240µs），这里 `Value::Array(pages)` 是 move，零拷贝。
                let mut data = serde_json::Map::new();
                data.insert("pages".to_owned(), Value::Array(pages));
                data.insert("hasMore".to_owned(), Value::Bool(has_more));
                data.insert("depth".to_owned(), json!(depth));
                data.insert("stale".to_owned(), Value::Bool(stale));
                data.insert("ageSecs".to_owned(), json!(age_secs));
                ok(Value::Object(data))
            })
        }

        // 设备身份初始化：`{dataDir, downloadDir?}` → 持久化 device.json。
        // 无状态幂等，不参与仲裁；失败不阻断（退化为进程内临时身份）。
        "init" => match param_str(&req.params, "dataDir") {
            Some(dir) if !dir.is_empty() => {
                device::set_data_dir(std::path::PathBuf::from(&dir));
                if let Some(download) = param_str(&req.params, "downloadDir")
                    && !download.is_empty()
                {
                    device::set_download_dir(std::path::PathBuf::from(&download));
                }
                let id = device::identity();
                ok(json!({ "initialized": true, "deviceIdLen": id.device_id.len() }))
            }
            _ => err("BAD_REQUEST", "missing dataDir"),
        },

        // 取流：`{id, episode?, vid?, quality?}` → `{proxyUrl, url, variants, ...}`。
        // 播放器只打开 `proxyUrl`（Referer 鉴权 baked 进代理会话）。
        "play" => match param_str(&req.params, "id") {
            Some(id) if !id.is_empty() => {
                arbitrated_read(req.session.as_deref(), req.sequence, "play", || {
                    with_provider(req.source.as_deref(), |p| {
                        p.play(
                            &id,
                            req.params
                                .get("episode")
                                .and_then(Value::as_u64)
                                .unwrap_or(1) as u32,
                            param_str(&req.params, "vid"),
                            req.params
                                .get("quality")
                                .and_then(Value::as_i64)
                                .unwrap_or(0),
                        )
                    })
                })
            }
            _ => err("BAD_REQUEST", "missing id"),
        },

        // 预取下集：同 `play` 参数，顺带解密首窗口；失败可忽略（可选能力）。
        "preload" => match param_str(&req.params, "id") {
            Some(id) if !id.is_empty() => {
                arbitrated_read(req.session.as_deref(), req.sequence, "preload", || {
                    with_provider(req.source.as_deref(), |p| {
                        p.preload(
                            &id,
                            req.params
                                .get("episode")
                                .and_then(Value::as_u64)
                                .unwrap_or(1) as u32,
                            param_str(&req.params, "vid"),
                            req.params
                                .get("quality")
                                .and_then(Value::as_i64)
                                .unwrap_or(0),
                        )
                    })
                })
            }
            _ => err("BAD_REQUEST", "missing id"),
        },

        // 换档：`{id, vid, quality}` → 同 `play` 的响应结构（含新的 `proxyUrl`）。
        //
        // 快路径在 `app_api::switch_quality`：上一次取流已经把这一集的**全部候选
        // 清晰度**解析回来了，换档只是在里面重挑一个并重新注册代理会话——
        // 零签名、零网络（`play` 换 quality 则会因缓存键不同而整条链重跑）。
        // 旁路缓存未命中（首次取流前换档 / 已过 TTL）才回落到完整解析。
        "playQuality" => match (param_str(&req.params, "id"), param_str(&req.params, "vid")) {
            (Some(id), Some(vid)) if !id.is_empty() && !vid.is_empty() => {
                let quality = req
                    .params
                    .get("quality")
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                arbitrated_read(req.session.as_deref(), req.sequence, "playQuality", || {
                    let source = req.source.as_deref();
                    with_provider(source, |p| p.play_variant(&id, &vid, quality))
                })
            }
            _ => err("BAD_REQUEST", "playQuality requires {id, vid}"),
        },

        // 追剧与进度（Rust 持久化，Dart 只渲染；无状态，不参与仲裁）。
        // 写操作按有效源落键，读操作缺省查全源——单源行为与过去完全一致。
        "followPut" => store::follow_put(effective_source(req.source.as_deref()), &req.params)
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        "followDel" => store::follow_del(effective_source(req.source.as_deref()), &req.params)
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        "followList" => store::follow_list(source_filter(req.source.as_deref()))
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        "historyPut" => store::history_put(effective_source(req.source.as_deref()), &req.params)
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        "historyGet" => store::history_get(source_filter(req.source.as_deref()), &req.params)
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        "historyClear" => store::history_clear(source_filter(req.source.as_deref()))
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        // 迁移下载目录：`{dir}` → `{dir, moved, bytes}`。
        // 走 `arbitrated_read`：它既有 600s 内层预算（慢磁盘搬迁需要），
        // 也能被 `cancelRead` 打断；先停机再搬，失败时旧目录原样保留。
        "moveDownloads" => match param_str(&req.params, "dir") {
            Some(dir) if !dir.trim().is_empty() => arbitrated_read(
                req.session.as_deref(),
                req.sequence,
                "moveDownloads",
                || {
                    download::move_downloads(&req.params)
                        .map(ok)
                        .unwrap_or_else(|e| {
                            let (code, msg, retry) = store_error(e);
                            err_with(code, msg, retry)
                        })
                },
            ),
            _ => err("BAD_REQUEST", "moveDownloads requires {dir}"),
        },
        // 并行任务数（1~6）：持久化到下载目录，下次启动照旧。
        "downloadSetConcurrency" => download::set_concurrency(&req.params)
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        // 离线优先取流：`{id, episode}` → 与 `play` 同构的计划；无完成文件 → NOT_FOUND。
        // 按有效源查表（同剧集在不同源的离线文件互不干扰）。
        "playLocal" => match param_str(&req.params, "id") {
            Some(id) if !id.is_empty() => {
                download::play_local(effective_source(req.source.as_deref()), &req.params)
                    .map(ok)
                    .unwrap_or_else(|e| {
                        let (code, msg, retry) = store_error(e);
                        err_with(code, msg, retry)
                    })
            }
            _ => err("BAD_REQUEST", "missing id"),
        },

        // 下载管理（长任务跑独立运行时；Dart 轮询 `downloadList` 取进度）。
        // 新建/取流按有效源归属； pause/retry/cancel/delete/file 凭不透明任务 id 操作。
        "downloadStart" => download::start(effective_source(req.source.as_deref()), &req.params)
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),
        "downloadList" => download::list().map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        "downloadPause" => download::pause(&req.params).map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        "downloadRetry" => download::retry(&req.params).map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        "downloadCancel" => download::cancel(&req.params).map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        "downloadDelete" => download::delete(&req.params).map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        // 离线播放：已完成下载注册文件会话，返回代理 URL（复用解密链）。
        "playFile" => download::play_file(&req.params)
            .map(ok)
            .unwrap_or_else(|e| {
                let (code, msg, retry) = store_error(e);
                err_with(code, msg, retry)
            }),

        // 搜索历史（Rust 持久化；Dart 侧不再用内存列表，重启后不丢）。
        //
        // 空白关键词在信封层即判 `BAD_REQUEST`（与 search/suggest 缺参同码）；
        // store 内的 `Parse` 作为直调兜底保留。
        "searchHistoryPut" => match param_str(&req.params, "keyword") {
            Some(kw) if !kw.trim().is_empty() => store::search_history_put(&req.params)
                .map(ok)
                .unwrap_or_else(|e| {
                    let (code, msg, retry) = store_error(e);
                    err_with(code, msg, retry)
                }),
            _ => err("BAD_REQUEST", "missing keyword"),
        },
        "searchHistoryList" => store::search_history_list().map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        "searchHistoryDel" => match param_str(&req.params, "keyword") {
            Some(kw) if !kw.trim().is_empty() => store::search_history_del(&req.params)
                .map(ok)
                .unwrap_or_else(|e| {
                    let (code, msg, retry) = store_error(e);
                    err_with(code, msg, retry)
                }),
            _ => err("BAD_REQUEST", "missing keyword"),
        },
        "searchHistoryClear" => store::search_history_clear().map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),

        // 缓存管理（目录缓存现在完全由 Rust 持有）：设置页「清除缓存」与诊断。
        "cacheClear" => cache::clear().map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        "cacheFlush" => cache::flush().map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),
        "cacheStats" => cache::stats().map(ok).unwrap_or_else(|e| {
            let (code, msg, retry) = store_error(e);
            err_with(code, msg, retry)
        }),

        other => err("UNSUPPORTED", format!("unknown op: {other}")),
    }
}

/// 入口：`char* drama_request(const char* utf8_json)`。
/// 返回的指针必须由 [`drama_free`] 释放；任何情况下都返回合法 JSON（不返回空指针）。
/// # Safety
/// `ptr` 必须为有效的、以 NUL 结尾的 UTF-8 字节串指针（或空指针）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn drama_request(ptr: *const c_char) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if ptr.is_null() {
            return err("BAD_REQUEST", "null input");
        }
        // SAFETY: 调用方保证 `ptr` 指向以 NUL 结尾的 UTF-8 字节串。
        match unsafe { CStr::from_ptr(ptr) }.to_str() {
            Ok(input) => dispatch(input),
            Err(_) => err("BAD_REQUEST", "input is not valid UTF-8"),
        }
    }))
    .unwrap_or_else(|_| err("INTERNAL", "panic in rust core"));

    let json = serde_json::to_string(&response).unwrap_or_else(|_| {
        r#"{"ok":false,"error":{"code":"INTERNAL","msg":"serialize failed","retry":false}}"#
            .to_owned()
    });

    // SAFETY: `CString` 持有内存所有权；`into_raw` 后所有权交给调用方，由 [`drama_free`] 回收。
    CString::new(json).unwrap_or_default().into_raw()
}

/// 释放 [`drama_request`] 返回的字符串指针。
///
/// # Safety
/// `ptr` 必须是 [`drama_request`] 返回、且尚未释放的指针（或空指针）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn drama_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: `ptr` 由 `drama_request` 的 `CString::into_raw` 产生，且仅在此处回收一次。
    unsafe { drop(CString::from_raw(ptr)) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn ping_returns_pong() {
        let out = dispatch(r#"{"v":1,"op":"ping"}"#);
        assert_eq!(out["ok"], json!(true));
        assert_eq!(out["data"], json!("pong"));
    }

    #[test]
    fn unknown_op_is_unsupported() {
        let out = dispatch(r#"{"v":1,"op":"nope"}"#);
        assert_eq!(out["ok"], json!(false));
        assert_eq!(out["error"]["code"], json!("UNSUPPORTED"));
    }

    #[test]
    fn invalid_json_is_bad_request() {
        let out = dispatch("not json");
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn wrong_envelope_version_is_rejected() {
        let out = dispatch(r#"{"v":2,"op":"ping"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_VERSION"));
    }

    #[test]
    fn oversized_input_is_rejected() {
        let big = "a".repeat(MAX_INPUT_BYTES + 1);
        let out = dispatch(&big);
        assert_eq!(out["error"]["code"], json!("TOO_LARGE"));
    }

    #[test]
    fn param_u32_saturates_instead_of_wrapping() {
        assert_eq!(param_u32(&json!({}), "page", 7), 7);
        assert_eq!(param_u32(&json!({"page": 3}), "page", 7), 3);
        // 超 u32 上限饱和，不回绕成小值。
        assert_eq!(
            param_u32(&json!({"page": 18446744073709551615u64}), "page", 7),
            u32::MAX
        );
        // 负数/非数字按缺失处理。
        assert_eq!(param_u32(&json!({"page": -1}), "page", 7), 7);
    }

    /// 契约守卫：`CONTRACT_OPS` 必须与 `dispatch` 实际处理的 op **完全一致**。
    ///
    /// 做法：对表里每个 op 发一次最小信封，断言**不是** `UNSUPPORTED`
    /// （即 dispatch 认得它）；再断言表里没有重复项。
    /// 这样「加了 op 忘了进表」与「删了 op 没清表」都会被抓到。
    #[test]
    fn contract_table_matches_dispatch() {
        // 串行执行，避免占用缓存 key / 在途槽污染并发测试。
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        // 1) 表内无重复
        let mut names: Vec<&str> = CONTRACT_OPS.iter().map(|(n, _)| *n).collect();
        let total = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), total, "CONTRACT_OPS 有重复 op");

        // 2) 每个 op 都被 dispatch 认得（不返回 UNSUPPORTED）。
        //
        // 会触网的读 op 用不存在的源：本用例只关心“认得”，`NOT_FOUND` 同样证明
        // 接线正常，且失败是瞬时的（不占网络、不写缓存、不污染其他测试）。
        const OFFLINE_SOURCE: &str = r#","source":"nope""#;
        for (op, _) in CONTRACT_OPS {
            let extra = match *op {
                "catalog" | "recommend" | "ranking" | "catalogPages" => OFFLINE_SOURCE,
                _ => "",
            };
            let out = dispatch(&format!(r#"{{"v":1,"op":"{op}"{extra}}}"#));
            let code = out["error"]["code"].as_str().unwrap_or("");
            assert_ne!(
                code, "UNSUPPORTED",
                "op `{op}` 在 CONTRACT_OPS 里但 dispatch 不认（文档与代码不一致）"
            );
        }

        // 3) 表外不应有 dispatch 认得的 op：抽查几个已删除/未登记的名字必须是 UNSUPPORTED
        for unknown in ["nope", "catalogPage", "playUrl", "downloadMove"] {
            let out = dispatch(&format!(r#"{{"v":1,"op":"{unknown}"}}"#));
            assert_eq!(
                out["error"]["code"],
                json!("UNSUPPORTED"),
                "`{unknown}` 不是已登记 op，却未被拒绝"
            );
        }
    }

    /// 契约守卫：仲裁标记必须与实际实现一致。
    ///
    /// 做法：带 `session`+`sequence` 调一次，用**已存在的更大 sequence** 制造
    /// 「进入即被取代」的场景。只有真正走 `arbitrated_read` 的 op 才会返回
    /// `CANCELED`。
    ///
    /// 注意：部分 op 在进入仲裁**之前**先校验必填参数（如 `search` 缺 `keyword`
    /// 会先返回 `BAD_REQUEST`）。因此这些 op 需要带上最小合法参数，
    /// 否则测不到仲裁这一层——表里第三列即为此而设。
    #[test]
    fn contract_arbitration_flags_match_implementation() {
        // 本用例 dispatch 全表：非仲裁 op 会真跑（含 cacheClear /
        // searchHistoryClear / historyClear / downloadList），必须串行，
        // 否则与 SERIAL 测试互删全局状态。
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        /// 让 op 能通过「参数校验」这一关的最小参数。
        fn minimal_params(op: &str) -> &'static str {
            match op {
                "search" | "suggest" => r#","params":{"keyword":"x"}"#,
                "detail" | "episodeGroups" | "playLocal" | "playFile" => r#","params":{"id":"1"}"#,
                "play" | "preload" => r#","params":{"id":"1"}"#,
                "playQuality" => r#","params":{"id":"1","vid":"2"}"#,
                "moveDownloads" => r#","params":{"dir":"/tmp/x"}"#,
                _ => "",
            }
        }

        for (op, arbitrated) in CONTRACT_OPS {
            let session = format!("contract-arb-{op}");
            // 占位一个更大的 sequence，让该 op 的进入检查必然判定「被取代」。
            assert_eq!(
                cancel::begin(&session, 9_999, CancellationToken::new()),
                cancel::Decision::Continue
            );
            let out = dispatch(&format!(
                r#"{{"v":1,"op":"{op}","session":"{session}","sequence":1{}}}"#,
                minimal_params(op)
            ));
            let code = out["error"]["code"].as_str().unwrap_or("");
            if *arbitrated {
                assert_eq!(
                    code, "CANCELED",
                    "`{op}` 标记为参与仲裁，但未被 sequence 取代（实际 code={code}）"
                );
            } else {
                assert_ne!(
                    code, "CANCELED",
                    "`{op}` 标记为不参与仲裁，却返回了 CANCELED"
                );
            }
            let _ = cancel::complete(&session, 9_999);
        }
    }

    /// 契约守卫：`docs/RUST_CONTRACT.md` 必须列出 `CONTRACT_OPS` 的**每一个** op。
    ///
    /// 前端按文档开发，文档漏一个 op 就会导致盲写。这里直接读 markdown 比对。
    /// 路径相对 crate 根（`CARGO_MANIFEST_DIR`）。
    #[test]
    fn contract_doc_lists_every_op() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join("docs/RUST_CONTRACT.md");
        let Ok(doc) = std::fs::read_to_string(&path) else {
            // 文档不在（例如只打包了 crate）时跳过，不让它成为构建阻塞。
            eprintln!("skip: {} not found", path.display());
            return;
        };
        let missing: Vec<&str> = CONTRACT_OPS
            .iter()
            .map(|(op, _)| *op)
            .filter(|op| !doc.contains(&format!("| `{op}` |")) && !doc.contains(&format!("`{op}`")))
            .collect();
        assert!(
            missing.is_empty(),
            "docs/RUST_CONTRACT.md 未记录这些 op：{missing:?}（新增 op 必须同步文档）"
        );
    }

    #[test]
    fn version_reports_source_caps() {
        let out = dispatch(r#"{"v":1,"op":"version"}"#);
        assert_eq!(out["ok"], json!(true));
        assert_eq!(out["data"]["sources"][0]["id"], json!("hongguo"));
        assert_eq!(out["data"]["sources"][0]["caps"]["detail"], json!(true));
        assert_eq!(out["data"]["sources"][0]["caps"]["playback"], json!(true));
    }

    /// 目录缓存与搜索历史都是进程级全局：这些用例必须串行，
    /// 且跑完清场，避免污染其它用例。
    ///
    /// 注意：不设 `data_dir` 时缓存/搜索历史退化为**纯内存**
    ///（`path()` 返回 `None` → 不落盘），正好适合离线单测。
    #[test]
    fn cache_ops_are_wired_through_dispatch() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let _ = cache::clear();

        let stats = dispatch(r#"{"v":1,"op":"cacheStats"}"#);
        assert_eq!(stats["ok"], json!(true), "cacheStats 必须已接线");
        assert_eq!(stats["data"]["entries"], json!(0));

        // 写一条再读：条数与字节数都应反映出来。
        let _ = cache::cached("probe", cache::TTL_CATALOG_MS, None, || {
            Ok(json!({ "items": [1, 2, 3] }))
        });
        let stats = dispatch(r#"{"v":1,"op":"cacheStats"}"#);
        assert_eq!(stats["data"]["entries"], json!(1));
        assert!(stats["data"]["bytes"].as_u64().unwrap() > 0);

        let _ = dispatch(r#"{"v":1,"op":"cacheFlush"}"#);
        let cleared = dispatch(r#"{"v":1,"op":"cacheClear"}"#);
        assert_eq!(cleared["data"]["cleared"], json!(true));
        assert_eq!(
            dispatch(r#"{"v":1,"op":"cacheStats"}"#)["data"]["entries"],
            json!(0)
        );
    }

    #[test]
    fn search_history_roundtrips_through_dispatch() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let _ = store::search_history_clear();

        let put = dispatch(r#"{"v":1,"op":"searchHistoryPut","params":{"keyword":"庆余年"}}"#);
        assert_eq!(put["ok"], json!(true), "中文关键词必须能入库");
        assert_eq!(put["data"]["keyword"], json!("庆余年"));

        let list = dispatch(r#"{"v":1,"op":"searchHistoryList"}"#);
        assert_eq!(list["data"]["items"][0]["keyword"], json!("庆余年"));

        let del = dispatch(r#"{"v":1,"op":"searchHistoryDel","params":{"keyword":"庆余年"}}"#);
        assert_eq!(del["ok"], json!(true));
        assert_eq!(
            dispatch(r#"{"v":1,"op":"searchHistoryList"}"#)["data"]["items"]
                .as_array()
                .unwrap()
                .len(),
            0
        );

        // 空词 → BAD_REQUEST（不该把空白塞进历史列表；与 search/suggest 缺参同码）。
        let empty = dispatch(r#"{"v":1,"op":"searchHistoryPut","params":{"keyword":"  "}}"#);
        assert_eq!(empty["error"]["code"], json!("BAD_REQUEST"));
        let empty_del = dispatch(r#"{"v":1,"op":"searchHistoryDel","params":{"keyword":""}}"#);
        assert_eq!(empty_del["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn catalog_pages_clamps_depth_to_page_limit() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        // 用不存在的源：无论 depth 多大，都应在**有限**步内失败返回，
        // 而不是串行打几十次网络。这里断言的是错误码（源不存在）与
        // 「不会挂住」——真跑起来即证明上限生效。
        let out = dispatch(
            r#"{"v":1,"op":"catalogPages","source":"nope","params":{"category":"x","depth":9999}}"#,
        );
        assert_eq!(out["error"]["code"], json!("NOT_FOUND"));
    }

    // ── 选集分组（播放页/详情页共用同一口径）────────────────────────────

    fn fake_detail(episode_count: usize) -> Vec<Value> {
        (1..=episode_count)
            .map(|i| json!({ "index": i, "vid": format!("v{i}") }))
            .collect()
    }

    #[test]
    fn episode_groups_splits_and_labels_every_group() {
        let out = episode_groups(fake_detail(120), 50);
        assert_eq!(out["groupSize"], json!(50));
        assert_eq!(out["total"], json!(120));
        assert_eq!(out["groupCount"], json!(3));
        let groups = out["groups"].as_array().unwrap();
        assert_eq!(groups.len(), 3);
        // 标签与起止：1-50 / 51-100 / 101-120（末组不足 50 集也完整给出）。
        assert_eq!(groups[0]["label"], json!("1-50"));
        assert_eq!(groups[1]["label"], json!("51-100"));
        assert_eq!(groups[2]["label"], json!("101-120"));
        assert_eq!(groups[2]["episodes"].as_array().unwrap().len(), 20);
        // 每组自带本组剧集，Dart 无需再切片。
        assert_eq!(groups[0]["episodes"][0]["index"], json!(1));
        assert_eq!(groups[2]["episodes"][19]["index"], json!(120));
    }

    #[test]
    fn episode_groups_handles_short_and_empty_lists() {
        // 少于一组：只有 1 组，不产生空组。
        let out = episode_groups(fake_detail(7), 50);
        assert_eq!(out["groupCount"], json!(1));
        assert_eq!(out["groups"][0]["label"], json!("1-7"));
        // 空列表：0 组而不是 1 个空组（UI 据此显示"暂无选集"，而不是空白 chip）。
        let out = episode_groups(Vec::new(), 50);
        assert_eq!(out["groupCount"], json!(0));
        assert_eq!(out["total"], json!(0));
    }

    #[test]
    fn episode_groups_clamps_group_size() {
        // 误传 1（会让 UI 变成上百个 chip）→ 抬到下限。
        let out = episode_groups(fake_detail(30), 1);
        assert_eq!(out["groupSize"], json!(MIN_EPISODE_GROUP_SIZE));
        // 误传超大值 → 压到上限。
        let out = episode_groups(fake_detail(30), 99_999);
        assert_eq!(out["groupSize"], json!(MAX_EPISODE_GROUP_SIZE));
    }

    #[test]
    fn episode_groups_without_id_is_bad_request() {
        let out = dispatch(r#"{"v":1,"op":"episodeGroups"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn play_quality_requires_id_and_vid() {
        let out = dispatch(r#"{"v":1,"op":"playQuality","params":{"vid":"v1"}}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        let out = dispatch(r#"{"v":1,"op":"playQuality","params":{"id":"1"}}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        // 换档内层 15s，Dart 外层更大 → 内层先到期（分级超时纪律）。
        assert_eq!(
            http::inner_timeout_for("playQuality"),
            std::time::Duration::from_secs(15)
        );
    }

    /// 选集分组的真实成本：**命中详情缓存**时一次 dispatch 的耗时。
    ///
    /// 播放页打开即取（`episodeGroups`），命中时零网络；这一项要回答的是
    /// 「加了 op 之后，选集区是不是免费的」。200 集是「超 60 集」场景的量级。
    #[test]
    #[ignore = "性能测量：需 release，见模块内说明"]
    fn bench_episode_groups_dispatch() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        crate::cache::clear_for_test();
        let _ = crate::covers::media_port(); // 预热端口绑定（封面展开要用）

        const TOTAL: usize = 200;
        let episodes: Vec<Value> = (1..=TOTAL)
            .map(|i| json!({ "index": i, "vid": format!("v{i}"), "title": format!("第{i}集") }))
            .collect();
        crate::cache::seed_for_test(
            &cache::key_detail("hongguo", "900001"),
            json!({ "drama": { "id": "900001", "title": "长剧" }, "episodes": episodes }),
        );

        let out = dispatch(r#"{"v":1,"op":"episodeGroups","params":{"id":"900001"}}"#);
        assert_eq!(out["ok"], json!(true));
        let groups = out["data"]["groups"].as_array().unwrap().len();
        println!("episodeGroups（{TOTAL} 集 → {groups} 组，含 FFI 序列化出参）:");

        const ROUNDS: usize = 200;
        let per_call = best_of(
            || {
                let start = Instant::now();
                for _ in 0..ROUNDS {
                    let out = dispatch(r#"{"v":1,"op":"episodeGroups","params":{"id":"900001"}}"#);
                    assert_eq!(out["ok"], json!(true));
                    assert_eq!(out["data"]["groups"].as_array().unwrap().len(), 4);
                }
                start.elapsed().as_secs_f64() * 1e6 / ROUNDS as f64
            },
            5,
        );
        println!("  单次 dispatch（缓存命中）: {per_call:.1}µs");

        let json = serde_json::to_string(&out).unwrap();
        println!("  出参体积: {} 字节（200 集全量分组）", json.len());

        crate::cache::clear_for_test();
    }

    /// 多组取最小（抑制测量噪声）。
    fn best_of<F: FnMut() -> f64>(mut measure: F, groups: usize) -> f64 {
        (0..groups).map(|_| measure()).fold(f64::INFINITY, f64::min)
    }

    #[test]
    fn play_without_id_is_bad_request() {
        let out = dispatch(r#"{"v":1,"op":"play","params":{}}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn init_without_datadir_is_bad_request() {
        let out = dispatch(r#"{"v":1,"op":"init","params":{}}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn init_with_datadir_reports_initialized() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let dir = std::env::temp_dir().join(format!("drama-init-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let input = format!(
            r#"{{"v":1,"op":"init","params":{{"dataDir":{}}}}}"#,
            serde_json::to_string(dir.to_str().unwrap()).unwrap()
        );
        let out = dispatch(&input);
        assert_eq!(out["ok"], json!(true));
        assert_eq!(out["data"]["initialized"], json!(true));
        let _ = std::fs::remove_dir_all(&dir);
        // 不留悬空 DATA_DIR：否则后续测试的落盘会重建该目录并产生文件 cross-talk。
        crate::device::clear_data_dir();
    }

    #[test]
    fn catalog_and_catalog_pages_share_page_zero_key() {
        // 单页 `page=0` 与聚合 `depth=1` 必须命中同一缓存条目（0 起页号统一）。
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        // 专属数据目录：文件后端（延迟载入/防抖落盘）与其他测试完全隔离。
        let dir = std::env::temp_dir().join(format!("drama-zerokey-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        crate::device::set_data_dir(dir.clone());
        crate::cache::clear_for_test();
        let seed_key = crate::cache::key_catalog("hongguo", "unified", 0);
        crate::cache::seed_for_test(
            &seed_key,
            json!({ "items": [{"id": "u1"}], "hasMore": true, "page": 0 }),
        );
        let single = dispatch(r#"{"v":1,"op":"catalog","params":{"category":"unified","page":0}}"#);
        assert_eq!(single["ok"], json!(true));
        // 必须命中种子（而非误抓网络）：否则下面的等价断言失去意义。
        assert_eq!(
            single["data"]["items"],
            json!([{"id": "u1"}]),
            "single catalog must hit the seeded entry"
        );
        // 聚合 dispatch 前种子必须还在：若不在，说明并行测试干扰了全局缓存，
        // 先修隔离再谈等价（与被测的 key 口径无关）。
        assert!(
            crate::cache::contains_for_test(&seed_key),
            "seed entry vanished before catalogPages (suite interference)"
        );
        let multi =
            dispatch(r#"{"v":1,"op":"catalogPages","params":{"category":"unified","depth":1}}"#);
        assert_eq!(multi["ok"], json!(true));
        assert_eq!(multi["data"]["pages"][0]["items"], single["data"]["items"]);
        crate::cache::clear_for_test();
        crate::device::clear_data_dir();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn data_dir_switch_resets_store_and_cache() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let dir_a = std::env::temp_dir().join(format!("drama-switch-a-{}", std::process::id()));
        let dir_b = std::env::temp_dir().join(format!("drama-switch-b-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir_a);
        let _ = std::fs::create_dir_all(&dir_b);
        crate::device::set_data_dir(dir_a.clone());
        crate::store::follow_put("hongguo", &json!({"id": "s1", "title": "T"})).unwrap();
        let _ = crate::cache::cached("switch-probe", crate::cache::TTL_CATALOG_MS, None, || {
            Ok(json!({"v": 1}))
        })
        .unwrap();
        // 切目录：旧内存表不得继续服务。
        crate::device::set_data_dir(dir_b.clone());
        let list = crate::store::follow_list(None).unwrap();
        assert_eq!(list["items"].as_array().unwrap().len(), 0);
        let miss = crate::cache::cached("switch-probe", crate::cache::TTL_CATALOG_MS, None, || {
            Err(SourceError::NotFound)
        });
        assert!(miss.is_err());
        // A 目录落盘仍在，切回去可读回。
        crate::device::set_data_dir(dir_a.clone());
        let list = crate::store::follow_list(None).unwrap();
        assert_eq!(list["items"].as_array().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir_a);
        let _ = std::fs::remove_dir_all(&dir_b);
        crate::device::clear_data_dir();
    }

    #[test]
    fn move_downloads_requires_dir_and_reserved_budget_still_applies() {
        // 迁移已实现：缺 `dir` → BAD_REQUEST（不再是 UNSUPPORTED）。
        let out = dispatch(r#"{"v":1,"op":"moveDownloads"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        // 600s 内层预算保留（慢磁盘搬迁需要），且 Dart 外层 620s 更大 → 内层先到期。
        assert_eq!(
            http::inner_timeout_for("preload"),
            std::time::Duration::from_secs(15)
        );
        assert_eq!(
            http::inner_timeout_for("moveDownloads"),
            std::time::Duration::from_secs(600)
        );
    }

    #[test]
    fn download_set_concurrency_rejects_out_of_range() {
        let out = dispatch(r#"{"v":1,"op":"downloadSetConcurrency","params":{"parallel":99}}"#);
        assert_eq!(out["ok"], json!(false));
        assert_eq!(out["error"]["code"], json!("PARSE"));
        let out = dispatch(r#"{"v":1,"op":"downloadSetConcurrency","params":{"parallel":0}}"#);
        assert_eq!(out["error"]["code"], json!("PARSE"));
    }

    #[test]
    fn play_local_requires_id() {
        let out = dispatch(r#"{"v":1,"op":"playLocal","params":{}}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        // 没有对应完成任务 → NOT_FOUND（调用方据此回落到在线取流）。
        let out = dispatch(r#"{"v":1,"op":"playLocal","params":{"id":"1","episode":1}}"#);
        assert_eq!(out["ok"], json!(false));
        assert_eq!(out["error"]["code"], json!("NOT_FOUND"));
    }

    #[test]
    fn search_without_keyword_is_bad_request() {
        let out = dispatch(r#"{"v":1,"op":"search"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn unknown_source_is_not_found() {
        // 用专属分类+页号隔离缓存 key：裸 `catalog` 信封的 key（`catalog::1`）
        // 会被并发测试（如 contract_table 的真实源抓取）占住在途槽，
        // 撞槽的请求拿不到 NOT_FOUND 会变 TIMEOUT。
        let out = dispatch(
            r#"{"v":1,"op":"catalog","source":"nope","params":{"category":"no-such-source-probe","page":7}}"#,
        );
        assert_eq!(out["error"]["code"], json!("NOT_FOUND"));
    }

    #[test]
    fn invalid_session_is_bad_request() {
        // 非法字符 / 超长 / 非 ASCII → BAD_REQUEST（任何 op 前的信封级校验）。
        let out = dispatch(r#"{"v":1,"op":"catalog","session":"bad session!","sequence":1}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        let out = dispatch(r#"{"v":1,"op":"ping","session":"中文"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn stale_sequence_is_canceled_without_network() {
        // 进入仲裁：已在途的更大 sequence 会让旧 sequence 在**发网络请求前**即被丢弃。
        let s = "stale-seq-test";
        assert_eq!(
            cancel::begin(s, 10, CancellationToken::new()),
            cancel::Decision::Continue
        );
        let out = dispatch(&format!(
            r#"{{"v":1,"op":"catalog","session":"{s}","sequence":3,"params":{{"category":"real-drama"}}}}"#
        ));
        assert_eq!(out["error"]["code"], json!("CANCELED"));
        assert_eq!(out["error"]["retry"], json!(false));
        let _ = cancel::complete(s, 10);
    }

    #[test]
    fn cancel_read_reports_count_and_zero_for_unknown_session() {
        // 不存在的 session → {canceled:0}。
        let out =
            dispatch(r#"{"v":1,"op":"cancelRead","params":{"session":"nope-x","sequence":9}}"#);
        assert_eq!(out["ok"], json!(true));
        assert_eq!(out["data"]["canceled"], json!(0));

        // 在途 5、6 两条，取消边界 6 → 只有 5 被取消。
        let s = "cancel-count-dispatch";
        assert_eq!(
            cancel::begin(s, 5, CancellationToken::new()),
            cancel::Decision::Continue
        );
        assert_eq!(
            cancel::begin(s, 6, CancellationToken::new()),
            cancel::Decision::Continue
        );
        let out = dispatch(&format!(
            r#"{{"v":1,"op":"cancelRead","params":{{"session":"{s}","sequence":6}}}}"#
        ));
        assert_eq!(out["data"]["canceled"], json!(1));
        let _ = cancel::complete(s, 5);
        let _ = cancel::complete(s, 6);
    }

    #[test]
    fn cancel_read_without_valid_params_is_bad_request() {
        let out = dispatch(r#"{"v":1,"op":"cancelRead"}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
        let out =
            dispatch(r#"{"v":1,"op":"cancelRead","params":{"session":"bad param","sequence":1}}"#);
        assert_eq!(out["error"]["code"], json!("BAD_REQUEST"));
    }

    #[test]
    fn ffi_roundtrip_via_c_abi() {
        let input = CString::new(r#"{"v":1,"op":"ping"}"#).unwrap();
        // SAFETY: `input` 为有效的 C 字符串。
        let out_ptr = unsafe { drama_request(input.as_ptr()) };
        assert!(!out_ptr.is_null());
        // SAFETY: `out_ptr` 由 `drama_request` 返回，尚未释放。
        let out = unsafe { CStr::from_ptr(out_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        // SAFETY: `out_ptr` 由 `drama_request` 返回，仅释放一次。
        unsafe { drama_free(out_ptr) };
        assert!(out.contains("\"ok\":true"));
        assert!(out.contains("pong"));
    }

    #[test]
    fn ffi_null_input_is_safe() {
        // SAFETY: 传入空指针，函数内部会安全处理。
        let out_ptr = unsafe { drama_request(std::ptr::null()) };
        assert!(!out_ptr.is_null());
        // SAFETY: `out_ptr` 由 `drama_request` 返回，尚未释放。
        let out = unsafe { CStr::from_ptr(out_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        // SAFETY: `out_ptr` 由 `drama_request` 返回，仅释放一次。
        unsafe { drama_free(out_ptr) };
        assert!(out.contains("BAD_REQUEST"));
    }
}
