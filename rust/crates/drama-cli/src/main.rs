//! 命令行验收工具。
//!
//! **与 FFI 走同一条 dispatch 路径**（`drama_core::request_text` →
//! `drama_engine::global().dispatch`）——如果 CLI 能用，FFI 就能用。
//! 这条约束防止「CLI 走捷径，FFI 才暴露 bug」。
//!
//! ## 用法
//!
//! ```text
//! drama-cli ping
//! drama-cli catalog --category short_play --page 0
//! drama-cli search --keyword 都市
//! drama-cli detail --id <series_id>
//! drama-cli detail-groups --id <series_id> --group-size 50
//! drama-cli sources
//! drama-cli validate --file ./my-source.yaml
//! drama-cli install --file ./my-source.yaml
//! drama-cli uninstall --id wuguo
//! drama-cli enable --id wuguo --on
//! drama-cli ops
//! drama-cli stats
//! ```
//!
//! 首次使用先 `--data-dir <path>` 初始化（不传则用临时目录）。

use std::path::PathBuf;
use std::process::ExitCode;

use serde_json::{Value, json};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("错误: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<ExitCode, String> {
    // 解析全局选项。
    let mut data_dir: Option<PathBuf> = None;
    let mut source: Option<String> = None;
    let mut positional: Vec<&String> = Vec::new();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--data-dir" => {
                index += 1;
                let value = args.get(index).ok_or("--data-dir 需要一个路径")?;
                data_dir = Some(PathBuf::from(value));
            }
            "--source" => {
                index += 1;
                let value = args.get(index).ok_or("--source 需要一个源 id")?;
                source = Some(value.clone());
            }
            _other => positional.push(&args[index]),
        }
        index += 1;
    }

    let Some(command) = positional.first() else {
        print_help();
        return Ok(ExitCode::SUCCESS);
    };

    // 初始化数据目录（默认临时目录）。
    let dir = data_dir.unwrap_or_else(|| {
        std::env::temp_dir().join(format!("drama-cli-{}", std::process::id()))
    });
    init_data_dir(&dir)?;
    // 日志由 `RUST_LOG` 控制（默认 tracing 的 warn 级别），
    // 不在程序内 set_var——Rust 2024 里它是 unsafe，工作区禁用 unsafe。

    let envelope = build_envelope(command, &positional[1..], source.as_deref())?;
    let response_text = drama_core::request_text(&envelope);
    let value: Value = serde_json::from_str(&response_text)
        .map_err(|e| format!("响应不是合法 JSON: {e}"))?;

    // 非零退出码：ok=false。
    let pretty = serde_json::to_string_pretty(&value).unwrap_or_else(|_| response_text.clone());
    println!("{pretty}");
    Ok(if value["ok"] == json!(true) {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

/// 初始化数据目录（走 `init` op，与 FFI 相同路径）。
fn init_data_dir(dir: &std::path::Path) -> Result<(), String> {
    let envelope = json!({
        "v": 1,
        "op": "init",
        "params": {"dataDir": dir.to_string_lossy()}
    });
    let text = drama_core::request_text(&envelope.to_string());
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    if value["ok"] != json!(true) {
        return Err(format!("初始化数据目录失败: {value}"));
    }
    Ok(())
}

/// 构造请求信封。
fn build_envelope(
    command: &str,
    args: &[&String],
    source: Option<&str>,
) -> Result<String, String> {
    // 友好别名 → 真实 op 名。
    let command = match command {
        "stats" => "cacheStats",
        "install" => "sourceInstall",
        "validate" => "sourceValidate",
        "uninstall" => "sourceUninstall",
        "enable" => "sourceEnable",
        other => other,
    };
    let mut envelope = json!({"v": 1, "op": command, "params": {}});
    if let Some(source) = source {
        envelope["source"] = json!(source);
    }
    let params = &mut envelope["params"];
    let need = |name: &str| -> Result<String, String> {
        let mut iter = args.iter();
        while let Some(arg) = iter.next() {
            if arg.as_str() == format!("--{name}") {
                let value = iter.next().ok_or(format!("--{name} 需要一个值"))?;
                return Ok(value.to_string());
            }
        }
        Err(format!("{command} 需要 --{name}"))
    };
    let opt = |name: &str| -> Option<String> {
        let mut iter = args.iter();
        while let Some(arg) = iter.next() {
            if arg.as_str() == format!("--{name}") {
                return iter.next().map(|v| v.to_string());
            }
        }
        None
    };

    match command {
        // 引擎级 op（无参数）。
        "ping" | "ops" | "sources" | "cacheStats" | "diagnostics" | "version" => {}
        "catalog" => {
            if let Some(category) = opt("category") {
                params["category"] = json!(category);
            }
            if let Some(page) = opt("page") {
                params["page"] = json!(page.parse::<u64>().map_err(|e| e.to_string())?);
            }
        }
        "search" | "suggest" => {
            let keyword = need("keyword")?;
            params["keyword"] = json!(keyword);
        }
        "detail" | "episodeGroups" | "followDel" | "historyGet" | "sourceUninstall" => {
            let id = need("id")?;
            params["id"] = json!(id);
            if command == "episodeGroups"
                && let Some(size) = opt("group-size")
            {
                params["groupSize"] = json!(size.parse::<u64>().map_err(|e| e.to_string())?);
            }
        }
        "play" | "preload" => {
            let id = need("id")?;
            params["id"] = json!(id);
            if let Some(episode) = opt("episode") {
                params["episode"] = json!(episode.parse::<u64>().map_err(|e| e.to_string())?);
            }
            if let Some(quality) = opt("quality") {
                params["quality"] = json!(quality.parse::<i64>().map_err(|e| e.to_string())?);
            }
            // `--vid`：分集视频 id（规则源的取流 URL 常需要它）。
            if let Some(vid) = opt("vid") {
                params["vid"] = json!(vid);
            }
        }
        "ranking" => {
            if let Some(board) = opt("board") {
                params["board"] = json!(board);
            }
        }
        "followPut" | "historyPut" => {
            let id = need("id")?;
            params["id"] = json!(id);
            if let Some(title) = opt("title") {
                params["title"] = json!(title);
            }
            if let Some(episode) = opt("episode") {
                params["episode"] = json!(episode.parse::<u64>().map_err(|e| e.to_string())?);
            }
        }
        "sourceValidate" | "sourceInstall" => {
            let path = need("file")?;
            let text = std::fs::read_to_string(&path)
                .map_err(|e| format!("读取 {path} 失败: {e}"))?;
            params["manifest"] = json!(text);
        }
        "sourceEnable" => {
            let id = need("id")?;
            params["id"] = json!(id);
            params["enabled"] = json!(opt("on").is_some());
        }
        _ => return Err(format!("未知命令: {command}（--help 查看用法）")),
    }
    Ok(envelope.to_string())
}

fn print_help() {
    println!(
        r#"红果短剧客户端 —— 后端验收 CLI

用法: drama-cli [--data-dir <path>] [--source <id>] <命令> [参数]

命令:
  ping                          连通性检查
  version                       核心版本与源列表
  ops                           wire 契约表
  catalog [--category C] [--page N]
                                分类目录
  search --keyword K            搜索
  suggest --keyword K           搜索联想
  detail --id ID                详情
  episodeGroups --id ID [--group-size N]
                                选集分组
  play --id ID [--episode N] [--quality Q]
                                取流
  ranking [--board B]           榜单
  followPut --id ID [--title T] [--episode N]
                                追剧
  followList / followDel --id ID
  historyPut --id ID ...        观看进度
  historyGet --id ID / historyClear
  sources                       已安装源
  validate --file FILE          校验规则包
  install --file FILE           安装规则包
  uninstall --id ID             卸载
  enable --id ID [--on]         启停
  stats / diagnostics           缓存与诊断

全局选项:
  --data-dir <path>             数据目录（默认临时目录）
  --source <id>                 指定源（默认 hongguo）
"#
    );
}
