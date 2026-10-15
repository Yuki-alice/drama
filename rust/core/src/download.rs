//! 下载管理器（离线面）。
//!
//! 单文件 MP4 下载（m3u8 明确拒绝，走在线代理播）：
//! 分片 Range 拉取 + `.part` 续传 + 完成改名 + 索引持久化。
//! 并发上限 2，其余排队；暂停/取消协作式（按块检查），
//! Dart 侧轮询 `downloadList` 取进度，不做跨线程推送。
//!
//! 离线播放复用网关注密链：完成文件 + 索引里的密钥经
//! `gateway::register_file` 注册为文件会话。

use std::collections::HashMap;
use std::sync::Mutex;

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use crate::source::traits::SourceError;

/// 最大并行下载数。
const MAX_PARALLEL: usize = 2;
/// 索引文件名。
const INDEX_FILE: &str = "downloads.json";

/// 任务状态（与 Dart 侧 `DownloadStatus` 同名映射）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DlState {
    Queued,
    Downloading,
    Paused,
    Completed,
    Failed,
}

/// 可持久化任务记录（运行时句柄另存）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DlRecord {
    pub id: String,
    pub series_id: String,
    pub title: String,
    pub cover: String,
    pub episode: u32,
    pub vid: String,
    pub quality: i64,
    pub url: String,
    pub referer: String,
    pub key_hex: String,
    pub total: u64,
    pub done: u64,
    pub state: DlState,
    pub error: String,
}

struct LiveTask {
    record: DlRecord,
    cancel: CancellationToken,
}

struct Manager {
    tasks: HashMap<String, LiveTask>,
    loaded: bool,
}

static MANAGER: Lazy<Mutex<Manager>> = Lazy::new(|| {
    Mutex::new(Manager {
        tasks: HashMap::new(),
        loaded: false,
    })
});

/// 独立下载运行时（长任务不占元数据/网关 worker）。
static DOWNLOAD_RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("dl-worker")
        .enable_all()
        .build()
        .expect("build download runtime")
});

fn dir() -> Result<std::path::PathBuf, SourceError> {
    crate::device::download_dir()
        .ok_or_else(|| SourceError::Parse("download dir not initialized (call init)".to_owned()))
}

fn index_path() -> Result<std::path::PathBuf, SourceError> {
    Ok(dir()?.join(INDEX_FILE))
}

fn task_dir(series_id: &str, vid: &str) -> Result<std::path::PathBuf, SourceError> {
    let safe_series: String = series_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    let safe_vid: String = vid.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if safe_series.is_empty() || safe_vid.is_empty() {
        return Err(SourceError::Parse("bad series/vid".to_owned()));
    }
    Ok(dir()?.join(format!("{safe_series}_{safe_vid}")))
}

/// 延迟加载索引。
fn ensure_loaded() {
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    if mgr.loaded {
        return;
    }
    mgr.loaded = true;
    let Ok(path) = index_path() else { return };
    let Ok(raw) = std::fs::read(&path) else {
        return;
    };
    let Ok(records) = serde_json::from_slice::<Vec<DlRecord>>(&raw) else {
        return;
    };
    for record in records {
        // 重启后在途任务回退为排队/暂停：下载中→排队等待 pump，其余保持。
        let mut record = record;
        if record.state == DlState::Downloading {
            record.state = DlState::Queued;
        }
        mgr.tasks.insert(
            record.id.clone(),
            LiveTask {
                record,
                cancel: CancellationToken::new(),
            },
        );
    }
}

fn persist_locked(mgr: &Manager) -> Result<(), SourceError> {
    let Ok(path) = index_path() else {
        return Ok(());
    };
    let records: Vec<&DlRecord> = mgr.tasks.values().map(|t| &t.record).collect();
    let raw = serde_json::to_vec(&records)
        .map_err(|e| SourceError::Parse(format!("encode index: {e}")))?;
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, raw).map_err(|e| SourceError::Parse(format!("write index: {e}")))?;
    Ok(())
}

/// 启动泵：空闲且有排队任务时开工（调用方持有锁，内部不再加锁）。
fn pump_locked(mgr: &mut Manager) {
    let active = mgr
        .tasks
        .values()
        .filter(|t| t.record.state == DlState::Downloading)
        .count();
    if active >= MAX_PARALLEL {
        return;
    }
    let next = mgr
        .tasks
        .iter()
        .find(|(_, t)| t.record.state == DlState::Queued)
        .map(|(id, _)| id.clone());
    if let Some(id) = next
        && let Some(task) = mgr.tasks.get_mut(&id)
    {
        task.record.state = DlState::Downloading;
        task.cancel = CancellationToken::new();
        let cancel = task.cancel.clone();
        let record = task.record.clone();
        DOWNLOAD_RT.spawn(async move {
            run_download(record, cancel).await;
        });
    }
}

fn record_to_json(r: &DlRecord) -> Value {
    let state = match r.state {
        DlState::Queued => "queued",
        DlState::Downloading => "downloading",
        DlState::Paused => "paused",
        DlState::Completed => "completed",
        DlState::Failed => "failed",
    };
    json!({
        "id": r.id,
        "seriesId": r.series_id,
        "title": r.title,
        "cover": r.cover,
        "episode": r.episode,
        "vid": r.vid,
        "quality": r.quality,
        "total": r.total,
        "done": r.done,
        "state": state,
        "error": r.error,
    })
}

/// 新建下载：`{seriesId, episode?, vid?, quality?, title?, cover?}`。
/// 已存在同 id 直接返回当前记录（幂等）；m3u8 明确拒绝。
pub fn start(params: &Value) -> Result<Value, SourceError> {
    let series_id = params.get("seriesId").and_then(Value::as_str).unwrap_or("");
    if series_id.is_empty() {
        return Err(SourceError::Parse("missing seriesId".to_owned()));
    }
    let episode = params
        .get("episode")
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .max(1) as u32;
    let quality = params.get("quality").and_then(Value::as_i64).unwrap_or(0);
    let id = format!("{series_id}:{episode}");
    ensure_loaded();
    let mgr = MANAGER.lock().expect("download manager poisoned");
    if let Some(task) = mgr.tasks.get(&id) {
        return Ok(record_to_json(&task.record));
    }
    // 取流复用 play 链（App→multi→public→web），但只要直链与密钥。
    let vid = params
        .get("vid")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .unwrap_or_default();
    drop(mgr);
    let (vid, media) = resolve_for_download(series_id, episode, &vid, quality)?;
    if media.url.contains(".m3u8") || media.url.contains("m3u8") {
        return Err(SourceError::Unsupported);
    }
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    let task_dir = task_dir(series_id, &vid)?;
    let _ = std::fs::create_dir_all(&task_dir);
    let title = params
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("")
        .chars()
        .take(128)
        .collect();
    let cover = params
        .get("cover")
        .and_then(Value::as_str)
        .unwrap_or("")
        .chars()
        .take(512)
        .collect();
    let record = DlRecord {
        id: id.clone(),
        series_id: series_id.to_owned(),
        title,
        cover,
        episode,
        vid,
        quality: media.quality,
        url: media.url,
        referer: media.referer.to_owned(),
        key_hex: media.key_hex,
        total: 0,
        done: 0,
        state: DlState::Queued,
        error: String::new(),
    };
    mgr.tasks.insert(
        id.clone(),
        LiveTask {
            record: record.clone(),
            cancel: CancellationToken::new(),
        },
    );
    pump_locked(&mut mgr);
    let out = record_to_json(&mgr.tasks.get(&id).expect("just inserted").record);
    persist_locked(&mgr)?;
    Ok(out)
}

fn resolve_for_download(
    series_id: &str,
    episode: u32,
    vid: &str,
    quality: i64,
) -> Result<(String, crate::app_api::ResolvedMedia), SourceError> {
    let provider = crate::source::provider(Some("hongguo"))?;
    let vid = if vid.is_empty() {
        let detail = provider.detail(series_id)?;
        let index = episode.max(1) as usize - 1;
        detail
            .get("episodes")
            .and_then(Value::as_array)
            .and_then(|eps| eps.get(index))
            .and_then(|ep| ep.get("vid"))
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
            .ok_or_else(|| SourceError::Parse("episode has no vid".to_owned()))?
            .to_owned()
    } else {
        vid.to_owned()
    };
    let media = crate::app_api::resolve_media(series_id, &vid, quality)?;
    Ok((vid, media))
}

/// 列表（按 seriesId 分组由 Dart 做；此处按更新倒序不保证，只给全量）。
pub fn list() -> Result<Value, SourceError> {
    ensure_loaded();
    let mgr = MANAGER.lock().expect("download manager poisoned");
    let mut items: Vec<Value> = mgr
        .tasks
        .values()
        .map(|t| record_to_json(&t.record))
        .collect();
    items.sort_by(|a, b| {
        b.get("episode")
            .and_then(Value::as_u64)
            .cmp(&a.get("episode").and_then(Value::as_u64))
    });
    Ok(json!({ "tasks": items }))
}

/// 暂停（协作式：worker 按块检查，当前块写完后停）。
pub fn pause(params: &Value) -> Result<Value, SourceError> {
    mutate_state(params, DlState::Paused, true)
}

/// 失败/暂停后重试（回到排队）。
pub fn retry(params: &Value) -> Result<Value, SourceError> {
    mutate_state(params, DlState::Queued, true)
}

/// 取消在途（效果同暂停，保留已下载分片）。
pub fn cancel(params: &Value) -> Result<Value, SourceError> {
    mutate_state(params, DlState::Paused, true)
}

fn mutate_state(params: &Value, state: DlState, pump: bool) -> Result<Value, SourceError> {
    let id = params.get("id").and_then(Value::as_str).unwrap_or("");
    ensure_loaded();
    let out = {
        let mut mgr = MANAGER.lock().expect("download manager poisoned");
        let task = mgr.tasks.get_mut(id).ok_or(SourceError::NotFound)?;
        if task.record.state == DlState::Completed {
            return Ok(record_to_json(&task.record));
        }
        task.cancel.cancel();
        task.cancel = CancellationToken::new();
        task.record.state = state;
        task.record.error.clear();
        record_to_json(&task.record)
    };
    if pump {
        let mut mgr = MANAGER.lock().expect("download manager poisoned");
        pump_locked(&mut mgr);
        let _ = persist_locked(&mgr);
        return Ok(out);
    }
    let mgr = MANAGER.lock().expect("download manager poisoned");
    persist_locked(&mgr)?;
    Ok(out)
}

/// 删除任务；`files=true` 同时删文件目录。
pub fn delete(params: &Value) -> Result<Value, SourceError> {
    let id = params.get("id").and_then(Value::as_str).unwrap_or("");
    let files = params
        .get("files")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    ensure_loaded();
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    let Some(task) = mgr.tasks.remove(id) else {
        return Err(SourceError::NotFound);
    };
    task.cancel.cancel();
    if files && let Ok(dir) = task_dir(&task.record.series_id, &task.record.vid) {
        let _ = std::fs::remove_dir_all(dir);
    }
    persist_locked(&mgr)?;
    Ok(json!({ "id": id }))
}

/// 离线播放：已完成任务注册文件会话，返回代理 URL（复用网关注密链）。
pub fn play_file(params: &Value) -> Result<Value, SourceError> {
    let id = params.get("id").and_then(Value::as_str).unwrap_or("");
    ensure_loaded();
    let mgr = MANAGER.lock().expect("download manager poisoned");
    let task = mgr.tasks.get(id).ok_or(SourceError::NotFound)?;
    if task.record.state != DlState::Completed {
        return Err(SourceError::Parse("download not completed".to_owned()));
    }
    let dir = task_dir(&task.record.series_id, &task.record.vid)?;
    let path = dir.join("video.mp4");
    if !path.is_file() {
        return Err(SourceError::NotFound);
    }
    let key = if task.record.key_hex.is_empty() {
        None
    } else {
        Some(hex_to_key(&task.record.key_hex)?)
    };
    let proxy = crate::gateway::register_file(&path, crate::http::USER_AGENT_VALUE.to_owned(), key)
        .map_err(SourceError::Parse)?;
    Ok(json!({
        "proxyUrl": proxy,
        "vid": task.record.vid,
        "episode": task.record.episode,
        "quality": task.record.quality,
        "encrypted": key.is_some(),
    }))
}

fn hex_to_key(hex: &str) -> Result<[u8; 16], SourceError> {
    if hex.len() != 32 {
        return Err(SourceError::Parse("bad key length".to_owned()));
    }
    let mut out = [0u8; 16];
    for (i, chunk) in out.iter_mut().enumerate() {
        *chunk = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
            .map_err(|_| SourceError::Parse("bad key hex".to_owned()))?;
    }
    Ok(out)
}

/// 工作循环：断点续传分片拉取。
async fn run_download(record: DlRecord, cancel: CancellationToken) {
    let result = download_to_file(&record, &cancel).await;
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    let Some(task) = mgr.tasks.get_mut(&record.id) else {
        return;
    };
    // 期间被删/被外部改了状态则不覆盖（暂停/取消优先）。
    if task.record.state != DlState::Downloading {
        let _ = persist_locked(&mgr);
        pump_locked(&mut mgr);
        return;
    }
    match result {
        Ok((total, done)) => {
            task.record.total = total;
            task.record.done = done;
            task.record.state = DlState::Completed;
            task.record.error.clear();
            finish_files(&record);
        }
        Err(e) => {
            if cancel.is_cancelled() && task.record.state == DlState::Downloading {
                task.record.state = DlState::Paused;
                task.record.error.clear();
            } else {
                task.record.state = DlState::Failed;
                task.record.error = e.chars().take(256).collect();
            }
        }
    }
    let _ = persist_locked(&mgr);
    pump_locked(&mut mgr);
}

fn part_path(record: &DlRecord) -> Result<std::path::PathBuf, String> {
    task_dir(&record.series_id, &record.vid)
        .map(|d| d.join("video.mp4.part"))
        .map_err(|e| e.to_string())
}

fn finish_files(record: &DlRecord) {
    let Ok(dir) = task_dir(&record.series_id, &record.vid) else {
        return;
    };
    let part = dir.join("video.mp4.part");
    let dest = dir.join("video.mp4");
    if part.is_file() {
        let _ = std::fs::rename(&part, &dest);
    }
    let meta = json!({
        "seriesId": record.series_id,
        "episode": record.episode,
        "vid": record.vid,
        "quality": record.quality,
        "keyHex": record.key_hex,
        "total": record.total,
    });
    if let Ok(raw) = serde_json::to_vec(&meta) {
        let _ = std::fs::write(dir.join("meta.json"), raw);
    }
}

/// 单块无数据超时（CDN 停顿即报错走续传重试，不无限挂起）。
const CHUNK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
/// 续传重试上限（不含首次）。
const RESUME_RETRIES: u32 = 5;

async fn download_to_file(
    record: &DlRecord,
    cancel: &CancellationToken,
) -> Result<(u64, u64), String> {
    let mut last_err = "empty".to_owned();
    for attempt in 0..=RESUME_RETRIES {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(attempt as u64)).await;
        }
        if cancel.is_cancelled() {
            return Err("cancelled".to_owned());
        }
        match download_once(record, cancel).await {
            Ok(done) => return Ok(done),
            Err(e) => {
                if e == "cancelled" {
                    return Err(e);
                }
                last_err = e;
            }
        }
    }
    Err(last_err)
}

async fn download_once(
    record: &DlRecord,
    cancel: &CancellationToken,
) -> Result<(u64, u64), String> {
    let part = part_path(record)?;
    let done = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;
    let mut req = client
        .get(&record.url)
        .header("Referer", record.referer.clone())
        .header("User-Agent", crate::http::USER_AGENT_VALUE);
    if done > 0 {
        req = req.header("Range", format!("bytes={done}-"));
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    // 不支持 Range（200 全量）但本地有分片：丢弃重下，避免拼出坏文件。
    let (mut file, mut done) = if status == 200 && done > 0 {
        (std::fs::File::create(&part).map_err(|e| e.to_string())?, 0)
    } else if status != 200 && status != 206 {
        return Err(format!("upstream status {status}"));
    } else {
        (
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&part)
                .map_err(|e| e.to_string())?,
            done,
        )
    };
    let total = resp
        .headers()
        .get("content-range")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.rsplit('/').next())
        .and_then(|s| s.trim().parse::<u64>().ok())
        .or_else(|| {
            resp.headers()
                .get("content-length")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.trim().parse::<u64>().ok())
                .map(|n| n + done)
        })
        .unwrap_or(0);
    {
        use std::io::Write;
        let mut resp = resp;
        loop {
            if cancel.is_cancelled() {
                let _ = file.flush();
                update_progress(&record.id, total, done);
                return Err("cancelled".to_owned());
            }
            match tokio::time::timeout(CHUNK_TIMEOUT, resp.chunk()).await {
                Err(_) => {
                    let _ = file.flush();
                    update_progress(&record.id, total, done);
                    return Err("chunk timeout, will resume".to_owned());
                }
                Ok(Err(e)) => return Err(e.to_string()),
                Ok(Ok(None)) => break,
                Ok(Ok(Some(chunk))) => {
                    file.write_all(&chunk).map_err(|e| e.to_string())?;
                    done += chunk.len() as u64;
                    // 每 1MB 同步一次进度（轮询可见，又不至于锁太频繁）。
                    if done % (1024 * 1024) < chunk.len() as u64 {
                        update_progress(&record.id, total, done);
                    }
                }
            }
        }
        let _ = file.flush();
    }
    update_progress(&record.id, total, done);
    Ok((total, done))
}

fn update_progress(id: &str, total: u64, done: u64) {
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    if let Some(task) = mgr.tasks.get_mut(id) {
        task.record.total = total;
        task.record.done = done;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 联网测试（默认跳过）：下一整集 → 校验文件/索引 → 离线代理出流。
    /// 跑两次可验证断点续传（第二次从 `.part` 续传不断从头）。
    #[test]
    #[ignore = "联网：下载完整分集并走离线代理"]
    fn live_download_full_episode() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let base = std::env::temp_dir().join(format!("drama-dl-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        crate::device::set_data_dir(base.join("data"));
        crate::device::set_download_dir(base.join("dl"));
        let provider = crate::source::provider(Some("hongguo")).unwrap();
        let cat = provider.catalog(Some("real-drama"), 1).unwrap();
        let series = cat["items"][0]["id"].as_str().unwrap().to_owned();
        let out = start(&json!({ "seriesId": series, "episode": 1 })).unwrap();
        let id = out["id"].as_str().unwrap().to_owned();
        // 轮询等完成（单集约 10~20MB，上限 10 分钟）。
        let mut done = false;
        for _ in 0..120 {
            std::thread::sleep(std::time::Duration::from_secs(5));
            let list = list().unwrap();
            let task = list["tasks"]
                .as_array()
                .unwrap()
                .iter()
                .find(|t| t["id"] == id)
                .expect("task vanished");
            let state = task["state"].as_str().unwrap_or("");
            eprintln!(
                "state={state} {}/{}",
                task["done"].as_u64().unwrap_or(0),
                task["total"].as_u64().unwrap_or(0)
            );
            if state == "completed" {
                done = true;
                break;
            }
            if state == "failed" {
                panic!("download failed: {}", task["error"]);
            }
        }
        assert!(done, "download did not complete in time");
        // 离线代理出流：首字节含 ftyp。
        let play = play_file(&json!({ "id": id })).unwrap();
        let proxy = play["proxyUrl"].as_str().unwrap().to_owned();
        let head: Vec<u8> = crate::http::runtime_handle().block_on(async {
            reqwest::Client::new()
                .get(&proxy)
                .header("Range", "bytes=0-31")
                .send()
                .await
                .unwrap()
                .bytes()
                .await
                .unwrap()
                .to_vec()
        });
        assert_eq!(&head[4..8], b"ftyp", "offline proxy head is not mp4");
        eprintln!("offline proxy ok, ftyp head: {}", head.len());
        crate::device::set_data_dir(std::path::PathBuf::new());
        crate::device::set_download_dir(std::path::PathBuf::new());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn record_json_state_names() {
        let mut r = DlRecord {
            id: "1:1".to_owned(),
            series_id: "1".to_owned(),
            title: String::new(),
            cover: String::new(),
            episode: 1,
            vid: "2".to_owned(),
            quality: 720,
            url: String::new(),
            referer: String::new(),
            key_hex: String::new(),
            total: 100,
            done: 25,
            state: DlState::Downloading,
            error: String::new(),
        };
        assert_eq!(record_to_json(&r)["state"], json!("downloading"));
        r.state = DlState::Failed;
        assert_eq!(record_to_json(&r)["state"], json!("failed"));
    }

    #[test]
    fn hex_key_validation() {
        assert!(hex_to_key(&"ab".repeat(16)).is_ok());
        assert!(hex_to_key("zz".repeat(16).as_str()).is_err());
        assert!(hex_to_key("abc").is_err());
    }
}
