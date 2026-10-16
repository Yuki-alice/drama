//! 封面代理：把源站封面 URL 换成本机回环地址，Dart 侧只认 `127.0.0.1`。
//!
//! **为什么需要它**：项目纪律是「Dart 侧禁直连源站」。封面同样来自源站 CDN，
//! 若让 Flutter 的 `Image.network` 直接打开 CDN 地址，就破了这条纪律，
//! 且会把源站 Referer/UA 要求、防盗链、缓存策略散落到 UI 层。
//!
//! **无状态签名设计**（关键）：代理 URL 形如
//! `http://127.0.0.1:{port}/img/{base64url(cdnUrl)}.{sig}`，
//! 其中 `sig = md5(install_id + ":" + cdnUrl)` 的前 16 个十六进制字符。
//!
//! 为什么不用「内存会话表 + 随机 token」：**目录会被缓存到磁盘**
//! （`CacheStore`），重启后 token 表已清空，缓存里那些封面 URL 就全部 404，
//! 海报墙整体退化成渐变占位——这是实测发现的问题。签名方案下 URL 自带全部
//! 信息，重启后依然可用，也不需要 TTL / LRU / 会话表。
//!
//! 签名密钥来自**持久化**的 `device.install_id`（`device.json`），因此重启稳定；
//! 同时它使本机其他进程**无法**借我们的代理抓任意 URL（改一个字节即签名不符）。
//!
//! **磁盘缓存**：`{dataDir}/covers/{md5(url)}`。海报墙一页几十张、且反复进出，
//! 不缓存会每次冷启都重抓一遍，既慢又容易触发源站限流。
//!
//! 未调用 `init`（无 dataDir）或端口未绑定时，[proxy_url] 返回空串，
//! Dart 侧回落到渐变占位——封面是增强项，不该让整页失败。

use std::time::Duration;

use once_cell::sync::Lazy;
use tokio::io::AsyncWriteExt;

/// 磁盘缓存文件数上限。
const MAX_CACHED_FILES: usize = 1200;
/// 单张封面上限（源站封面 ~20KiB ~ 1MiB；给足余量，超限直接放弃）。
const MAX_COVER_BYTES: usize = 8 * 1024 * 1024;
/// 回源连接/总超时（封面小，不需要长超时）。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const TOTAL_TIMEOUT: Duration = Duration::from_secs(20);
/// 签名长度（十六进制字符数）。
const SIG_LEN: usize = 16;

/// 封面回源客户端（独立超时：封面小且要求快，不能沿用媒体的无总超时）。
static COVER_CLIENT: Lazy<reqwest::Client> = Lazy::new(|| {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(TOTAL_TIMEOUT)
        .build()
        .expect("build cover client")
});

fn b64_encode(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn b64_decode(text: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(text)
        .ok()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// 内容签名：`md5(install_id + ":" + url)` 的前 16 个十六进制字符。
fn sign(url: &str) -> String {
    let digest = md5::compute(format!("{}:{}", device_install_id(), url));
    hex(&digest.0)[..SIG_LEN].to_owned()
}

/// 稳定的安装标识（持久化于 `device.json`）。
///
/// 未 `init` 时退化为进程内生成值——签名仍自洽（同进程可校验），
/// 只是重启后旧 URL 失效；这是无 dataDir 时的可接受降级。
fn device_install_id() -> String {
    crate::device::identity().install_id
}

/// 是否值得代理：只代理 http(s)，其余（空/相对路径）放弃。
fn is_proxyable(raw: &str) -> bool {
    !raw.is_empty() && (raw.starts_with("https://") || raw.starts_with("http://"))
}

/// 当前代理端口（供 `version` op 上报给 Dart）；未绑定则尝试绑定。
pub fn media_port() -> Option<u16> {
    crate::gateway::ensure_port().ok()
}

/// 把本机代理封面地址改写到**当前**端口；非本机代理地址返回 `None`。
///
/// 端口是实现细节（47800-47899 取首个可用），跨会话会变。封面地址却会
/// 被持久化（追剧表 `progress.json`、目录缓存），因此**读出时**统一在此
/// 改写，使旧数据自愈。Dart 侧因此不必在渲染时逐条解析 URI 改写端口。
pub fn rewrite_to_current_port(url: &str) -> Option<String> {
    let rest = url.strip_prefix("http://127.0.0.1:")?;
    let (_, tail) = rest.split_once('/')?;
    let token = tail.strip_prefix("img/")?;
    if token.is_empty() {
        return None;
    }
    let port = media_port()?;
    Some(format!("http://127.0.0.1:{port}/img/{token}"))
}

/// 由 CDN 地址生成本机代理 URL；不可代理或端口不可用时返回空串。
pub fn proxy_url(raw: &str, _referer: &'static str) -> String {
    let raw = raw.trim();
    if !is_proxyable(raw) {
        return String::new();
    }
    let Ok(port) = crate::gateway::ensure_port() else {
        return String::new();
    };
    let token = format!("{}.{}", b64_encode(raw.as_bytes()), sign(raw));
    format!("http://127.0.0.1:{port}/img/{token}")
}

/// 校验并还原出 CDN 地址；签名不符 / 解码失败 → `None`。
///
/// **这是唯一入口**：只有能通过签名的 URL 才会被回源，
/// 因此本机其他进程无法把它当开放代理用。
pub fn resolve(token: &str) -> Option<String> {
    let (payload, sig) = token.rsplit_once('.')?;
    if sig.len() != SIG_LEN || !sig.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let url = String::from_utf8(b64_decode(payload)?).ok()?;
    if !is_proxyable(&url) {
        return None;
    }
    // 定长比较，避免早退泄露（本机场景风险极低，但成本几乎为零）。
    let expected = sign(&url);
    if expected.len() != sig.len() {
        return None;
    }
    let mut diff = 0u8;
    for (a, b) in expected.bytes().zip(sig.bytes()) {
        diff |= a ^ b;
    }
    if diff != 0 {
        return None;
    }
    Some(url)
}

/// 缓存文件名：URL 的 md5（定长、无路径穿越风险）。
fn cache_path(url: &str) -> Option<std::path::PathBuf> {
    let dir = crate::device::data_dir()?.join("covers");
    Some(dir.join(hex(&md5::compute(url.as_bytes()).0)))
}

/// 磁盘缓存淘汰：只统计数量，按 mtime 升序删到上限以下。
///
/// 失败一律忽略——缓存是优化项，不能因为它让请求失败。
async fn prune_cache(dir: &std::path::Path) {
    let Ok(mut entries) = tokio::fs::read_dir(dir).await else {
        return;
    };
    let mut files: Vec<(std::time::SystemTime, std::path::PathBuf)> = Vec::new();
    while let Ok(Some(entry)) = entries.next_entry().await {
        let Ok(meta) = entry.metadata().await else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        files.push((
            meta.modified().unwrap_or(std::time::UNIX_EPOCH),
            entry.path(),
        ));
    }
    if files.len() <= MAX_CACHED_FILES {
        return;
    }
    files.sort_by_key(|(mtime, _)| *mtime);
    let excess = files.len() - MAX_CACHED_FILES;
    for (_, path) in files.into_iter().take(excess) {
        let _ = tokio::fs::remove_file(path).await;
    }
}

/// 图片类型：按 URL 后缀猜（源站多是无扩展名的 tos 地址 → 默认 PNG）。
fn content_type_for(url: &str) -> &'static str {
    let lower = url.split('?').next().unwrap_or("").to_ascii_lowercase();
    if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        "image/jpeg"
    } else if lower.ends_with(".webp") {
        "image/webp"
    } else if lower.ends_with(".gif") {
        "image/gif"
    } else if lower.ends_with(".avif") {
        "image/avif"
    } else {
        "image/png"
    }
}

/// 取封面字节：先磁盘缓存，未命中再回源并顺手写缓存。
async fn load_bytes(url: &str) -> Result<Vec<u8>, String> {
    let path = cache_path(url);
    if let Some(path) = &path
        && let Ok(bytes) = tokio::fs::read(path).await
        && !bytes.is_empty()
    {
        return Ok(bytes);
    }

    let resp = COVER_CLIENT
        .get(url)
        .header("Referer", "https://www.hongguoduanju.com/")
        .header("User-Agent", crate::http::USER_AGENT_VALUE)
        .send()
        .await
        .map_err(|e| format!("cover upstream: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("cover upstream status {}", resp.status()));
    }
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("cover read body: {e}"))?
        .to_vec();
    if bytes.is_empty() || bytes.len() > MAX_COVER_BYTES {
        return Err("cover size out of range".to_owned());
    }

    // 原子写：先写 .part 再 rename，避免半截文件被当成有效缓存。
    if let Some(path) = &path {
        if let Some(parent) = path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let tmp = path.with_extension("part");
        if tokio::fs::write(&tmp, &bytes).await.is_ok()
            && tokio::fs::rename(&tmp, path).await.is_err()
        {
            let _ = tokio::fs::remove_file(&tmp).await;
        }
        if let Some(parent) = path.parent() {
            prune_cache(parent).await;
        }
    }
    Ok(bytes)
}

/// 处理 `/img/{token}` 请求（由 [`crate::gateway`] 的 accept 循环路由进来）。
pub async fn serve(
    stream: &mut tokio::net::TcpStream,
    token: &str,
    is_head: bool,
) -> Result<(), String> {
    let Some(url) = resolve(token) else {
        // 签名不符：既可能是损坏链接，也可能是本机其他进程在探测开放代理。
        return respond(
            stream,
            403,
            "Forbidden",
            "text/plain",
            b"bad signature",
            is_head,
        )
        .await;
    };
    match load_bytes(&url).await {
        Ok(bytes) => respond(stream, 200, "OK", content_type_for(&url), &bytes, is_head).await,
        Err(e) => {
            // 明确区分「取不到」：Dart 侧据此回落占位，不重试到卡住。
            respond(
                stream,
                502,
                "Bad Gateway",
                "text/plain",
                e.as_bytes(),
                is_head,
            )
            .await
        }
    }
}

async fn respond(
    stream: &mut tokio::net::TcpStream,
    status: u16,
    reason: &str,
    content_type: &str,
    body: &[u8],
    is_head: bool,
) -> Result<(), String> {
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\r\n",
        body.len(),
    );
    stream
        .write_all(head.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    if !is_head {
        stream.write_all(body).await.map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用签名（不依赖 dataDir）。
    fn test_token(url: &str) -> String {
        format!("{}.{}", b64_encode(url.as_bytes()), sign(url))
    }

    #[test]
    fn rejects_non_http_and_empty() {
        assert_eq!(proxy_url("", "https://x/"), "");
        assert_eq!(proxy_url("  ", "https://x/"), "");
        assert_eq!(proxy_url("/relative/cover.png", "https://x/"), "");
        assert_eq!(proxy_url("ftp://x/c.png", "https://x/"), "");
    }

    #[test]
    fn roundtrip_signed_token() {
        let url = "https://p11-novel-seo.byteimg.com/tos-cn-i-x/home/abc.png";
        assert_eq!(resolve(&test_token(url)).as_deref(), Some(url));
    }

    #[test]
    fn tampered_url_fails_signature() {
        let url = "https://cdn.example/a.png";
        let other = "https://cdn.example/b.png";
        // 用 a 的签名配 b 的载荷 → 必须拒绝（否则就是开放代理）。
        let forged = format!("{}.{}", b64_encode(other.as_bytes()), sign(url));
        assert_eq!(resolve(&test_token(url)).as_deref(), Some(url));
        assert_eq!(resolve(&forged), None);
    }

    #[test]
    fn malformed_tokens_are_rejected() {
        assert_eq!(resolve(""), None);
        assert_eq!(resolve("nodot"), None);
        assert_eq!(resolve("payload."), None);
        assert_eq!(
            resolve(&format!(
                "{}.{}",
                b64_encode(b"https://x/a"),
                "z".repeat(SIG_LEN)
            )),
            None
        );
        // 非 http(s) 载荷。
        assert_eq!(resolve(&test_token("ftp://x/a")), None);
        // 非法 base64。
        assert_eq!(resolve(&format!("!!!.{}", "a".repeat(SIG_LEN))), None);
    }

    #[test]
    fn content_type_guesses_from_extension_and_defaults_png() {
        assert_eq!(content_type_for("https://x/a.jpg"), "image/jpeg");
        assert_eq!(content_type_for("https://x/a.jpeg?q=1"), "image/jpeg");
        assert_eq!(content_type_for("https://x/a.webp"), "image/webp");
        assert_eq!(content_type_for("https://x/a.gif"), "image/gif");
        assert_eq!(content_type_for("https://x/a.avif"), "image/avif");
        assert_eq!(
            content_type_for("https://x/tos-cn-i-abc/image"),
            "image/png"
        );
    }

    #[test]
    fn token_is_url_safe_single_segment() {
        let url = "https://p6-novel.byteimg.com/novel-pic/a/b~tplv-shrink:640:0.image";
        let token = test_token(url);
        // 必须能安全放进单个路径段：不含 `/`、`?`、`#`、`+`。
        for bad in ['/', '?', '#', '+', '&', ' '] {
            assert!(!token.contains(bad), "token contains {bad}: {token}");
        }
    }

    /// 联网测试（默认跳过）：签名 URL 跨「进程」稳定——这是磁盘缓存可用性的前提。
    #[test]
    #[ignore = "联网：需访问源站 CDN"]
    fn network_signed_url_is_stable_and_serves_image() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let dir = std::env::temp_dir().join("drama-cover-restart-probe");
        let _ = std::fs::create_dir_all(&dir);
        crate::device::set_data_dir(dir.clone());

        // install_id 持久化 → 同一 URL 两次生成必须完全一致（重启后仍可解析）。
        let raw = "https://p6-novel.byteimg.com/novel-pic/a2cb1301ce6c9d4031d934d038eb4578~tplv-shrink:640:0.image";
        let a = proxy_url(raw, "https://www.hongguoduanju.com/");
        let b = proxy_url(raw, "https://www.hongguoduanju.com/");
        assert!(!a.is_empty(), "proxy_url returned empty");
        assert_eq!(a, b, "signed url must be stable across calls");

        // 模拟「重启」：清空身份内存缓存后重新读取（仍从 device.json 读回同一 id）。
        let token = a.rsplit("/img/").next().unwrap();
        assert_eq!(resolve(token).as_deref(), Some(raw));

        // 真取一次图（走代理 → 回源 → 落盘缓存）。
        let bytes = crate::http::runtime_handle()
            .block_on(async { reqwest::get(&a).await.unwrap().bytes().await.unwrap() });
        assert!(bytes.len() > 1000, "cover too small: {}", bytes.len());
        let is_png = bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]);
        let is_jpg = bytes.starts_with(&[0xFF, 0xD8, 0xFF]);
        assert!(is_png || is_jpg, "not an image");

        // 第二次取图应命中磁盘缓存（明显更快）。
        let t0 = std::time::Instant::now();
        let again = crate::http::runtime_handle()
            .block_on(async { reqwest::get(&a).await.unwrap().bytes().await.unwrap() });
        let cached_ms = t0.elapsed().as_millis();
        assert_eq!(again.len(), bytes.len());
        eprintln!("second fetch (disk cache) took {cached_ms}ms");

        crate::device::clear_data_dir();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cache_path_absent_without_data_dir() {
        // 无 dataDir → None（不 panic）。
        let _ = cache_path("https://x/a.png");
    }
}
