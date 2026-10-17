//! 原子写与 fsync。
//!
//! 三段式：
//!
//! ```text
//! 1. 写 {target}.tmp-{rand}  →  fsync(file)
//! 2. rename(tmp, target)        （同一目录内，POSIX 保证原子）
//! 3. fsync(dir)                 （保证目录项落盘）
//! ```
//!
//! 第 3 步是原实现缺失的一环。没有它，掉电后可能「文件内容在、名字不在」——
//! 用户看到的是「配置全丢了」，而备份文件（`.tmp`）还躺在那里。
//!
//! ## 失败语义
//!
//! 任何一步失败都**不触碰目标文件**：旧值保持原样。这是「更新失败不能把能用的
//! 数据搞坏」这条原则的落地。

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

/// 写入错误。
#[derive(Debug, thiserror::Error)]
pub enum WriteError {
    #[error("创建目录失败: {0}")]
    CreateDir(String),
    #[error("写入临时文件失败: {0}")]
    Temp(String),
    #[error("fsync 失败: {0}")]
    Sync(String),
    #[error("重命名失败: {0}")]
    Rename(String),
    #[error("序列化失败: {0}")]
    Encode(String),
    #[error("内容超过上限 {limit} 字节（实际 {actual}）")]
    TooLarge { limit: usize, actual: usize },
}

/// 原子写入字节。
///
/// `max_bytes` 为 `Some(n)` 时超限直接拒绝（**不写半截文件**），
/// 让调用方能把「超过保存上限」明确报给用户。
pub fn write_atomic(target: &Path, data: &[u8], max_bytes: Option<usize>) -> Result<(), WriteError> {
    if let Some(limit) = max_bytes
        && data.len() > limit
    {
        return Err(WriteError::TooLarge {
            limit,
            actual: data.len(),
        });
    }
    let parent = target.parent().ok_or_else(|| {
        WriteError::CreateDir(format!("目标路径没有父目录: {}", target.display()))
    })?;
    fs::create_dir_all(parent)
        .map_err(|e| WriteError::CreateDir(format!("{}: {e}", parent.display())))?;

    let temp = temp_path(target);
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|e| WriteError::Temp(format!("{}: {e}", temp.display())))?;
        file.write_all(data)
            .map_err(|e| WriteError::Temp(format!("{}: {e}", temp.display())))?;
        file.sync_all()
            .map_err(|e| WriteError::Sync(format!("{}: {e}", temp.display())))?;
    }

    // rename 前再次确认内容大小（防止并发写者让临时文件膨胀）。
    if let Ok(meta) = fs::metadata(&temp)
        && let Some(limit) = max_bytes
        && meta.len() > limit as u64
    {
        let _ = fs::remove_file(&temp);
        return Err(WriteError::TooLarge {
            limit,
            actual: meta.len() as usize,
        });
    }

    if let Err(e) = fs::rename(&temp, target) {
        let _ = fs::remove_file(&temp);
        return Err(WriteError::Rename(format!("{}: {e}", target.display())));
    }

    // 目录 fsync：保证 rename 本身落盘。
    sync_dir(parent);
    Ok(())
}

/// 原子写入 JSON。
pub fn write_json_atomic<T: Serialize>(
    target: &Path,
    value: &T,
    max_bytes: Option<usize>,
) -> Result<(), WriteError> {
    let bytes = serde_json::to_vec(value).map_err(|e| WriteError::Encode(e.to_string()))?;
    write_atomic(target, &bytes, max_bytes)
}

/// 读 JSON；文件不存在返回 `Ok(None)`，解析失败返回 `Err`。
///
/// **解析失败不能静默当空**：调用方需要区分「首次启动」与「文件损坏」，
/// 后者必须保留原文件并提示用户（原实现有专门的损坏锁定流程）。
pub fn read_json<T: DeserializeOwned>(target: &Path) -> Result<Option<T>, ReadError> {
    let bytes = match fs::read(target) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(ReadError::Io(format!("{}: {e}", target.display()))),
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|e| ReadError::Parse(format!("{}: {e}", target.display())))
}

/// 读取错误。
#[derive(Debug, thiserror::Error)]
pub enum ReadError {
    #[error("读取失败: {0}")]
    Io(String),
    #[error("解析失败: {0}")]
    Parse(String),
}

/// 目录 fsync（失败不报错：某些文件系统不支持目录 fsync，不该因此让写入失败）。
fn sync_dir(dir: &Path) {
    #[cfg(unix)]
    {
        if let Ok(handle) = File::open(dir) {
            let _ = handle.sync_all();
        }
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
    }
}

/// 生成同目录的临时路径。
fn temp_path(target: &Path) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    let name = target
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "data".to_owned());
    target.with_file_name(format!(".{name}.tmp-{pid}-{n}"))
}

/// 清理残留的临时文件（启动时调用；超过 `older_than` 才删）。
pub fn cleanup_temp_files(dir: &Path, older_than: std::time::Duration) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let now = std::time::SystemTime::now();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with('.') || !name.contains(".tmp-") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(modified) = meta.modified() else { continue };
        if now.duration_since(modified).is_ok_and(|age| age > older_than) {
            let _ = fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    #[test]
    fn writes_and_reads_json() {
        let dir = TempDir::new("atomic");
        let target = dir.path().join("x.json");
        write_json_atomic(&target, &serde_json::json!({"a": 1}), None).expect("write");
        let value: serde_json::Value = read_json(&target).expect("read").expect("present");
        assert_eq!(value["a"], 1);
    }

    #[test]
    fn missing_file_is_none_not_error() {
        let dir = TempDir::new("atomic-missing");
        let value: Option<serde_json::Value> =
            read_json(&dir.path().join("nope.json")).expect("read");
        assert!(value.is_none());
    }

    #[test]
    fn corrupt_file_is_an_error_not_empty() {
        let dir = TempDir::new("atomic-corrupt");
        let target = dir.path().join("bad.json");
        fs::write(&target, b"{not json").expect("write");
        let err = read_json::<serde_json::Value>(&target).unwrap_err();
        assert!(matches!(err, ReadError::Parse(_)));
        // 原文件必须保留，供用户/支持人员恢复。
        assert!(target.exists());
    }

    #[test]
    fn oversized_write_leaves_old_value_intact() {
        let dir = TempDir::new("atomic-limit");
        let target = dir.path().join("x.json");
        write_json_atomic(&target, &serde_json::json!({"v": "old"}), None).expect("first");
        let big = vec![b'x'; 100];
        let err = write_atomic(&target, &big, Some(10)).unwrap_err();
        assert!(matches!(err, WriteError::TooLarge { .. }));
        let value: serde_json::Value = read_json(&target).expect("read").expect("present");
        assert_eq!(value["v"], "old");
    }

    #[test]
    fn no_temp_files_left_behind() {
        let dir = TempDir::new("atomic-temp");
        let target = dir.path().join("x.json");
        for i in 0..5 {
            write_json_atomic(&target, &serde_json::json!({"i": i}), None).expect("write");
        }
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .expect("read dir")
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left: {leftovers:?}");
    }

    #[test]
    fn creates_parent_directories() {
        let dir = TempDir::new("atomic-nested");
        let target = dir.path().join("a/b/c/x.json");
        write_json_atomic(&target, &serde_json::json!({"ok": true}), None).expect("write");
        assert!(target.exists());
    }

    #[test]
    fn cleanup_removes_old_temp_files_only() {
        let dir = TempDir::new("atomic-cleanup");
        let stale = dir.path().join(".x.json.tmp-1-2");
        fs::write(&stale, b"junk").expect("write");
        // 用 0 时长让「刚创建」也被判为过期。
        cleanup_temp_files(dir.path(), std::time::Duration::ZERO);
        assert!(!stale.exists());
    }
}
