//! 进程间文件锁。
//!
//! 原实现**没有任何文件锁**，靠「只有一个写者」的隐含假设。Rust 侧要防两件事：
//!
//! 1. 同一进程内多个 worker 同时写同一文件 —— 用 `Mutex`（各模块内部持有）；
//! 2. 多进程同时写（桌面端开两个窗口、CLI 与 GUI 同时跑）—— 用本模块。
//!
//! 锁是**非阻塞**的：拿不到就立刻返回，让调用方提示「另一个实例正在使用」，
//! 而不是把 UI 挂住等锁。

use std::fs::File;
use std::path::{Path, PathBuf};

use fs2::FileExt;

/// 独占文件锁。
///
/// `Drop` 时释放并删除锁文件。锁文件本身不含数据——它的**存在**与**被占用**
/// 才是信号，所以删掉是安全的。
#[derive(Debug)]
pub struct FileLock {
    path: PathBuf,
    file: Option<File>,
}

impl FileLock {
    /// 尝试获取独占锁（非阻塞）。
    ///
    /// 返回 `Ok(None)` 表示锁被别的进程持有。
    pub fn try_acquire(path: &Path) -> std::io::Result<Option<FileLock>> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        match file.try_lock_exclusive() {
            Ok(()) => Ok(Some(FileLock {
                path: path.to_path_buf(),
                file: Some(file),
            })),
            Err(_) => Ok(None),
        }
    }

    /// 阻塞获取（用于 CLI 等可以等的场景）。
    pub fn acquire(path: &Path) -> std::io::Result<FileLock> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        file.lock_exclusive()?;
        Ok(FileLock {
            path: path.to_path_buf(),
            file: Some(file),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        if let Some(file) = self.file.take() {
            let _ = fs2::FileExt::unlock(&file);
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    #[test]
    fn acquires_and_releases() {
        let dir = TempDir::new("lock");
        let path = dir.path().join("app.lock");
        let lock = FileLock::try_acquire(&path).expect("acquire").expect("free");
        assert_eq!(lock.path(), path);
        drop(lock);
        assert!(FileLock::try_acquire(&path).expect("acquire").is_some());
    }

    #[test]
    fn second_acquire_blocks() {
        let dir = TempDir::new("lock-twice");
        let path = dir.path().join("app.lock");
        let _first = FileLock::try_acquire(&path).expect("acquire").expect("free");
        // 同一进程内，flock 对**不同 fd** 仍然互斥。
        let second = FileLock::try_acquire(&path).expect("acquire");
        assert!(second.is_none(), "expected lock contention");
    }

    #[test]
    fn creates_parent_directory() {
        let dir = TempDir::new("lock-nested");
        let path = dir.path().join("a/b/app.lock");
        assert!(FileLock::try_acquire(&path).expect("acquire").is_some());
        assert!(dir.path().join("a/b").is_dir());
    }
}
