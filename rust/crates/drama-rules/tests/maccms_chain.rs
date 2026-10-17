//! MacCMS 风格站源的端到端验证。
//!
//! 用**真实抓取到的页面结构**做夹具（网果 / 花果），走完整管线：
//! 本地 HTTP 服务器 → 规则引擎 → 目录 / 详情 / 取流。
//!
//! 为什么这个测试重要：HTML 源是参考项目里最多的一类（8/22），
//! 如果规则引擎连它们都跑不动，「规则源」这个架构改造就只是空话。

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use drama_rules::{Manifest, RuleEngine};
use drama_types::SourceProvider;

/// 起一个按路径返回固定内容的服务器。
fn serve(routes: HashMap<String, String>) -> (String, Arc<AtomicBool>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let done = Arc::new(AtomicBool::new(false));
    let stop = done.clone();
    let routes = Arc::new(routes);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let Ok(mut stream) = stream else { break };
            let mut buffer = [0u8; 8192];
            let Ok(n) = stream.read(&mut buffer) else { break };
            let request = String::from_utf8_lossy(&buffer[..n]).to_string();
            let path = request
                .lines()
                .next()
                .and_then(|line| line.split_whitespace().nth(1))
                .unwrap_or("/")
                .to_owned();
            let key = path.split('?').next().unwrap_or("/").to_owned();
            let body = routes
                .get(&key)
                .cloned()
                .unwrap_or_else(|| "<html><body>404</body></html>".to_owned());
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
        }
    });
    (format!("http://{addr}"), done)
}

/// 网果风格列表页：`article.post` 卡片 + `a@href` + `a@title`。
const WANGGUO_LIST: &str = r#"<html><body>
<div class="row posts-wrapper">
  <div class="col-lg-2">
    <article class="post post-grid">
      <div class="entry-media">
        <a href="/vod/49477.html" title="谁才是他亲爹">
          <img class="lazyload" data-src="https://pic.example/a.jpg" src="data:image/gif;base64,R0">
        </a>
      </div>
    </article>
  </div>
  <div class="col-lg-2">
    <article class="post post-grid">
      <div class="entry-media">
        <a href="/vod/49476.html" title="第二个剧">
          <img class="lazyload" data-src="https://pic.example/b.jpg" src="data:image/gif;base64,R0">
        </a>
      </div>
    </article>
  </div>
</div>
</body></html>"#;

/// 详情页：`h1` 标题 + `.playlist a` 分集。
const WANGGUO_DETAIL: &str = r#"<html><body>
<div class="video-info"><h1>谁才是他亲爹</h1><div class="desc">剧情简介在这里</div></div>
<ul class="playlist">
  <li><a href="/play/49477-1-1.html">第1集</a></li>
  <li><a href="/play/49477-1-2.html">第2集</a></li>
</ul>
</body></html>"#;

/// 播放页：`player_aaaa` 内嵌 JSON，URL 被 JS 转义。
const WANGGUO_PLAY: &str = r#"<html><body>
<script type="text/javascript">
var player_aaaa={"flag":"play","encrypt":0,"url":"https:\/\/v8.example.com\/wjv8\/202610\/16\/VHQK\/video\/index.m3u8","from":"wjm3u8","id":"49477","sid":1,"nid":1};
</script>
</body></html>"#;

/// 构造清单：`{base}` 由 format 填入，模板变量用 `{{…}}`（format 会转义成 `{…}`，
/// 故这里直接写单花括号，解析前再还原）。
fn wangguo_manifest(base: &str) -> Manifest {
    let yaml = format!(
        r#"
schema: 1
id: wangguo
name: 网果
version: 1.0.0
author: test
base: {base}
user_agent: desktop
ops:
  catalog:
    request:
      url: "{{base}}/vod-list/{{page}}"
    items: "css:article.post"
    map:
      id:
        from: "a@href"
        filters:
          - 're:([0-9]+)\.html:1' 
      title:
        from: "a@title"
      cover:
        from: "img@data-src"
    pagination:
      type: page
      size: 2
  detail:
    request:
      url: "{{base}}/vod/{{id}}.html"
    identity_check: false
    map:
      id:
        from: "{{id}}"
      title:
        from: "css:h1"
      summary:
        from: "css:.desc"
    chapters:
      items: "css:.playlist a"
      title_template: "第{{index}}集"
      url: "a@href"
      index:
        from: "a@href"
        filters:
          - 're:([0-9]+)\.html:1' 
"#
    );
    // format 把 `{{base}}` 变成 `{base}`；还原成模板变量。
    let yaml = yaml
        .replace("{base}", "{{base}}")
        .replace("{page}", "{{page}}")
        .replace("{id}", "{{id}}")
        .replace("{index}", "{{index}}")
        .replace("{episode}", "{{episode}}");
    Manifest::from_yaml(&yaml).expect("manifest")
}

#[test]
fn maccms_catalog_uses_element_level_extraction() {
    let routes = HashMap::from([("/vod-list/1".to_owned(), WANGGUO_LIST.to_owned())]);
    let (base, done) = serve(routes);
    let engine = RuleEngine::new(wangguo_manifest(&base)).expect("engine");

    let page = engine.catalog("", 0).expect("catalog");
    assert_eq!(page.items.len(), 2, "应解析出 2 个卡片");
    // 元素级取值：每张卡片标题不同（重构前做不到，全是空）。
    assert_eq!(page.items[0].title, "谁才是他亲爹");
    assert_eq!(page.items[1].title, "第二个剧");
    // id 从 href 正则提取。
    assert_eq!(page.items[0].id.source_id, "49477");
    assert_eq!(page.items[1].id.source_id, "49476");
    // 封面取 data-src 并补全。
    assert_eq!(page.items[0].cover, "https://pic.example/a.jpg");
    done.store(true, Ordering::Relaxed);
}

#[test]
fn maccms_detail_parses_html_chapters() {
    let routes = HashMap::from([("/vod/49477.html".to_owned(), WANGGUO_DETAIL.to_owned())]);
    let (base, done) = serve(routes);
    let engine = RuleEngine::new(wangguo_manifest(&base)).expect("engine");

    let detail = engine.detail("49477").expect("detail");
    assert_eq!(detail.drama.title, "谁才是他亲爹");
    assert_eq!(detail.drama.summary, "剧情简介在这里");
    assert_eq!(detail.episodes.len(), 2);
    assert_eq!(detail.episodes[0].title, "第1集");
    assert_eq!(detail.episodes[0].index, 1);
    assert!(detail.episodes[0].url.contains("49477-1-1.html"));
    done.store(true, Ordering::Relaxed);
}

/// 取流清单：从播放页正则抠 URL。
fn playback_manifest(base: &str, pattern: &str) -> Manifest {
    let yaml = format!(
        r#"
schema: 1
id: wangguo
name: 网果
base: {base}
ops:
  catalog:
    request:
      url: "{{base}}/list"
    items: "css:article"
  playback:
    request:
      url: "{{base}}/play/{{id}}-1-{{episode}}.html"
    extract:
      type: regex
      pattern: {pattern}
      group: 1
    referer: "{{base}}/"
"#
    );
    let yaml = yaml
        .replace("{base}", "{{base}}")
        .replace("{page}", "{{page}}")
        .replace("{id}", "{{id}}")
        .replace("{episode}", "{{episode}}");
    Manifest::from_yaml(&yaml).expect("manifest")
}

#[test]
fn maccms_playback_extracts_url_from_player_json() {
    let routes = HashMap::from([("/play/49477-1-1.html".to_owned(), WANGGUO_PLAY.to_owned())]);
    let (base, done) = serve(routes);
    let engine = RuleEngine::new(playback_manifest(&base, r#"'"url":"([^"]+)"'"#))
        .expect("engine");

    let media = engine
        .play(drama_types::PlayRequest {
            series_id: "49477".to_owned(),
            episode: 1,
            vid: None,
            quality: 0,
        })
        .expect("play");
    // JS 转义必须反转义成可用的 URL。
    assert_eq!(
        media.url,
        "https://v8.example.com/wjv8/202610/16/VHQK/video/index.m3u8"
    );
    done.store(true, Ordering::Relaxed);
}

#[test]
fn maccms_playback_trims_trailing_comma() {
    // 花果的真实脏数据：m3u8 后面跟一个逗号。
    let page = r#"<html><body><script>
{"url":"https://v11.example.com/wjv11/202508/15/SnEX/video/index.m3u8,"}
</script></body></html>"#;
    let routes = HashMap::from([("/play/1-1-1.html".to_owned(), page.to_owned())]);
    let (base, done) = serve(routes);
    let engine = RuleEngine::new(playback_manifest(
        &base,
        r#"(https://[^"'\s]+\.m3u8),?"#,
    ))
    .expect("engine");

    let media = engine
        .play(drama_types::PlayRequest {
            series_id: "1".to_owned(),
            episode: 1,
            vid: None,
            quality: 0,
        })
        .expect("play");
    // 尾随逗号必须被清掉，否则播放器 404。
    assert_eq!(
        media.url,
        "https://v11.example.com/wjv11/202508/15/SnEX/video/index.m3u8"
    );
    done.store(true, Ordering::Relaxed);
}

/// 剧果场景：取流响应用 `Set-Cookie` 下发 CloudFront 签名，
/// 媒体请求必须带上，否则 403。
///
/// 这个测试验证「cookie 捕获」这一步：取流后引擎里应有值。
#[test]
fn cookie_jar_captures_set_cookie() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let done = Arc::new(AtomicBool::new(false));
    let stop = done.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let Ok(mut stream) = stream else { break };
            let mut buffer = [0u8; 4096];
            let Ok(_) = stream.read(&mut buffer) else { break };
            let body = r#"{"url":"https://cdn.example/hls/index.m3u8"}"#;
            // 关键：带上 Set-Cookie。
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: CloudFront-Policy=abc123; Path=/; Secure\r\nSet-Cookie: CloudFront-Signature=sig456; Path=/; Secure\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
        }
    });
    let base = format!("http://{addr}");

    let yaml = format!(
        r#"
schema: 1
id: huangju
name: 剧果
base: {base}
cookie_jar: on
caps:
  catalog: true
  playback: true
ops:
  catalog:
    request:
      url: "{{base}}/list"
    items: "items"
  playback:
    request:
      url: "{{base}}/play/{{vid}}"
    extract:
      type: json
      path: "url"
"#
    );
    let yaml = yaml.replace("{base}", "{{base}}");
    let manifest = Manifest::from_yaml(&yaml).expect("manifest");
    let engine = RuleEngine::new(manifest).expect("engine");

    let media = engine
        .play(drama_types::PlayRequest {
            series_id: "d".to_owned(),
            episode: 1,
            vid: Some("17570".to_owned()),
            quality: 0,
        })
        .expect("play");
    assert_eq!(media.url, "https://cdn.example/hls/index.m3u8");

    // cookie 必须被捕获并拼成 `name=value; name=value`。
    let cookie = engine.media_cookie().expect("cookie captured");
    assert!(cookie.contains("CloudFront-Policy=abc123"), "got {cookie}");
    assert!(cookie.contains("CloudFront-Signature=sig456"), "got {cookie}");
    done.store(true, Ordering::Relaxed);
}
