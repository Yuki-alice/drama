//! 下载子系统：任务调度、分段续传、索引持久化、本地播放计划。
//!
//! ## 与原实现的关键差异
//!
//! 原实现的下载器在 Go 核心内，产物是「源站原始字节」+ 密钥 hex；
//! 本实现保留同样的产物语义（播放器自己解密），但：
//!
//! - **索引全有或全无**：任一条记录的校验失败即整份拒绝，且**绝不覆盖**
//!   原文件——用户丢下载记录比丢一次下载更难受；
//! - **先落盘再起 worker**：重启后看到的是「已暂停」而不是「消失」；
//! - **续传需要强验证器**：弱 ETag（`W/`）不算，否则会把两个文件拼在一起。
//!
//! ## 为什么不做 HLS 合并
//!
//! 合并需要 ffmpeg（体积 + 平台差异）。产物保留 `index.m3u8` + 分片，
//! 由播放器直接播；导出时再交给 ffmpeg。这保持了「下载器只负责取字节」。

pub mod engine;

use std::sync::Mutex;

/// 下载目录覆盖（`init` op 的 `downloadDir`）。
static DOWNLOAD_DIR: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);

/// 设置下载目录。
pub fn set_download_dir(dir: std::path::PathBuf) {
    let normalized = if dir.as_os_str().is_empty() {
        None
    } else {
        Some(dir)
    };
    *DOWNLOAD_DIR.lock().expect("download dir poisoned") = normalized;
}

/// 当前下载目录：显式设置优先，否则数据目录下 `downloads`。
pub fn download_dir() -> Option<std::path::PathBuf> {
    if let Some(dir) = DOWNLOAD_DIR
        .lock()
        .expect("download dir poisoned")
        .clone()
    {
        return Some(dir);
    }
    drama_store::data_dirs().map(|d| d.download_dir)
}

pub use engine::{
    DlRecord, DlState, cancel, delete, list, move_downloads, pause, play_file, play_local, retry,
    set_concurrency, start,
};
