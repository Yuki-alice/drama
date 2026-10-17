//! 本地回环媒体代理（播放交付面）。
//!
//! 播放器只打开本机地址（`http://127.0.0.1:{port}/play/{token}/video.mp4`），
//! 不直接碰源站。明文流透传（注入 Referer、透传 Range）；加密流在首读时
//! 解析 moov 建样本表、重写 moov、下发解密后的干净 MP4——播放器零配置。
//!
//! 安全模型：只绑 `127.0.0.1`；每次 `play` 颁发 token（32 位十六进制，
//! 30 分钟过期）；token 即能力，不做额外鉴权——同一设备上的其他应用理论上
//! 可探测端口，但拿不到 token 就拿不到内容，会话过期即失效。

use crate::install_id;

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use aes::Aes128;
use aes::cipher::{BlockCipherEncrypt, KeyInit};
use once_cell::sync::Lazy;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::decrypt::{self, MoviePlan};


/// 会话有效期。
const SESSION_TTL: Duration = Duration::from_secs(30 * 60);
/// 会话上限（LRU 淘汰最旧）。
const MAX_SESSIONS: usize = 8;
/// 请求头读取上限（只读请求行 + 头）。
const MAX_HEAD_BYTES: usize = 64 * 1024;
/// 首读探测长度（moov 一般在前部；不够再取尾）。
const PROBE_LEN: u64 = 2 * 1024 * 1024;
/// 单次响应解密上限（播放器通常只要几百 KiB~几 MiB）。
/// 实测 AES-CTR 约 5.8GB/s（`decrypt::bench_decrypt_sample_throughput`），
/// 32MiB 解密约 6ms——该上限约束的是单次响应内存，不是 CPU。
const MAX_DECRYPT_SPAN: u64 = 32 * 1024 * 1024;
/// 全量 GET 下发窗口（流式，不一次性缓冲）。
const STREAM_WINDOW: u64 = 4 * 1024 * 1024;

struct CachedPlan {
    plan: MoviePlan,
    total_virtual: u64,
}

struct Session {
    url: String,
    referer: &'static str,
    user_agent: String,
    key: Option<[u8; 16]>,
    /// 本地文件源（离线播放）；`Some` 时忽略 url 回源，读磁盘。
    file: Option<std::path::PathBuf>,
    plan: Mutex<Option<Arc<CachedPlan>>>,
    expires: Instant,
    last_used: Instant,
}

static SESSIONS: Lazy<Mutex<HashMap<String, Session>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static TOKEN_COUNTER: AtomicU64 = AtomicU64::new(1);
static BOUND_PORT: OnceLock<u16> = OnceLock::new();

/// 网关独立运行时（与元数据 RUNTIME 分离）：`register` 可在任何线程
/// block_on，永远不会与调用方所在的运行时嵌套；媒体流量也跑在这里，
/// 不占元数据请求的 worker。
static GATEWAY_RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("media-gateway")
        .enable_all()
        .build()
        .expect("build gateway runtime")
});

/// 媒体回源客户端（独立于元数据客户端：**没有总超时**，
/// 长视频边下边播不能被总超时切断；连接超时保留）。
static MEDIA_CLIENT: Lazy<reqwest::Client> = Lazy::new(|| {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .build()
        .expect("build media client")
});

/// 确保代理在跑，返回端口。已在跑则直接返回。
/// 必须在 Tokio 上下文内调用（`play` op 经 `RUNTIME.block_on` 进入，满足条件）。
/// 网关首选端口区间。
///
/// **为什么不用 `:0`（内核随机分配）**：封面代理 URL 会**落盘进目录缓存**
/// （见 `covers` 模块），而 URL 里含端口。若每次启动换端口，重启后缓存里
/// 的封面地址全部指向一个没人监听的端口，海报墙整体退化成渐变占位——
/// 这是实测发现的问题。改为在固定区间内取第一个可用端口，使端口在
/// 绝大多数情况下跨启动稳定（被占用时才顺延）。
const PORT_RANGE_START: u16 = 47_800;
const PORT_RANGE_END: u16 = 47_899;

async fn ensure_running() -> Result<u16, String> {
    if let Some(port) = BOUND_PORT.get() {
        return Ok(*port);
    }
    let mut listener = None;
    let mut last_err = String::new();
    for port in PORT_RANGE_START..=PORT_RANGE_END {
        match tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
            Ok(l) => {
                listener = Some(l);
                break;
            }
            Err(e) => last_err = e.to_string(),
        }
    }
    let listener = match listener {
        Some(l) => l,
        // 区间全被占（极端情况）：退回内核随机端口。此时本次会话的封面
        // 仍可用，只是重启后缓存里的旧地址需等目录缓存过期才会自愈。
        None => tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| format!("bind loopback: {e} (range last err: {last_err})"))?,
    };
    let port = listener
        .local_addr()
        .map_err(|e| format!("loopback addr: {e}"))?
        .port();
    let _ = BOUND_PORT.set(port);
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            tokio::spawn(async move {
                if let Err(e) = serve_connection(stream).await {
                    tracing::warn!("gateway connection failed: {e}");
                }
            });
        }
    });
    Ok(port)
}

/// 注册一次播放会话，返回播放器可直接打开的本地 URL。
/// 同步函数：在独立网关运行时上 block_on，与调用方所在的运行时
/// （FFI 线程无运行时、或元数据 RUNTIME worker）永远不嵌套。
pub fn register(
    url: &str,
    referer: &'static str,
    user_agent: String,
    key: Option<[u8; 16]>,
) -> Result<String, String> {
    let port = ensure_port_blocking()?;
    sweep_and_evict();
    let token = new_token();
    let now = Instant::now();
    let session = Session {
        url: url.to_owned(),
        referer,
        user_agent,
        key,
        file: None,
        plan: Mutex::new(None),
        expires: now + SESSION_TTL,
        last_used: now,
    };
    SESSIONS
        .lock()
        .expect("sessions poisoned")
        .insert(token.clone(), session);
    Ok(format!("http://127.0.0.1:{port}/play/{token}/video.mp4"))
}

/// 注册文件会话（离线播放）：`key` 为空表示明文直通，否则走同一套
/// moov 改写 + 样本解密（与在线链路共用计划缓存逻辑）。
pub fn register_file(
    path: &std::path::Path,
    user_agent: String,
    key: Option<[u8; 16]>,
) -> Result<String, String> {
    if !path.is_file() {
        return Err("file not found".to_owned());
    }
    let port = ensure_port_blocking()?;
    sweep_and_evict();
    let token = new_token();
    let now = Instant::now();
    let session = Session {
        url: String::new(),
        referer: "file",
        user_agent,
        key,
        file: Some(path.to_owned()),
        plan: Mutex::new(None),
        expires: now + SESSION_TTL,
        last_used: now,
    };
    SESSIONS
        .lock()
        .expect("sessions poisoned")
        .insert(token.clone(), session);
    Ok(format!("http://127.0.0.1:{port}/play/{token}/video.mp4"))
}

/// 确保监听：bind + 把 accept 循环抛到网关运行时上。
fn ensure_port_blocking() -> Result<u16, String> {
    if let Some(port) = BOUND_PORT.get() {
        return Ok(*port);
    }
    GATEWAY_RT
        .block_on(ensure_running())
        .map_err(|e| e.to_string())
}

/// 供封面代理复用同一端口（本机只占一个回环端口，便于排查与放行）。
///
/// 与 [`register`] 同约束：可在任意线程调用（内部 `block_on` 网关运行时）。
pub fn ensure_port() -> Result<u16, String> {
    ensure_port_blocking()
}

fn new_token() -> String {
    let n = TOKEN_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let digest = md5::compute(format!("{}:{}:{}", install_id(), n, nanos));
    digest.0.iter().map(|b| format!("{b:02x}")).collect()
}

/// 过期 sweep + 超量 LRU 淘汰（注册时顺带做，不另起任务）。
fn sweep_and_evict() {
    let now = Instant::now();
    let mut map = SESSIONS.lock().expect("sessions poisoned");
    map.retain(|_, s| s.expires > now);
    while map.len() >= MAX_SESSIONS {
        let oldest = map
            .iter()
            .min_by_key(|(_, s)| s.last_used)
            .map(|(k, _)| k.clone());
        match oldest {
            Some(k) => {
                map.remove(&k);
            }
            None => break,
        }
    }
}

struct SessionView {
    url: String,
    referer: &'static str,
    user_agent: String,
    key: Option<[u8; 16]>,
    file: Option<std::path::PathBuf>,
}

fn lookup(token: &str) -> Option<SessionView> {
    let mut map = SESSIONS.lock().expect("sessions poisoned");
    let session = map.get_mut(token)?;
    if session.expires <= Instant::now() {
        map.remove(token);
        return None;
    }
    session.last_used = Instant::now();
    Some(SessionView {
        url: session.url.clone(),
        referer: session.referer,
        user_agent: session.user_agent.clone(),
        key: session.key,
        file: session.file.clone(),
    })
}

/// 数据源大小：文件读元数据，回源发 HEAD（失败回退首字节探测）。
async fn source_size(view: &SessionView) -> Result<u64, String> {
    if let Some(path) = view.file.as_deref() {
        return std::fs::metadata(path)
            .map(|m| m.len())
            .map_err(|e| format!("local file: {e}"));
    }
    upstream_size(&view.url, view.referer, &view.user_agent).await
}

/// 数据源区间读：文件直接读磁盘，回源走 Range。
async fn source_range(view: &SessionView, start: u64, end: u64) -> Result<Vec<u8>, String> {
    if start > end {
        return Err("bad range".to_owned());
    }
    if let Some(path) = view.file.as_deref() {
        return read_file_range(path, start, end).map_err(|e| format!("local file: {e}"));
    }
    upstream_range(&view.url, view.referer, &view.user_agent, start, end).await
}

fn read_file_range(path: &std::path::Path, start: u64, end: u64) -> Result<Vec<u8>, String> {
    use std::io::{Read, Seek, SeekFrom};
    let len = end - start + 1;
    if len > MAX_DECRYPT_SPAN * 4 {
        return Err("range too large".to_owned());
    }
    let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    file.seek(SeekFrom::Start(start))
        .map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; len as usize];
    file.read_exact(&mut buf).map_err(|e| e.to_string())?;
    Ok(buf)
}

/// 预热：对 `proxyUrl` 建改写计划并解密首个 64KiB（结果丢弃）。
/// 返回实际预热字节数；明文流只预热上游首字节连接。
/// 同步函数（内部经网关运行时 block_on，与 `register` 同约束）。
pub fn warm_first_window(proxy_url: &str, window: u64) -> Result<u64, String> {
    let token = proxy_url
        .split("?")
        .next()
        .unwrap_or("")
        .strip_prefix("http://127.0.0.1:")
        .and_then(|rest| rest.split("/play/").nth(1))
        .and_then(|rest| rest.split("/").next())
        .unwrap_or("");
    let view = lookup(token).ok_or_else(|| "session expired".to_owned())?;
    drama_net::handle().block_on(async {
        if view.key.is_none() {
            let bytes = source_range(&view, 0, window - 1).await?;
            return Ok(bytes.len() as u64);
        }
        let key = view.key.ok_or_else(|| "no key".to_owned())?;
        let cached = match cached_plan(token) {
            Some(p) => p,
            None => {
                let built = build_plan(&view, &key).await?;
                let cached = Arc::new(built);
                store_plan(token, cached.clone());
                cached
            }
        };
        let end = window.min(cached.total_virtual).saturating_sub(1);
        let body = render_virtual(&cached.plan, &view, &key, 0, end).await?;
        Ok(body.len() as u64)
    })
}

fn cached_plan(token: &str) -> Option<Arc<CachedPlan>> {
    SESSIONS
        .lock()
        .expect("sessions poisoned")
        .get(token)
        .and_then(|s| s.plan.lock().expect("plan poisoned").clone())
}

fn store_plan(token: &str, plan: Arc<CachedPlan>) {
    if let Some(session) = SESSIONS.lock().expect("sessions poisoned").get(token) {
        *session.plan.lock().expect("plan poisoned") = Some(plan);
    }
}

async fn serve_connection(mut stream: tokio::net::TcpStream) -> Result<(), String> {
    let mut head = Vec::with_capacity(4096);
    let mut buf = [0u8; 4096];
    loop {
        let n = stream.read(&mut buf).await.map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("client closed".to_owned());
        }
        head.extend_from_slice(&buf[..n]);
        if head.len() > MAX_HEAD_BYTES {
            return Err("head too large".to_owned());
        }
        if head.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    let head_str = String::from_utf8_lossy(&head);
    let mut lines = head_str.split("\r\n");
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    if method != "GET" && method != "HEAD" {
        return respond_simple(&mut stream, 405, "method not allowed").await;
    }
    let is_head = method == "HEAD";
    let path = target.split("?").next().unwrap_or("");

    // 封面代理：与媒体走同一端口，路径前缀区分（`/img/{token}`）。
    // token 形如 `{base64url(cdnUrl)}.{sig}`，由 covers 模块自行校验签名；
    // 这里只做基本长度/字符集粗筛，避免把畸形串喂给解析。
    if let Some(token) = path.strip_prefix("/img/") {
        let looks_valid = token.len() <= 2048
            && token.contains('.')
            && token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.');
        if !looks_valid {
            return respond_simple(&mut stream, 404, "not found").await;
        }
        return crate::covers::serve(&mut stream, token, is_head).await;
    }

    let token = path
        .strip_prefix("/play/")
        .and_then(|rest| rest.split("/").next())
        .unwrap_or("");
    if token.len() != 32 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
        return respond_simple(&mut stream, 404, "not found").await;
    }
    let Some(view) = lookup(token) else {
        return respond_simple(&mut stream, 404, "session expired").await;
    };
    let mut range: Option<String> = None;
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some(value) = line
            .strip_prefix("Range:")
            .or_else(|| line.strip_prefix("range:"))
        {
            range = Some(value.trim().to_owned());
        }
    }
    if view.key.is_some() {
        serve_decrypted(&mut stream, token, &view, range.as_deref(), is_head).await
    } else if view.file.is_some() {
        serve_file_direct(&mut stream, &view, range.as_deref(), is_head).await
    } else {
        forward(
            &mut stream,
            &view.url,
            view.referer,
            &view.user_agent,
            range,
            is_head,
        )
        .await
    }
}

/// 明文文件直通（离线）：读磁盘区间下发，无解密无改写。
async fn serve_file_direct(
    stream: &mut tokio::net::TcpStream,
    view: &SessionView,
    range: Option<&str>,
    is_head: bool,
) -> Result<(), String> {
    let total = source_size(view).await?;
    if is_head {
        let head = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        );
        stream
            .write_all(head.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    match range {
        Some(spec) => {
            let Some((start, end)) = parse_range(spec, total) else {
                return respond_simple(stream, 416, "range not satisfiable").await;
            };
            let body = source_range(view, start, end).await?;
            let head = format!(
                "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream
                .write_all(head.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
            stream.write_all(&body).await.map_err(|e| e.to_string())?;
            Ok(())
        }
        None => {
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            );
            stream
                .write_all(head.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
            let mut cursor = 0u64;
            while cursor < total {
                let chunk_end = (cursor + STREAM_WINDOW - 1).min(total - 1);
                let bytes = source_range(view, cursor, chunk_end).await?;
                stream.write_all(&bytes).await.map_err(|e| e.to_string())?;
                cursor = chunk_end + 1;
            }
            Ok(())
        }
    }
}

async fn respond_simple(
    stream: &mut tokio::net::TcpStream,
    status: u16,
    message: &str,
) -> Result<(), String> {
    let body = message.as_bytes();
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len(),
        reason = if status == 404 { "Not Found" } else { "Error" },
    );
    stream
        .write_all(head.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    stream.write_all(body).await.map_err(|e| e.to_string())?;
    Ok(())
}

/// 回源请求构造（Range 可选）。
async fn upstream_get(
    url: &str,
    referer: &'static str,
    user_agent: &str,
    range: Option<&str>,
) -> Result<reqwest::Response, String> {
    let mut req = MEDIA_CLIENT
        .get(url)
        .header("Referer", referer)
        .header("User-Agent", user_agent);
    if let Some(range) = range {
        req = req.header("Range", range);
    }
    req.send().await.map_err(|e| format!("upstream: {e}"))
}

/// 明文透传：透传 Range，注入 Referer/UA，透传 200/206 与媒体头，流式下发。
async fn forward(
    stream: &mut tokio::net::TcpStream,
    url: &str,
    referer: &'static str,
    user_agent: &str,
    range: Option<String>,
    is_head: bool,
) -> Result<(), String> {
    let resp = upstream_get(url, referer, user_agent, range.as_deref()).await?;
    let status = resp.status().as_u16();
    if status != 200 && status != 206 {
        return respond_simple(stream, 502, "upstream unavailable").await;
    }
    let mut head = format!(
        "HTTP/1.1 {status} {}\r\nConnection: close\r\n",
        if status == 206 {
            "Partial Content"
        } else {
            "OK"
        }
    );
    for name in [
        "content-type",
        "content-length",
        "content-range",
        "accept-ranges",
    ] {
        if let Some(value) = resp.headers().get(name)
            && let Ok(text) = value.to_str()
        {
            head.push_str(&format!("{name}: {text}\r\n"));
        }
    }
    head.push_str("\r\n");
    stream
        .write_all(head.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    if is_head {
        return Ok(());
    }
    let mut resp = resp;
    loop {
        match resp.chunk().await {
            Ok(Some(chunk)) => stream.write_all(&chunk).await.map_err(|e| e.to_string())?,
            Ok(None) => break,
            Err(e) => return Err(format!("upstream body: {e}")),
        }
    }
    Ok(())
}

/// 虚拟 Range 解析：`A-B` / `A-` / `-N`。
fn parse_range(header: &str, total: u64) -> Option<(u64, u64)> {
    let spec = header.strip_prefix("bytes=")?.trim();
    if let Some(suffix) = spec.strip_prefix('-') {
        let n: u64 = suffix.parse().ok()?;
        if n == 0 || total == 0 {
            return None;
        }
        let n = n.min(total);
        return Some((total - n, total - 1));
    }
    let (start_s, end_s) = spec.split_once('-')?;
    let start: u64 = start_s.trim().parse().ok()?;
    let end = if end_s.trim().is_empty() {
        total.saturating_sub(1)
    } else {
        end_s.trim().parse().ok()?
    };
    if start >= total {
        return None;
    }
    Some((start, end.min(total - 1)))
}

/// 加密下发：moov 改写缓存 + 样本解密。
async fn serve_decrypted(
    stream: &mut tokio::net::TcpStream,
    token: &str,
    view: &SessionView,
    range: Option<&str>,
    is_head: bool,
) -> Result<(), String> {
    let key = view.key.ok_or_else(|| "no key".to_owned())?;
    let cached = match cached_plan(token) {
        Some(p) => p,
        None => {
            let built = build_plan(view, &key).await?;
            let cached = Arc::new(built);
            store_plan(token, cached.clone());
            cached
        }
    };
    let total = cached.total_virtual;
    if is_head {
        let head = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        );
        stream
            .write_all(head.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    match range {
        Some(spec) => {
            let Some((start, end)) = parse_range(spec, total) else {
                return respond_simple(stream, 416, "range not satisfiable").await;
            };
            if end - start + 1 > MAX_DECRYPT_SPAN {
                return respond_simple(stream, 416, "range too large").await;
            }
            let body = render_virtual(&cached.plan, view, &key, start, end).await?;
            let head = format!(
                "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream
                .write_all(head.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
            stream.write_all(&body).await.map_err(|e| e.to_string())?;
            Ok(())
        }
        None => {
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            );
            stream
                .write_all(head.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
            stream_virtual(&cached.plan, view, &key, total, stream).await
        }
    }
}

/// 建改写计划：取大小 → 前部取 moov → 不足取尾。
async fn build_plan(view: &SessionView, key: &[u8; 16]) -> Result<CachedPlan, String> {
    let file_size = source_size(view).await?;
    let front_len = PROBE_LEN.min(file_size);
    let front = source_range(view, 0, front_len - 1).await?;
    match decrypt::analyze_moov(&front, 0, key) {
        Ok(raw) => finish_with_avcc(raw, view, key, &front, file_size).await,
        Err(_) if file_size > front_len => {
            let tail_len = PROBE_LEN.min(file_size);
            let tail = source_range(view, file_size - tail_len, file_size - 1).await?;
            let raw = decrypt::analyze_moov(&tail, file_size - tail_len, key)
                .map_err(|e| format!("moov analyze: {e}"))?;
            finish_with_avcc(raw, view, key, &front, file_size).await
        }
        Err(e) => Err(format!("moov analyze: {e}")),
    }
}

/// 取首视频样本解密出 SPS/PPS 后终定（取不到则按无 avcC 终定）。
async fn finish_with_avcc(
    raw: decrypt::RawPlan,
    view: &SessionView,
    key: &[u8; 16],
    front: &[u8],
    file_size: u64,
) -> Result<CachedPlan, String> {
    let mut avcc = None;
    // 仅当视频轨还原为 avc1 且缺少 avcC 时合成；自带 hvcC/avcC 的直接终定。
    if raw.needs_avcc
        && let Some((start, end)) = raw.first_video
        && end > start
        && end - start <= 4 * 1024 * 1024
    {
        let bytes = if (end as usize) <= front.len() {
            front[start as usize..end as usize].to_vec()
        } else {
            source_range(view, start, end - 1).await?
        };
        let mut decrypted = bytes;
        let iv = raw
            .samples
            .iter()
            .find(|s| s.start == start)
            .map(|s| s.iv)
            .ok_or_else(|| "first video sample not in table".to_owned())?;
        crate::decrypt::decrypt_sample(key, &iv, &mut decrypted);
        if let Some((sps, pps)) = decrypt::extract_sps_pps(&decrypted) {
            avcc = decrypt::build_avcc(&sps, &pps);
        }
    }
    let plan = decrypt::finalize_plan(raw, avcc).map_err(|e| format!("finalize: {e}"))?;
    Ok(finish_plan(plan, file_size))
}

fn finish_plan(plan: decrypt::MoviePlan, file_size: u64) -> CachedPlan {
    let total_virtual = (file_size as i64 + plan.delta) as u64;
    CachedPlan {
        plan,
        total_virtual,
    }
}

async fn upstream_size(url: &str, referer: &'static str, user_agent: &str) -> Result<u64, String> {
    let resp = MEDIA_CLIENT
        .head(url)
        .header("Referer", referer)
        .header("User-Agent", user_agent)
        .send()
        .await
        .map_err(|e| format!("upstream head: {e}"))?;
    if let Some(len) = resp.headers().get("content-length")
        && let Ok(text) = len.to_str()
        && let Ok(n) = text.trim().parse::<u64>()
        && n > 0
    {
        return Ok(n);
    }
    // 无长度：取首字节从 Content-Range 读总量。
    let resp = upstream_get(url, referer, user_agent, Some("bytes=0-0")).await?;
    let text = resp
        .headers()
        .get("content-range")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_owned();
    text.rsplit('/')
        .next()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|n| *n > 0)
        .ok_or_else(|| "unknown upstream size".to_owned())
}

async fn upstream_range(
    url: &str,
    referer: &'static str,
    user_agent: &str,
    start: u64,
    end: u64,
) -> Result<Vec<u8>, String> {
    let resp = upstream_get(
        url,
        referer,
        user_agent,
        Some(&format!("bytes={start}-{end}")),
    )
    .await?;
    if resp.status().as_u16() != 206 {
        return Err("upstream range unsupported".to_owned());
    }
    resp.bytes()
        .await
        .map(|b| b.to_vec())
        .map_err(|e| format!("upstream body: {e}"))
}

/// 渲染虚拟区间 `[start, end]`：前缀直取 + 新 moov + 后缀取回解密。
async fn render_virtual(
    plan: &decrypt::MoviePlan,
    view: &SessionView,
    key: &[u8; 16],
    start: u64,
    end: u64,
) -> Result<Vec<u8>, String> {
    let moov_v_start = plan.moov_start;
    let moov_v_end = moov_v_start + plan.new_moov.len() as u64;
    let mut out = Vec::with_capacity((end - start + 1).min(MAX_DECRYPT_SPAN) as usize);
    // 前缀（moov 之前，原样）。
    if start < moov_v_start {
        let take_end = end.min(moov_v_start - 1);
        let bytes = source_range(view, start, take_end).await?;
        out.extend_from_slice(&bytes);
    }
    // 新 moov。
    if end >= moov_v_start && start < moov_v_end {
        let s = start.max(moov_v_start) - moov_v_start;
        let e = end.min(moov_v_end - 1) - moov_v_start;
        out.extend_from_slice(&plan.new_moov[s as usize..=e as usize]);
    }
    // 后缀（moov 之后：回映射到原偏移，解密相交样本）。
    if end >= moov_v_end {
        let s = start.max(moov_v_end);
        // 虚拟偏移 → 原偏移：减去 moov 长度差。
        let orig_s = (s as i64 - plan.delta) as u64;
        let orig_e = (end as i64 - plan.delta) as u64;
        let mut bytes = source_range(view, orig_s, orig_e).await?;
        for sample in &plan.samples {
            if sample.end <= orig_s || sample.start > orig_e {
                continue;
            }
            let o0 = sample.start.max(orig_s) - orig_s;
            let o1 = sample.end.min(orig_e + 1) - orig_s;
            let slot = &mut bytes[o0 as usize..o1 as usize];
            // CTR 流位置相关：样本内偏移除首块余量后逐块解密。
            decrypt_range(
                key,
                &sample.iv,
                (sample.start.max(orig_s) - sample.start) as usize,
                slot,
            );
        }
        out.extend_from_slice(&bytes);
    }
    Ok(out)
}

/// 按样本内偏移解密区间（CTR 计数器从样本 IV 起算）。
fn decrypt_range(key: &[u8; 16], iv: &[u8; 16], sample_off: usize, data: &mut [u8]) {
    let cipher = Aes128::new(key.into());
    let mut block_index = (sample_off / 16) as u64;
    let mut pos = sample_off;
    // 首块余量。
    let rem = sample_off % 16;
    if rem != 0 && pos < sample_off + data.len() {
        let mut ks = counter_block(iv, block_index);
        cipher.encrypt_block((&mut ks).into());
        let take = (16 - rem).min(data.len());
        for (i, b) in data[..take].iter_mut().enumerate() {
            *b ^= ks[rem + i];
        }
        pos += take;
        block_index += 1;
    }
    while pos < sample_off + data.len() {
        let mut ks = counter_block(iv, block_index);
        cipher.encrypt_block((&mut ks).into());
        let end = (pos + 16).min(sample_off + data.len());
        let off = pos - sample_off;
        for (i, b) in data[off..end - sample_off].iter_mut().enumerate() {
            *b ^= ks[i];
        }
        pos = end;
        block_index += 1;
    }
}

fn counter_block(iv: &[u8; 16], index: u64) -> [u8; 16] {
    let base = u128::from_be_bytes(*iv);
    (base.wrapping_add(index as u128)).to_be_bytes()
}

/// 全量下发（无 Range）：前缀 + moov + 后缀窗口流式。
async fn stream_virtual(
    plan: &decrypt::MoviePlan,
    view: &SessionView,
    key: &[u8; 16],
    total_virtual: u64,
    stream: &mut tokio::net::TcpStream,
) -> Result<(), String> {
    if plan.moov_start > 0 {
        let bytes = source_range(view, 0, plan.moov_start - 1).await?;
        stream.write_all(&bytes).await.map_err(|e| e.to_string())?;
    }
    stream
        .write_all(&plan.new_moov)
        .await
        .map_err(|e| e.to_string())?;
    let mut cursor = plan.moov_start + plan.new_moov.len() as u64;
    while cursor < total_virtual {
        let chunk_end = (cursor + STREAM_WINDOW - 1).min(total_virtual - 1);
        let bytes = render_suffix(plan, view, key, cursor, chunk_end).await?;
        stream.write_all(&bytes).await.map_err(|e| e.to_string())?;
        cursor = chunk_end + 1;
    }
    Ok(())
}

/// 后缀虚拟区间渲染（供全量下发复用）。
async fn render_suffix(
    plan: &decrypt::MoviePlan,
    view: &SessionView,
    key: &[u8; 16],
    start: u64,
    end: u64,
) -> Result<Vec<u8>, String> {
    let orig_s = (start as i64 - plan.delta) as u64;
    let orig_e = (end as i64 - plan.delta) as u64;
    let mut bytes = source_range(view, orig_s, orig_e).await?;
    for sample in &plan.samples {
        if sample.end <= orig_s || sample.start > orig_e {
            continue;
        }
        let o0 = sample.start.max(orig_s) - orig_s;
        let o1 = sample.end.min(orig_e + 1) - orig_s;
        let slot = &mut bytes[o0 as usize..o1 as usize];
        decrypt_range(
            key,
            &sample.iv,
            (sample.start.max(orig_s) - sample.start) as usize,
            slot,
        );
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_parser() {
        assert_eq!(parse_range("bytes=0-99", 1000), Some((0, 99)));
        assert_eq!(parse_range("bytes=900-", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=-100", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=1000-", 1000), None);
        assert_eq!(parse_range("bytes=-0", 1000), None);
    }

}
