//! 下载管理器（离线面）。
//!
//! 单文件 MP4 下载（m3u8 明确拒绝，走在线代理播）：
//! **多连接分片 Range 拉取** + `.part` 逐段写桩 + 完成改名 + 索引持久化。
//! 任务并发数可调（默认 2，上限 6），其余排队；暂停/取消协作式（按块检查），
//! Dart 侧轮询 `downloadList` 取进度与速度，不做跨线程推送。
//!
//! 离线播放复用网关注密链：完成文件 + 索引里的密钥经
//! `gateway::register_file` 注册为文件会话（`play_local`）。

use std::collections::HashMap;
use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::fs::OpenOptions;
use tokio::io::{AsyncSeekExt, AsyncWriteExt};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use crate::source::traits::SourceError;

/// 默认并行任务数。
const DEFAULT_PARALLEL: usize = 2;
/// 并行任务数上限（与设置页选项一致）。
const MAX_PARALLEL_LIMIT: usize = 6;
/// 单任务的分段（连接）数；与任务数相乘后受总连接上限约束。
const CONNECTIONS_PER_TASK: usize = 3;
/// 总连接上限（含所有在途任务的分段连接）。
const MAX_TOTAL_CONNECTIONS: usize = 12;
/// 分片下载的最小段体积：低于此值时握手开销占比过高，退化为单连接。
const MIN_SEGMENT_BYTES: u64 = 512 * 1024;
/// 单连接无数据超时（CDN 停顿即报错走续传重试，不无限挂起）。
const CHUNK_TIMEOUT: Duration = Duration::from_secs(30);
/// 续传重试上限（不含首次）。
const RESUME_RETRIES: u32 = 5;
/// 续传重试等待上限（秒，按轮次线性增长）。
const RESUME_BACKOFF_CAP_SECS: u64 = 8;
/// 进度上报最小间隔（轮询可见，又不至于频繁抢锁）。
const REPORT_INTERVAL: Duration = Duration::from_millis(250);
/// 续传 sidecar 落盘最小间隔。
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(2);

/// 索引文件名。
const INDEX_FILE: &str = "downloads.json";
/// 设置文件名（并发数持久化，独立于索引以免破坏其结构）。
const SETTINGS_FILE: &str = "settings.json";

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

/// 单个 Range 段：`[start, end]` 闭区间，`done` 为本段已写入字节。
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
struct Segment {
    start: u64,
    end: u64,
    done: u64,
}

impl Segment {
    fn len(&self) -> u64 {
        self.end + 1 - self.start
    }
    fn finished(&self) -> bool {
        self.done >= self.len()
    }
}

/// 续传 sidecar：记录本次任务的体积、是否支持 Range 与各段进度。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Resume {
    url: String,
    total: u64,
    ranges: bool,
    segments: Vec<Segment>,
}

/// 持久化设置。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Settings {
    #[serde(default)]
    parallel: usize,
}

/// 速度采样器（EMA，单位 bytes/s）。
#[derive(Debug, Default)]
struct Meter {
    last_done: u64,
    last_ts: Option<Instant>,
    ema: f64,
}

impl Meter {
    fn reset(&mut self) {
        self.last_done = 0;
        self.last_ts = None;
        self.ema = 0.0;
    }

    /// 采样：两次采样间隔 ≥250ms 才更新 EMA（避免抖动主导读数）。
    fn sample(&mut self, done: u64, now: Instant) -> f64 {
        let Some(ts) = self.last_ts else {
            self.last_ts = Some(now);
            self.last_done = done;
            return 0.0;
        };
        let dt = now.duration_since(ts).as_secs_f64();
        if dt < 0.25 {
            return self.ema;
        }
        let instant = done.saturating_sub(self.last_done) as f64 / dt;
        self.ema = if self.ema <= 0.0 {
            instant
        } else {
            self.ema * 0.7 + instant * 0.3
        };
        self.last_ts = Some(now);
        self.last_done = done;
        self.ema
    }
}

struct LiveTask {
    record: DlRecord,
    cancel: CancellationToken,
    meter: Meter,
    /// 最近一次采样得到的速度（bytes/s），仅运行期使用。
    speed_bps: u64,
}

struct Manager {
    tasks: HashMap<String, LiveTask>,
    loaded: bool,
    /// 搬迁中：暂停开工，避免 worker 写向正在搬走的路径。
    moving: bool,
}

static MANAGER: Lazy<Mutex<Manager>> = Lazy::new(|| {
    Mutex::new(Manager {
        tasks: HashMap::new(),
        loaded: false,
        moving: false,
    })
});

/// 并行任务数（可由 `downloadSetConcurrency` 调整）。
static PARALLEL: AtomicUsize = AtomicUsize::new(DEFAULT_PARALLEL);

fn max_parallel() -> usize {
    PARALLEL
        .load(Ordering::Relaxed)
        .clamp(1, MAX_PARALLEL_LIMIT)
}

/// 单任务可用连接数：在总连接预算内按任务数切分，至少 1。
fn connections_per_task(parallel: usize) -> usize {
    let budget = MAX_TOTAL_CONNECTIONS / parallel.max(1);
    CONNECTIONS_PER_TASK.min(budget.max(1))
}

/// 独立下载运行时（长任务不占元数据/网关 worker）。
static DOWNLOAD_RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .thread_name("dl-worker")
        .enable_all()
        .build()
        .expect("build download runtime")
});

fn dir() -> Result<PathBuf, SourceError> {
    crate::device::download_dir()
        .ok_or_else(|| SourceError::Parse("download dir not initialized (call init)".to_owned()))
}

fn index_path() -> Result<PathBuf, SourceError> {
    Ok(dir()?.join(INDEX_FILE))
}

fn settings_path() -> Result<PathBuf, SourceError> {
    Ok(dir()?.join(SETTINGS_FILE))
}

fn task_dir(series_id: &str, vid: &str) -> Result<PathBuf, SourceError> {
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

/// 延迟加载索引与设置。
fn ensure_loaded() {
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    if mgr.loaded {
        return;
    }
    mgr.loaded = true;
    load_settings();
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
                meter: Meter::default(),
                speed_bps: 0,
            },
        );
    }
}

/// 设置加载：只认 1..=上限，越界/损坏一律回落默认值。
fn load_settings() {
    if let Ok(path) = settings_path()
        && let Ok(raw) = std::fs::read(&path)
        && let Ok(settings) = serde_json::from_slice::<Settings>(&raw)
        && (1..=MAX_PARALLEL_LIMIT).contains(&settings.parallel)
    {
        PARALLEL.store(settings.parallel, Ordering::Relaxed);
    }
}

fn save_settings(parallel: usize) {
    if let Ok(path) = settings_path() {
        let settings = Settings { parallel };
        if let Ok(raw) = serde_json::to_vec(&settings) {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(&path, raw);
        }
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
    if mgr.moving {
        return;
    }
    let limit = max_parallel();
    let mut room = limit.saturating_sub(
        mgr.tasks
            .values()
            .filter(|t| t.record.state == DlState::Downloading)
            .count(),
    );
    while room > 0 {
        let next = mgr
            .tasks
            .iter()
            .find(|(_, t)| t.record.state == DlState::Queued)
            .map(|(id, _)| id.clone());
        let Some(id) = next else { break };
        spawn_locked(mgr, &id);
        room -= 1;
    }
}

/// 置为下载中并派生 worker（调用方持有锁）。
fn spawn_locked(mgr: &mut Manager, id: &str) {
    let Some(task) = mgr.tasks.get_mut(id) else {
        return;
    };
    task.record.state = DlState::Downloading;
    task.record.error.clear();
    task.cancel = CancellationToken::new();
    task.meter.reset();
    task.speed_bps = 0;
    let cancel = task.cancel.clone();
    let record = task.record.clone();
    DOWNLOAD_RT.spawn(async move {
        run_download(record, cancel).await;
    });
}

fn record_to_json(r: &DlRecord, speed_bps: u64) -> Value {
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
        "speed": speed_bps,
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
        return Ok(record_to_json(&task.record, task.speed_bps));
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
    if media.url.contains("m3u8") {
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
            meter: Meter::default(),
            speed_bps: 0,
        },
    );
    pump_locked(&mut mgr);
    let task = mgr.tasks.get(&id).expect("just inserted");
    let out = record_to_json(&task.record, task.speed_bps);
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

/// 列表：全量任务（按 seriesId 分组由 Dart 做）+ 当前并发配置。
pub fn list() -> Result<Value, SourceError> {
    ensure_loaded();
    let mgr = MANAGER.lock().expect("download manager poisoned");
    let mut items: Vec<Value> = mgr
        .tasks
        .values()
        .map(|t| record_to_json(&t.record, t.speed_bps))
        .collect();
    items.sort_by(|a, b| {
        b.get("episode")
            .and_then(Value::as_u64)
            .cmp(&a.get("episode").and_then(Value::as_u64))
    });
    let parallel = max_parallel();
    Ok(json!({
        "tasks": items,
        "parallel": parallel,
        "connections": connections_per_task(parallel),
        // 当前下载根：UI 要把它显示出来（搬迁前得让用户知道现在在哪）。
        "dir": dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
    }))
}

/// 调整并行任务数（1..=6），持久化到下载目录 `settings.json`。
pub fn set_concurrency(params: &Value) -> Result<Value, SourceError> {
    let raw = params.get("parallel").and_then(Value::as_u64).unwrap_or(0) as usize;
    if !(1..=MAX_PARALLEL_LIMIT).contains(&raw) {
        return Err(SourceError::Parse(format!(
            "parallel must be 1..={MAX_PARALLEL_LIMIT}"
        )));
    }
    ensure_loaded();
    PARALLEL.store(raw, Ordering::Relaxed);
    save_settings(raw);
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    pump_locked(&mut mgr);
    Ok(json!({
        "parallel": max_parallel(),
        "connections": connections_per_task(max_parallel()),
    }))
}

/// 暂停（协作式：worker 按块检查，当前块写完后停）。
pub fn pause(params: &Value) -> Result<Value, SourceError> {
    mutate_state(params, DlState::Paused, true)
}

/// 失败/暂停后重试（回到排队）。
pub fn retry(params: &Value) -> Result<Value, SourceError> {
    mutate_state(params, DlState::Queued, true)
}

/// 取消在途（效果同暂停，保留已下载分片，可续传）。
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
            return Ok(record_to_json(&task.record, task.speed_bps));
        }
        task.cancel.cancel();
        task.cancel = CancellationToken::new();
        task.record.state = state;
        task.record.error.clear();
        task.speed_bps = 0;
        record_to_json(&task.record, 0)
    };
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    if pump {
        pump_locked(&mut mgr);
    }
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
    pump_locked(&mut mgr);
    Ok(json!({ "id": id }))
}

/// 迁移下载目录：`{dir}` → `{dir, moved, bytes}`。
///
/// 停机顺序：**先**置 `moving` 标记并掐掉全部在途 worker（回到排队），
/// 等 worker 确实退出后再搬——否则 worker 会一边写旧路径一边被搬走，
/// 表现为进度倒退或坏文件。搬迁用「复制 → 切换根 → 落新索引 → 删旧」，
/// 任一步失败都保留旧目录不动（只 `moving` 复位，任务仍在旧路径可用）。
pub fn move_downloads(params: &Value) -> Result<Value, SourceError> {
    let raw = params
        .get("dir")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if raw.is_empty() {
        return Err(SourceError::Parse("missing dir".to_owned()));
    }
    let target = PathBuf::from(raw);
    let from = dir()?;

    ensure_loaded();
    // ① 停机：掐掉在途 worker 并禁止新的开工。
    {
        let mut mgr = MANAGER.lock().expect("download manager poisoned");
        mgr.moving = true;
        for task in mgr.tasks.values_mut() {
            if task.record.state == DlState::Downloading {
                task.cancel.cancel();
                task.record.state = DlState::Queued;
                task.speed_bps = 0;
            }
        }
    }
    // ② 等静默（worker 在下一个块边界退出），上限 8s。
    let quiet = wait_until_quiet(Duration::from_secs(8));
    if !quiet {
        release_moving();
        return Err(SourceError::Parse(
            "downloads still active, retry later".to_owned(),
        ));
    }

    let outcome = do_move(&from, &target);
    match outcome {
        Ok((moved, bytes)) => {
            release_moving();
            let mut mgr = MANAGER.lock().expect("download manager poisoned");
            pump_locked(&mut mgr);
            let _ = persist_locked(&mgr);
            Ok(json!({
                "dir": target.to_string_lossy(),
                "moved": moved,
                "bytes": bytes,
            }))
        }
        Err(e) => {
            release_moving();
            Err(SourceError::Parse(e))
        }
    }
}

/// 搬迁实现（失败返回错误信息，调用方负责复位 `moving`）。
///
/// 同路径（canonical 相等）视为空操作，返回 0；目标根下若已有同名
/// 任务目录或索引文件，一律中止——不做覆盖合并，避免静默丢数据。
fn do_move(from: &Path, target: &Path) -> Result<(usize, u64), String> {
    let from_canon = from.canonicalize().unwrap_or_else(|_| from.to_path_buf());
    let target_canon = target
        .canonicalize()
        .unwrap_or_else(|_| target.to_path_buf());
    if from_canon == target_canon {
        return Ok((0, 0));
    }
    std::fs::create_dir_all(target).map_err(|e| format!("create target: {e}"))?;
    let entries = std::fs::read_dir(from).map_err(|e| format!("read source: {e}"))?;
    let mut sources: Vec<PathBuf> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_owned();
        if name == INDEX_FILE || name == SETTINGS_FILE || name.ends_with(".tmp") {
            continue;
        }
        sources.push(path);
    }
    for path in &sources {
        let dest = target.join(path.file_name().unwrap_or_default());
        if dest.exists() {
            return Err(format!(
                "target already contains {}",
                dest.file_name().and_then(|n| n.to_str()).unwrap_or("item")
            ));
        }
    }
    let mut moved = 0usize;
    let mut bytes = 0u64;
    for path in &sources {
        let dest = target.join(path.file_name().unwrap_or_default());
        let added = copy_entry(path, &dest).map_err(|e| format!("copy {}: {e}", dest.display()))?;
        bytes += added;
        moved += 1;
    }
    // 先切换根再重写索引：之后所有路径都指向新目录，旧目录成为纯垃圾。
    let parallel = max_parallel();
    crate::device::set_download_dir(target.to_path_buf());
    save_settings(parallel);
    {
        let mgr = MANAGER.lock().expect("download manager poisoned");
        persist_locked(&mgr).map_err(|e| format!("write index: {e}"))?;
    }
    for path in &sources {
        if path.is_dir() {
            let _ = std::fs::remove_dir_all(path);
        } else {
            let _ = std::fs::remove_file(path);
        }
    }
    let _ = std::fs::remove_file(from.join(INDEX_FILE));
    let _ = std::fs::remove_file(from.join(SETTINGS_FILE));
    Ok((moved, bytes))
}

/// 复制目录或文件，返回累计字节数。
fn copy_entry(src: &Path, dst: &Path) -> Result<u64, std::io::Error> {
    if src.is_file() {
        let bytes = std::fs::copy(src, dst)?;
        return Ok(bytes);
    }
    std::fs::create_dir_all(dst)?;
    let mut total = 0u64;
    for entry in std::fs::read_dir(src)?.flatten() {
        let name = entry.file_name();
        total += copy_entry(&entry.path(), &dst.join(name))?;
    }
    Ok(total)
}

/// 等待在途 worker 退出（回复后可重新开工）。
fn wait_until_quiet(budget: Duration) -> bool {
    let deadline = Instant::now() + budget;
    loop {
        let active = MANAGER
            .lock()
            .expect("download manager poisoned")
            .tasks
            .values()
            .filter(|t| t.record.state == DlState::Downloading)
            .count();
        if active == 0 {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn release_moving() {
    MANAGER.lock().expect("download manager poisoned").moving = false;
}

/// 离线播放：已完成任务注册文件会话，返回代理 URL（复用网关注密链）。
pub fn play_file(params: &Value) -> Result<Value, SourceError> {
    let id = params.get("id").and_then(Value::as_str).unwrap_or("");
    ensure_loaded();
    let mgr = MANAGER.lock().expect("download manager poisoned");
    let task = mgr.tasks.get(id).ok_or(SourceError::NotFound)?;
    local_playback_of(&task.record)
}

/// 按「剧 + 集」取已完成文件的播放计划（供播放器离线优先取流）。
///
/// 返回结构与在线 `play` **同构**（`proxyUrl`/`vid`/`quality`/`variants` 齐全），
/// 没有对应完成任务时返回 `NotFound`——调用方据此回落到在线取流。
pub fn play_local(params: &Value) -> Result<Value, SourceError> {
    let series_id = params.get("id").and_then(Value::as_str).unwrap_or("");
    let episode = params
        .get("episode")
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .max(1);
    if series_id.is_empty() {
        return Err(SourceError::Parse("missing id".to_owned()));
    }
    ensure_loaded();
    let mgr = MANAGER.lock().expect("download manager poisoned");
    let id = format!("{series_id}:{episode}");
    let task = mgr.tasks.get(&id).ok_or(SourceError::NotFound)?;
    local_playback_of(&task.record)
}

fn local_playback_of(record: &DlRecord) -> Result<Value, SourceError> {
    if record.state != DlState::Completed {
        return Err(SourceError::NotFound);
    }
    let dir = task_dir(&record.series_id, &record.vid)?;
    let path = dir.join("video.mp4");
    if !path.is_file() {
        return Err(SourceError::NotFound);
    }
    let key = if record.key_hex.is_empty() {
        None
    } else {
        Some(hex_to_key(&record.key_hex)?)
    };
    let proxy = crate::gateway::register_file(&path, crate::http::USER_AGENT_VALUE.to_owned(), key)
        .map_err(SourceError::Parse)?;
    Ok(json!({
        "proxyUrl": proxy,
        "url": path.to_string_lossy(),
        "vid": record.vid,
        "episode": record.episode,
        "quality": record.quality,
        "encrypted": key.is_some(),
        "durationSecs": 0,
        "variants": [],
        "offline": true,
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

/// worker 收尾：写结果 / 错误，并在需要时写回 sidecar 的收尾状态。
async fn run_download(record: DlRecord, cancel: CancellationToken) {
    let connections = connections_per_task(max_parallel());
    let result = download_to_file(&record, &cancel, connections).await;
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
            task.speed_bps = 0;
            finish_files(&record, total);
        }
        Err(e) => {
            if cancel.is_cancelled() && task.record.state == DlState::Downloading {
                task.record.state = DlState::Paused;
                task.record.error.clear();
            } else {
                task.record.state = DlState::Failed;
                task.record.error = e.chars().take(256).collect();
            }
            task.speed_bps = 0;
        }
    }
    let _ = persist_locked(&mgr);
    pump_locked(&mut mgr);
}

fn part_path(record: &DlRecord) -> std::result::Result<PathBuf, SourceError> {
    task_dir(&record.series_id, &record.vid).map(|d| d.join("video.mp4.part"))
}

fn progress_path(record: &DlRecord) -> std::result::Result<PathBuf, SourceError> {
    task_dir(&record.series_id, &record.vid).map(|d| d.join("video.mp4.progress.json"))
}

fn finish_files(record: &DlRecord, total: u64) {
    let Ok(dir) = task_dir(&record.series_id, &record.vid) else {
        return;
    };
    let part = dir.join("video.mp4.part");
    let dest = dir.join("video.mp4");
    // 收尾前校一次体积：短一寸说明段进度记账偏乐观，宁可留 .part 重传
    // 也不能把坏文件改名为成品（坏文件表现为「能播但黑屏/提前结束」）。
    let size = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if total == 0 || size < total {
        return;
    }
    let _ = std::fs::rename(&part, &dest);
    let _ = std::fs::remove_file(dir.join("video.mp4.progress.json"));
    let meta = json!({
        "seriesId": record.series_id,
        "episode": record.episode,
        "vid": record.vid,
        "quality": record.quality,
        "keyHex": record.key_hex,
        "total": total,
    });
    if let Ok(raw) = serde_json::to_vec(&meta) {
        let _ = std::fs::write(dir.join("meta.json"), raw);
    }
}

/// 首次探测：一次 `Range: bytes=0-1` 拿到总体积与是否支持 Range。
///
/// 不读 body（只取响应头后丢弃），代价是 2 字节。
async fn probe_resource(record: &DlRecord) -> Result<(u64, bool), String> {
    let resp = crate::http::download_client()
        .get(&record.url)
        .header("Referer", record.referer.clone())
        .header("User-Agent", crate::http::USER_AGENT_VALUE)
        .header("Range", "bytes=0-1")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    match status {
        // 206：支持 Range，总体积从 Content-Range 的 `total` 段取。
        206 => {
            let total = content_range_total(&resp).ok_or("missing content-range")?;
            Ok((total, true))
        }
        // 200：不支持 Range（整下发），Content-Length 即总体积。
        200 => {
            let total = resp
                .headers()
                .get(reqwest::header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.trim().parse::<u64>().ok())
                .ok_or("missing content-length")?;
            Ok((total, false))
        }
        other => Err(format!("upstream status {other}")),
    }
}

fn content_range_total(resp: &reqwest::Response) -> Option<u64> {
    resp.headers()
        .get(reqwest::header::CONTENT_RANGE)?
        .to_str()
        .ok()?
        .rsplit('/')
        .next()?
        .trim()
        .parse::<u64>()
        .ok()
}

/// 规划分段：不支持 Range 或体积过小 → 单段（等于单连接整下发）。
fn plan_segments(total: u64, ranges: bool, connections: usize) -> Vec<Segment> {
    let single = || {
        vec![Segment {
            start: 0,
            end: total.saturating_sub(1),
            done: 0,
        }]
    };
    if !ranges || total == 0 {
        return single();
    }
    let conns = connections.max(1);
    if total / conns as u64 >= MIN_SEGMENT_BYTES {
        let mut out = Vec::with_capacity(conns);
        let mut start = 0u64;
        for i in 0..conns {
            let end = if i + 1 == conns {
                total - 1
            } else {
                start + total / conns as u64 - 1
            };
            out.push(Segment {
                start,
                end,
                done: 0,
            });
            start = end + 1;
        }
        return out;
    }
    single()
}

/// 读 sidecar：只有 `url` 与本地记录一致时才认可（换源/改清晰度一律作废）。
async fn load_resume(record: &DlRecord) -> Option<Resume> {
    let Ok(path) = progress_path(record) else {
        return None;
    };
    let raw = tokio::fs::read(&path).await.ok()?;
    let resume = serde_json::from_slice::<Resume>(&raw).ok()?;
    if resume.url == record.url && resume.total > 0 && !resume.segments.is_empty() {
        return Some(resume);
    }
    None
}

/// 记账与实际磁盘是否自洽：任一段写到过的位置超过文件大小，说明内容丢了
/// （被清理/迁移中断），此时段进度不可信，必须整轮重来。
fn written_extent(segments: &[Segment]) -> u64 {
    segments
        .iter()
        .map(|s| s.start + s.done.min(s.len()))
        .max()
        .unwrap_or(0)
}

/// 多段下载进度共享态。
struct Shared {
    total: u64,
    url: String,
    segments: Mutex<Vec<Segment>>,
    last_report: Mutex<Instant>,
    last_checkpoint: Mutex<Instant>,
    task_id: String,
    path: PathBuf,
}

impl Shared {
    /// 汇总已完成字节，并按间隔上报给 manager（含速度 EMA）与 sidecar。
    fn report(&self, force: bool) {
        let now = Instant::now();
        let due = {
            let mut last = self.last_report.lock().expect("report poisoned");
            if force || now.duration_since(*last) >= REPORT_INTERVAL {
                *last = now;
                true
            } else {
                false
            }
        };
        if !due {
            return;
        }
        let done: u64 = self
            .segments
            .lock()
            .expect("segments poisoned")
            .iter()
            .map(|s| s.done)
            .sum();
        update_progress(&self.task_id, self.total, done, now);
    }

    /// 续传 sidecar 落盘：默认按 [`CHECKPOINT_INTERVAL`] 节流，`force` 用于
    /// 收尾时刻必须把段进度钉到磁盘的场合。
    ///
    /// 写入用 **await 而非 spawn**：收尾那一刻必须真的写完，
    /// 否则「取消后立刻回来续」读不到 progress，会被迫整轮重下。
    async fn checkpoint(&self, force: bool) {
        let now = Instant::now();
        {
            let mut last = self.last_checkpoint.lock().expect("checkpoint poisoned");
            if !force && now.duration_since(*last) < CHECKPOINT_INTERVAL {
                return;
            }
            *last = now;
        }
        let snapshot = {
            let segs = self.segments.lock().expect("segments poisoned");
            segs.clone()
        };
        let resume = Resume {
            url: self.url.clone(),
            total: self.total,
            ranges: true,
            segments: snapshot,
        };
        if let Ok(raw) = serde_json::to_vec(&resume) {
            let _ = tokio::fs::write(&self.path, raw).await;
        }
    }
}

async fn download_to_file(
    record: &DlRecord,
    cancel: &CancellationToken,
    connections: usize,
) -> Result<(u64, u64), String> {
    let mut last_err = "empty".to_owned();
    for attempt in 0..=RESUME_RETRIES {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_secs(
                (attempt as u64).min(RESUME_BACKOFF_CAP_SECS),
            ))
            .await;
        }
        if cancel.is_cancelled() {
            return Err("cancelled".to_owned());
        }
        match download_once(record, cancel, connections).await {
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

/// 一轮完整下载：探测 → 规划/续传 → 多段并发拉取 → 合并验收。
async fn download_once(
    record: &DlRecord,
    cancel: &CancellationToken,
    connections: usize,
) -> Result<(u64, u64), String> {
    let dir = task_dir(&record.series_id, &record.vid).map_err(|e| e.to_string())?;
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| e.to_string())?;
    let part = part_path(record).map_err(|e| e.to_string())?;
    let part_len = tokio::fs::metadata(&part)
        .await
        .map(|m| m.len())
        .unwrap_or(0);

    let mut resume = load_resume(record).await;
    if resume.is_none() {
        // 没有可核验的段进度（首次 / 以前单连接留下的 `.part` / 被强杀未来得及落盘）
        // → **作废重来**。多段写会让 `.part` 呈「前半有洞、后半已写」的形态，
        // 只凭文件大小无法定位已写字节，按大小续传会拼出坏文件
        // （表现为能播但花屏/提前结束），所以不猜。
        if part_len > 0 {
            tokio::fs::remove_file(&part).await.ok();
        }
        let (total, ranges) = probe_resource(record).await?;
        resume = Some(Resume {
            url: record.url.clone(),
            total,
            ranges,
            segments: plan_segments(total, ranges, connections),
        });
    }
    let mut resume = resume.expect("plan ready");
    // 磁盘内容与记账不一致（例如迁移被打断）→ 同样重来。
    if part_len < written_extent(&resume.segments) {
        if part_len > 0 {
            tokio::fs::remove_file(&part).await.ok();
        }
        for seg in &mut resume.segments {
            seg.done = 0;
        }
    }
    let total = resume.total;
    let shared = Arc::new(Shared {
        total,
        url: record.url.clone(),
        segments: Mutex::new(resume.segments.clone()),
        last_report: Mutex::new(Instant::now()),
        last_checkpoint: Mutex::new(Instant::now()),
        task_id: record.id.clone(),
        path: progress_path(record).map_err(|e| e.to_string())?,
    });

    // 已完成的段不再起连接（续传语义）。
    // 带上段起点：续传时 `from` 只是**本连接**的起点，`done` 要以段起点为基线算。
    let targets: Vec<(usize, u64, u64, u64)> = {
        let segs = shared.segments.lock().expect("segments poisoned");
        segs.iter()
            .enumerate()
            .filter(|(_, s)| !s.finished())
            .map(|(i, s)| (i, s.start, s.start + s.done, s.end))
            .collect()
    };
    if targets.is_empty() {
        shared.report(true);
        return Ok((total, total));
    }

    // Windows 下同一文件**不能**被并发 open 多次（第二个起即“拒绝访问”），
    // 故全段共用一个句柄，桶成一把异步锁；每次写入只持锁一次 write，
    // 网络等待仍在锁外，因此并发收益不受影响。
    let handle = OpenOptions::new()
        .create(true)
        // 明确保留已有内容：`.part` 是续传载体，截断会让断点失效。
        .truncate(false)
        .write(true)
        .open(&part)
        .await
        .map_err(|e| e.to_string())?;
    let writer = Arc::new(tokio::sync::Mutex::new(handle));
    let mut set = JoinSet::new();
    for (index, segment_start, from, end) in targets {
        set.spawn(pull_segment(
            Pull {
                index,
                start: segment_start,
                from,
                end,
            },
            record.url.clone(),
            record.referer.clone(),
            Arc::clone(&writer),
            Arc::clone(&shared),
            cancel.clone(),
        ));
    }
    let mut outcome: std::result::Result<(), String> = Ok(());
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                if outcome.is_err() {
                    continue;
                }
                outcome = Err(e);
                // 其余段立即收尾（它们的连接会被 JoinSet drop 中断）。
                break;
            }
            Err(e) => {
                if outcome.is_ok() {
                    outcome = Err(format!("task join: {e}"));
                }
                break;
            }
        }
    }
    shared.report(true);
    // 无论成功失败，收尾都要把段进度钉到磁盘（下一次据此续传）。
    shared.checkpoint(true).await;
    let done: u64 = shared
        .segments
        .lock()
        .expect("segments poisoned")
        .iter()
        .map(|s| s.done)
        .sum();
    outcome?;
    Ok((total, done))
}

/// 定位写入：复用同一个文件句柄（Windows 下不允许并发多次 open），
/// 每次写入先 seek 到段内偏移再写，写完立即释放锁，让其他段继续。
async fn write_at(
    file: &tokio::sync::Mutex<tokio::fs::File>,
    offset: u64,
    bytes: &[u8],
) -> std::result::Result<(), String> {
    let mut guard = file.lock().await;
    guard
        .seek(SeekFrom::Start(offset))
        .await
        .map_err(|e| e.to_string())?;
    guard.write_all(bytes).await.map_err(|e| e.to_string())?;
    Ok(())
}

/// 单段的拉取范围。
///
/// `start` 是**段起点**（记账基线），`from` 是**本次连接**起点；
/// 续传时两者不同：`done = cursor - start`，绝不能用 `cursor - from`。
struct Pull {
    index: usize,
    start: u64,
    from: u64,
    end: u64,
}

/// 单段拉取：`Range: bytes={from}-{end}` → 按偏移写入 `.part`。
///
/// 所有段共用同一个文件句柄做**定位写**，因此并发不再受
/// “Windows 同文件不可并发 open”的限制；每段只统计自己写过的字节
/// （少算最多一个上报间隔的量，续传时会重取重叠部分，而写入是定位写，
/// 重写的仍是同一段数据，不会拼坏）。
async fn pull_segment(
    plan: Pull,
    url: String,
    referer: String,
    file: Arc<tokio::sync::Mutex<tokio::fs::File>>,
    shared: Arc<Shared>,
    cancel: CancellationToken,
) -> std::result::Result<(), String> {
    let Pull {
        index,
        start: segment_start,
        from,
        end,
    } = plan;
    let mut req = crate::http::download_client()
        .get(&url)
        .header("Referer", referer)
        .header("User-Agent", crate::http::USER_AGENT_VALUE);
    // 服务端明确不支持 Range 时（单段整下发）不写 Range 头。
    if from > 0 || end + 1 < shared.total {
        req = req.header("Range", format!("bytes={from}-{end}"));
    }
    let mut resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    if status != 200 && status != 206 {
        return Err(format!("upstream status {status}"));
    }
    let mut cursor = from;
    loop {
        if cancel.is_cancelled() {
            record_segment(index, cursor - segment_start, &shared);
            shared.checkpoint(true).await;
            return Err("cancelled".to_owned());
        }
        let remaining = end + 1 - cursor;
        if remaining == 0 {
            break;
        }
        match tokio::time::timeout(CHUNK_TIMEOUT, resp.chunk()).await {
            Err(_) => {
                record_segment(index, cursor - segment_start, &shared);
                return Err("chunk timeout, will resume".to_owned());
            }
            Ok(Err(e)) => {
                record_segment(index, cursor - segment_start, &shared);
                return Err(e.to_string());
            }
            Ok(Ok(None)) => break,
            Ok(Ok(Some(chunk))) => {
                // 服务端可能多给（忽略 Range 时），截断到本段边界。
                let take = (chunk.len() as u64).min(remaining) as usize;
                write_at(&file, cursor, &chunk[..take]).await?;
                cursor += take as u64;
                record_segment(index, cursor - segment_start, &shared);
                shared.report(false);
                shared.checkpoint(false).await;
            }
        }
    }
    record_segment(index, cursor - segment_start, &shared);
    let done_here = cursor - from;
    let expected = end + 1 - from;
    if done_here < expected {
        return Err(format!(
            "segment short read {done_here}/{expected}, will resume"
        ));
    }
    Ok(())
}

/// 写入某段的已完成量（段思维：起点 + 已写字节）。
fn record_segment(index: usize, written: u64, shared: &Arc<Shared>) {
    let mut segs = shared.segments.lock().expect("segments poisoned");
    if let Some(seg) = segs.get_mut(index) {
        seg.done = written.min(seg.len());
    }
}

fn update_progress(id: &str, total: u64, done: u64, now: Instant) {
    let mut mgr = MANAGER.lock().expect("download manager poisoned");
    if let Some(task) = mgr.tasks.get_mut(id) {
        task.record.total = total;
        task.record.done = done;
        task.speed_bps = task.meter.sample(done, now).max(0.0) as u64;
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
                "state={state} {}/{} speed={}B/s",
                task["done"].as_u64().unwrap_or(0),
                task["total"].as_u64().unwrap_or(0),
                task["speed"].as_u64().unwrap_or(0),
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
        assert_eq!(record_to_json(&r, 0)["state"], json!("downloading"));
        r.state = DlState::Failed;
        assert_eq!(record_to_json(&r, 0)["state"], json!("failed"));
        // 速度与进度同时下发，供 UI 显示「已完成 / 剩余时间」。
        let json = record_to_json(&r, 1024);
        assert_eq!(json["done"], json!(25));
        assert_eq!(json["speed"], json!(1024));
    }

    #[test]
    fn hex_key_validation() {
        assert!(hex_to_key(&"ab".repeat(16)).is_ok());
        assert!(hex_to_key("zz".repeat(16).as_str()).is_err());
        assert!(hex_to_key("abc").is_err());
    }

    #[test]
    fn segment_planning_splits_and_falls_back_to_single() {
        // 支持 Range 且每连接 ≥1MiB → 按连接数均分，末段吃掉余数。
        let segs = plan_segments(10 * 1024 * 1024, true, 3);
        assert_eq!(segs.len(), 3);
        assert_eq!(segs[0].start, 0);
        assert_eq!(segs[2].end, 10 * 1024 * 1024 - 1);
        assert_eq!(segs.iter().map(|s| s.len()).sum::<u64>(), 10 * 1024 * 1024);

        // 不支持 Range → 单段整下发。
        let single = plan_segments(10 * 1024 * 1024, false, 3);
        assert_eq!(single.len(), 1);
        assert_eq!(single[0].len(), 10 * 1024 * 1024);

        // 体积过小 → 不分片（握手开销占比过高）。
        assert_eq!(plan_segments(700 * 1024, true, 4).len(), 1);
    }

    #[test]
    fn segment_finished_and_len_are_consistent() {
        let mut seg = Segment {
            start: 10,
            end: 19,
            done: 0,
        };
        assert_eq!(seg.len(), 10);
        assert!(!seg.finished());
        seg.done = 10;
        assert!(seg.finished());
        // 记账溢出不影响判定。
        seg.done = 99;
        assert!(seg.finished());
    }

    #[test]
    fn concurrency_bounds_are_enforced() {
        assert!(set_concurrency(&json!({ "parallel": 0 })).is_err());
        assert!(set_concurrency(&json!({ "parallel": 99 })).is_err());
        let old = max_parallel();
        let out = set_concurrency(&json!({ "parallel": 4 })).unwrap();
        assert_eq!(out["parallel"], json!(4));
        assert!(out["connections"].as_u64().unwrap() >= 1);
        let _ = set_concurrency(&json!({ "parallel": old }));
    }

    #[test]
    fn total_connection_budget_is_shared_between_tasks() {
        // 并行任务越多，单任务的连接数越少，但至少 1。
        assert!(connections_per_task(1) >= CONNECTIONS_PER_TASK.min(MAX_TOTAL_CONNECTIONS));
        assert!(connections_per_task(MAX_PARALLEL_LIMIT) >= 1);
        for p in 1..=MAX_PARALLEL_LIMIT {
            assert!(p * connections_per_task(p) <= MAX_TOTAL_CONNECTIONS.max(p));
        }
    }

    #[test]
    fn meter_smooths_and_reports_bytes_per_second() {
        let mut meter = Meter::default();
        let t0 = Instant::now();
        assert_eq!(meter.sample(0, t0), 0.0);
        // 间隔不足 250ms → 读数不变。
        assert_eq!(meter.sample(1000, t0 + Duration::from_millis(50)), 0.0);
        let speed = meter.sample(500_000, t0 + Duration::from_millis(500));
        // 500KB / 0.5s ≈ 1MB/s（允许 EMA 与计时抖动）。
        assert!((speed - 1_000_000.0).abs() < 200_000.0, "speed={speed}");
    }

    // ── 本地服务器端到端：分片拼装 / 续传 / 并发提速 ─────────────────

    use tokio::io::AsyncReadExt;

    /// 测试用静态资源：内容按位置可校验（第 n 字节 = `n % 251`）。
    fn body_of(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i % 251) as u8).collect()
    }

    /// 按限速折算需要 sleep 的毫秒数（除数为 0 视为不限速）。
    fn checked_sleep_ms(sent: u64, bytes_per_sec: u64) -> Option<u64> {
        sent.checked_mul(1000)?.checked_div(bytes_per_sec)
    }

    /// 起一个本地 HTTP 服务：支持 Range，且**每条连接限速** `bytes_per_sec`
    /// （用于复现 CDN 单连接限速，从而量化多连接的收益）。
    ///
    /// 返回下载地址与关闭句柄（句柄 drop 即停）。
    fn spawn_test_server(
        body: Vec<u8>,
        bytes_per_sec: u64,
    ) -> (String, tokio::sync::oneshot::Sender<()>) {
        let listener = DOWNLOAD_RT.block_on(async {
            tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .expect("bind test server")
        });
        let addr = listener.local_addr().expect("local addr");
        let (tx, mut rx) = tokio::sync::oneshot::channel::<()>();
        DOWNLOAD_RT.spawn(async move {
            loop {
                let accept = tokio::select! {
                    _ = &mut rx => return,
                    res = listener.accept() => res,
                };
                let Ok((mut socket, _)) = accept else { continue };
                let body = body.clone();
                tokio::spawn(async move {
                    // 极简 HTTP/1.1 解析：读到空行即请求头结束，再从中找 Range。
                    let mut raw = Vec::new();
                    let mut buf = [0u8; 1024];
                    loop {
                        match socket.read(&mut buf).await {
                            Ok(0) => return,
                            Ok(n) => raw.extend_from_slice(&buf[..n]),
                            Err(_) => return,
                        }
                        if raw.windows(4).any(|w| w == b"\r\n\r\n") {
                            break;
                        }
                    }
                    let head = String::from_utf8_lossy(&raw).to_ascii_lowercase();
                    let range: Option<(usize, usize)> = head.lines().find_map(|line| {
                        let rest = line.trim().strip_prefix("range:")?;
                        let pair = rest.trim().strip_prefix("bytes=")?;
                        let (a, b) = pair.split_once('-')?;
                        let start: usize = a.trim().parse().ok()?;
                        let end: usize = if b.trim().is_empty() {
                            body.len().saturating_sub(1)
                        } else {
                            b.trim().parse().ok()?
                        };
                        Some((start, end.min(body.len().saturating_sub(1))))
                    });
                    let total_len = body.len();
                    let (start, end) = range.unwrap_or((0, total_len.saturating_sub(1)));
                    let slice = &body[start..=end.min(total_len.saturating_sub(1))];
                    let status = if range.is_some() { "206" } else { "200" };
                    let mut head_out = format!(
                        "HTTP/1.1 {status} Partial Content\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\n",
                        slice.len()
                    );
                    if range.is_some() {
                        head_out.push_str(&format!(
                            "Content-Range: bytes {start}-{end}/{total_len}\r\n"
                        ));
                    }
                    head_out.push_str("Connection: close\r\n\r\n");
                    let _ = socket.write_all(head_out.as_bytes()).await;
                    // 按限速分块发送：每块 ≤16KiB，块间补足应耗时间。
                    for part in slice.chunks(16 * 1024) {
                        let _ = socket.write_all(part).await;
                        if let Some(ms) = checked_sleep_ms(part.len() as u64, bytes_per_sec)
                            && ms > 0
                        {
                            tokio::time::sleep(Duration::from_millis(ms)).await;
                        }
                    }
                    let _ = socket.flush().await;
                });
            }
        });
        (format!("http://127.0.0.1:{}/v.mp4", addr.port()), tx)
    }

    /// 测试任务记录：顺带把下载根指到临时目录（与真实逻辑同一套路径规则）。
    fn test_record(id: &str, url: &str) -> DlRecord {
        let root = std::env::temp_dir().join(format!("drama-dl-core-{id}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        crate::device::set_download_dir(root);
        DlRecord {
            id: id.to_owned(),
            series_id: "900001".to_owned(),
            title: "本地测试剧".to_owned(),
            cover: String::new(),
            episode: 1,
            vid: "700001".to_owned(),
            quality: 360,
            url: url.to_owned(),
            referer: crate::app_api::WEB_REFERER.to_owned(),
            key_hex: String::new(),
            total: 0,
            done: 0,
            state: DlState::Downloading,
            error: String::new(),
        }
    }

    fn cleanup(record: &DlRecord) {
        if let Ok(dir) = task_dir(&record.series_id, &record.vid) {
            let _ = std::fs::remove_dir_all(dir);
        }
        crate::device::set_download_dir(std::path::PathBuf::new());
    }

    /// 分片下载的核心正确性：**字节必须与源逐字节一致**。
    #[test]
    fn multi_segment_download_assembles_exact_bytes() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let body = body_of(2 * 1024 * 1024); // 2 MiB
        let (url, _stop) = spawn_test_server(body.clone(), 4 * 1024 * 1024);
        let record = test_record("multi", &url);
        let (total, done) = DOWNLOAD_RT
            .block_on(download_to_file(&record, &CancellationToken::new(), 3))
            .expect("multi download failed");
        assert_eq!(total, body.len() as u64);
        assert_eq!(done, body.len() as u64);
        let written = std::fs::read(part_path(&record).unwrap()).unwrap();
        assert_eq!(written.len(), body.len(), "assembled size mismatch");
        assert_eq!(written, body, "assembled bytes differ from source");
        cleanup(&record);
    }

    /// 性能证据：在**每连接限速**的服务 break 上，3 连接应显著快于 1 连接。
    ///
    /// 这复现了 CDN 的常见形态（单 TCP 连接带宽受限、多连接可叠加），
    /// 单进程本机测得的是调度与串行等待的差距，不是绝对吞吐。
    #[test]
    fn parallel_connections_beats_single_connection_under_per_connection_cap() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let body = body_of(2 * 1024 * 1024); // 2 MiB
        let rate = 512 * 1024; // 每连接 512 KiB/s → 单连接理论 4s
        let (url, _stop) = spawn_test_server(body.clone(), rate);

        let single = test_record("perf-single", &url);
        let t0 = Instant::now();
        let single_out =
            DOWNLOAD_RT.block_on(download_to_file(&single, &CancellationToken::new(), 1));
        let single_ms = t0.elapsed().as_millis() as u64;
        assert!(single_out.is_ok(), "single pass failed");
        let written = std::fs::read(part_path(&single).unwrap()).unwrap();
        assert_eq!(written, body, "single connection bytes differ");
        cleanup(&single);

        let multi = test_record("perf-multi", &url);
        let t1 = Instant::now();
        let multi_out =
            DOWNLOAD_RT.block_on(download_to_file(&multi, &CancellationToken::new(), 3));
        let multi_ms = t1.elapsed().as_millis() as u64;
        assert!(multi_out.is_ok(), "multi pass failed");
        let written = std::fs::read(part_path(&multi).unwrap()).unwrap();
        assert_eq!(written, body, "multi connection bytes differ");
        cleanup(&multi);

        eprintln!("2MiB @512KiB/s per connection: single={single_ms}ms 3-conn={multi_ms}ms");
        assert!(
            multi_ms * 100 < single_ms * 70,
            "3-conn={multi_ms}ms should be far faster than single={single_ms}ms"
        );
    }

    /// 断点续传：中途取消后从 sidecar 续跑，最终文件仍与源逐字节一致。
    #[test]
    fn resume_after_cancel_produces_complete_file() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let body = body_of(2 * 1024 * 1024);
        let (url, _stop) = spawn_test_server(body.clone(), 1024 * 1024);
        let record = test_record("resume", &url);
        let cancel = CancellationToken::new();

        let canceller = cancel.clone();
        DOWNLOAD_RT.spawn(async move {
            tokio::time::sleep(Duration::from_millis(600)).await;
            canceller.cancel();
        });
        let out = DOWNLOAD_RT.block_on(download_to_file(&record, &cancel, 3));
        assert!(out.is_err(), "cancel should abort the first pass");

        let part = part_path(&record).unwrap();
        let partial = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        assert!(partial > 0, "cancel left nothing on disk");
        assert!(partial < body.len() as u64, "first pass already finished");
        // 续传前提：sidecar 已落盘，记录比已下载量的所在段位置。
        assert!(
            progress_path(&record).unwrap().is_file(),
            "checkpoint sidecar missing after cancel"
        );

        let (total, done) = DOWNLOAD_RT
            .block_on(download_to_file(&record, &CancellationToken::new(), 3))
            .expect("resume pass failed");
        assert_eq!(total, body.len() as u64);
        assert_eq!(done, body.len() as u64);
        let written = std::fs::read(&part).unwrap();
        assert_eq!(written, body, "resumed file differs from source");
        cleanup(&record);
    }

    /// 迁移下载目录：文件搬过去、索引在新位置落盘、任务列表不变。
    #[test]
    fn move_downloads_relocates_files_and_rewrites_index() {
        let guard = crate::test_serial::SERIAL
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let base = std::env::temp_dir().join(format!("drama-dl-move-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let old_root = base.join("old");
        let new_root = base.join("new");
        let _ = std::fs::create_dir_all(&old_root);
        crate::device::set_download_dir(old_root.clone());

        // 造一个「已完成假象」的任务目录（含成品文件）+ 让索引里有一条记录。
        let task_dir_path = task_dir("777001", "888001").unwrap();
        let _ = std::fs::create_dir_all(&task_dir_path);
        std::fs::write(task_dir_path.join("video.mp4"), b"cached-episode").unwrap();
        std::fs::write(task_dir_path.join("meta.json"), b"{}").unwrap();
        {
            let mut mgr = MANAGER.lock().expect("download manager poisoned");
            mgr.tasks.insert(
                "777001:1".to_owned(),
                LiveTask {
                    record: DlRecord {
                        id: "777001:1".to_owned(),
                        series_id: "777001".to_owned(),
                        title: "搬家测试剧".to_owned(),
                        cover: String::new(),
                        episode: 1,
                        vid: "888001".to_owned(),
                        quality: 360,
                        url: "https://cdn.example/x.mp4".to_owned(),
                        referer: crate::app_api::WEB_REFERER.to_owned(),
                        key_hex: String::new(),
                        total: 14,
                        done: 14,
                        state: DlState::Completed,
                        error: String::new(),
                    },
                    cancel: CancellationToken::new(),
                    meter: Meter::default(),
                    speed_bps: 0,
                },
            );
            mgr.loaded = true;
            persist_locked(&mgr).unwrap();
        }

        let out = move_downloads(&json!({ "dir": new_root.to_string_lossy() }))
            .expect("moveDownloads failed");
        assert_eq!(out["moved"], json!(1));
        assert_eq!(out["bytes"], json!(14u64 + 2u64)); // video.mp4(14) + meta.json(2)

        // 旧位置不再有该文件，新位置有；索引在新根下落盘且任务仍在。
        assert!(
            !task_dir_path.join("video.mp4").exists(),
            "old file remains"
        );
        let moved_file = new_root.join("777001_888001").join("video.mp4");
        assert!(moved_file.is_file(), "file not present at new root");
        assert_eq!(std::fs::read(&moved_file).unwrap(), b"cached-episode");
        assert!(new_root.join(INDEX_FILE).is_file(), "index not rewritten");
        let tasks = list().unwrap()["tasks"].clone();
        assert_eq!(tasks.as_array().unwrap().len(), 1);
        assert_eq!(tasks[0]["state"], json!("completed"));

        // 再搬回同一路径 → 空操作（不计搬运，也不报错）。
        let again = move_downloads(&json!({ "dir": new_root.to_string_lossy() }))
            .expect("idempotent move failed");
        assert_eq!(again["moved"], json!(0));

        drop(guard);
        MANAGER
            .lock()
            .expect("download manager poisoned")
            .tasks
            .clear();
        MANAGER.lock().expect("download manager poisoned").loaded = false;
        crate::device::set_download_dir(std::path::PathBuf::new());
        let _ = std::fs::remove_dir_all(&base);
    }

    /// 目标目录已有同名任务目录 → 中止搬迁（不覆盖、不丢数据）。
    #[test]
    fn move_downloads_refuses_to_overwrite_existing_target() {
        let guard = crate::test_serial::SERIAL
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let base = std::env::temp_dir().join(format!("drama-dl-move2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let old_root = base.join("old");
        let new_root = base.join("new");
        let _ = std::fs::create_dir_all(old_root.join("900001_910001"));
        let _ = std::fs::create_dir_all(new_root.join("900001_910001"));
        std::fs::write(old_root.join("900001_910001").join("video.mp4"), b"old").unwrap();
        crate::device::set_download_dir(old_root.clone());
        let mut mgr = MANAGER.lock().expect("download manager poisoned");
        mgr.moving = false;
        drop(mgr);

        let err = move_downloads(&json!({ "dir": new_root.to_string_lossy() })).unwrap_err();
        assert!(matches!(err, SourceError::Parse(_)), "unexpected: {err:?}");
        // 源数据必须原样保留。
        assert_eq!(
            std::fs::read(old_root.join("900001_910001").join("video.mp4")).unwrap(),
            b"old"
        );
        drop(guard);
        crate::device::set_download_dir(std::path::PathBuf::new());
        let _ = std::fs::remove_dir_all(&base);
    }

    /// 缺 `dir` / 空白串 → 直接拒绝（不清空现有数据）。
    #[test]
    fn move_downloads_rejects_blank_dir() {
        assert!(move_downloads(&json!({})).is_err());
        assert!(move_downloads(&json!({ "dir": "   " })).is_err());
    }

    /// 记账与磁盘不一致（模拟迁移被打断）→ 整轮重来，而不是按残缺文件继续。
    #[test]
    fn inconsistent_part_file_forces_clean_restart() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let body = body_of(1024 * 1024);
        let (url, _stop) = spawn_test_server(body.clone(), 8 * 1024 * 1024);
        let record = test_record("restart", &url);
        let dir = task_dir(&record.series_id, &record.vid).unwrap();
        let _ = std::fs::create_dir_all(&dir);
        let part = part_path(&record).unwrap();
        // 假的 sidecar：声称三段都写完了，但磁盘上什么都没有。
        let resume = Resume {
            url: url.clone(),
            total: body.len() as u64,
            ranges: true,
            segments: plan_segments(body.len() as u64, true, 3),
        };
        for seg in &resume.segments {
            assert_eq!(seg.done, 0);
        }
        let mut all_done = resume.clone();
        for seg in &mut all_done.segments {
            seg.done = seg.len();
        }
        std::fs::write(
            progress_path(&record).unwrap(),
            serde_json::to_vec(&all_done).unwrap(),
        )
        .unwrap();
        std::fs::write(&part, b"junk").unwrap();

        let (total, done) = DOWNLOAD_RT
            .block_on(download_to_file(&record, &CancellationToken::new(), 3))
            .expect("restart pass failed");
        assert_eq!(total, body.len() as u64);
        assert_eq!(done, body.len() as u64);
        let written = std::fs::read(&part).unwrap();
        assert_eq!(written, body, "restart did not rebuild a clean file");
        cleanup(&record);
    }
}
