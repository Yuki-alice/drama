//! 网关字节转发集成测试（进程内）。
//!
//! ## 为什么必须进程内
//!
//! 网关是**进程级单例**：`drama-cli play` 打印完 plan 就退出，
//! 网关随之关闭，外部 curl 只能拿到 connection refused。
//! 真实播放器会一直持有进程，所以这个场景只能在同一进程里验证。
//!
//! 本测试起一个本地 HTTP 服务器当「源站」，注册会话后
//! 通过回环地址取字节，验证：
//!
//! - 200 全量、206 Range、HEAD 三种请求；
//! - `Content-Range` / `Accept-Ranges` 透传（播放器 seek 依赖它）；
//! - 未知 token 返回 404（而不是 500 或挂住）。

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// 起一个只服务固定字节的 HTTP 服务器。
fn spawn_origin(body: Vec<u8>) -> (String, Arc<AtomicBool>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let done = Arc::new(AtomicBool::new(false));
    let done_clone = done.clone();
    let body = Arc::new(body);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            if done_clone.load(Ordering::Relaxed) {
                break;
            }
            let Ok(mut stream) = stream else { break };
            let mut buffer = [0u8; 4096];
            let Ok(n) = stream.read(&mut buffer) else { break };
            let request = String::from_utf8_lossy(&buffer[..n]).to_string();
            let body = body.clone();

            // 解析 Range 头。
            let range = request
                .lines()
                .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                .and_then(|l| l.split_once('='))
                .and_then(|(_, spec)| {
                    let (start, end) = spec.split_once('-')?;
                    Some((start.trim().parse::<usize>().ok()?, end.trim().parse::<usize>().ok()))
                });

            let (status, payload, extra) = match range {
                Some((start, Some(end))) if start < body.len() => {
                    let end = end.min(body.len() - 1);
                    (
                        206,
                        body[start..=end].to_vec(),
                        format!(
                            "Content-Range: bytes {start}-{end}/{}\r\nAccept-Ranges: bytes\r\n",
                            body.len()
                        ),
                    )
                }
                _ => (200, body.to_vec(), "Accept-Ranges: bytes\r\n".to_owned()),
            };
            let header = format!(
                "HTTP/1.1 {status} OK\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n",
                payload.len()
            );
            let _ = stream.write_all(header.as_bytes());
            let _ = stream.write_all(&payload);
        }
    });
    (format!("http://{addr}/video.mp4"), done)
}

/// 用裸 TCP 发一个请求，返回 (状态行, 头文本, body)。
fn raw_request(url: &str, method: &str, extra_headers: &str) -> (String, String, Vec<u8>) {
    let rest = url.strip_prefix("http://").expect("http url");
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let mut stream = std::net::TcpStream::connect(authority).expect("connect");
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .expect("timeout");
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: {authority}\r\n{extra_headers}Connection: close\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).expect("write");

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).expect("read");
    split_response(&raw)
}

fn split_response(raw: &[u8]) -> (String, String, Vec<u8>) {
    let text = String::from_utf8_lossy(raw).into_owned();
    let Some(split) = text.find("\r\n\r\n") else {
        return (String::new(), String::new(), Vec::new());
    };
    let head = text[..split].to_owned();
    let status = head.lines().next().unwrap_or("").to_owned();
    let header_len = split + 4;
    let body = raw.get(header_len..).unwrap_or(&[]).to_vec();
    (status, head, body)
}

fn sample_body() -> Vec<u8> {
    // 可变内容，验证 Range 切的是正确区间。
    (0..8192).map(|i| (i % 251) as u8).collect()
}

#[test]
fn full_get_relays_bytes() {
    let (origin, done) = spawn_origin(sample_body());
    let proxy = drama_gateway::register_hex(&origin, String::new(), None).expect("register");

    let (status, head, body) = raw_request(&proxy, "GET", "");
    assert!(status.contains("200"), "status: {status}");
    assert_eq!(body, sample_body(), "body must be relayed verbatim");
    assert!(head.to_ascii_lowercase().contains("content-type: video/mp4"));
    done.store(true, Ordering::Relaxed);
}

#[test]
fn range_request_returns_206_and_content_range() {
    let (origin, done) = spawn_origin(sample_body());
    let proxy = drama_gateway::register_hex(&origin, String::new(), None).expect("register");

    let (status, head, body) = raw_request(&proxy, "GET", "Range: bytes=100-199\r\n");
    assert!(status.contains("206"), "status: {status}");
    // 播放器 seek 依赖 Content-Range 与 Accept-Ranges 透传。
    let lower = head.to_ascii_lowercase();
    assert!(lower.contains("content-range: bytes 100-199/8192"), "head: {head}");
    assert!(lower.contains("accept-ranges: bytes"));
    assert_eq!(body, sample_body()[100..=199]);
    done.store(true, Ordering::Relaxed);
}

#[test]
fn head_request_has_headers_without_body() {
    let (origin, done) = spawn_origin(sample_body());
    let proxy = drama_gateway::register_hex(&origin, String::new(), None).expect("register");

    let (status, head, body) = raw_request(&proxy, "HEAD", "");
    assert!(status.contains("200"), "status: {status}");
    assert!(body.is_empty(), "HEAD must not carry a body");
    assert!(head.to_ascii_lowercase().contains("content-type: video/mp4"));
    done.store(true, Ordering::Relaxed);
}

#[test]
fn unknown_token_is_404_not_hung() {
    let (origin, done) = spawn_origin(sample_body());
    // 注册后立刻丢弃，模拟会话过期。
    let proxy = drama_gateway::register_hex(&origin, String::new(), None).expect("register");
    // `http://host/play/{token}/video.mp4` → 换成不存在的 token。
    let base = proxy.rsplit_once("/play/").expect("play path").0;
    let forged = format!("{base}/play/00000000000000000000000000000000/video.mp4");

    let (status, _, _) = raw_request(&forged, "GET", "");
    // 404（而不是 500 / 挂住）：token 未注册就是「没有这个资源」。
    // 客户端据此提示「播放已结束，请重新解析」。
    assert!(status.contains("404"), "forged token status: {status}");
    done.store(true, Ordering::Relaxed);
}

#[test]
fn bad_method_is_405() {
    let (origin, done) = spawn_origin(sample_body());
    let proxy = drama_gateway::register_hex(&origin, String::new(), None).expect("register");

    let (status, _, _) = raw_request(&proxy, "POST", "");
    assert!(status.contains("405"), "status: {status}");
    done.store(true, Ordering::Relaxed);
}

#[test]
fn key_registration_rejects_bad_hex() {
    let (origin, done) = spawn_origin(sample_body());
    // 密钥必须是 32 hex（16 字节）。
    assert!(drama_gateway::register_hex(&origin, String::new(), Some("zz".to_owned())).is_err());
    assert!(
        drama_gateway::register_hex(&origin, String::new(), Some("0011".to_owned())).is_err()
    );
    // 合法密钥可注册。
    assert!(
        drama_gateway::register_hex(&origin, String::new(), Some("00112233445566778899aabbccddeeff".to_owned()))
            .is_ok()
    );
    done.store(true, Ordering::Relaxed);
}
