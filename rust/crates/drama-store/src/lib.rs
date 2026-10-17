//! 持久化层：目录缓存、追剧、观看进度、搜索历史、设置、用户权限。
//!
//! ## 落盘纪律（比原实现严格）
//!
//! 原实现的原子写是「写临时文件 → rename」，**没有 fsync**，也没有目录 fsync。
//! 掉电后 rename 可能尚未落盘，结果是「文件消失了」——比「文件是旧内容」更糟。
//! 本模块的 [`atomic::write_atomic`] 做完整的三段 fsync：
//!
//! 1. 写临时文件 → `fsync(file)`：保证内容落盘；
//! 2. `rename` 到目标名；
//! 3. `fsync(dir)`：保证目录项落盘。
//!
//! 另外原实现**没有任何文件锁**，靠「只有一个写者」的隐含假设。本模块用
//! 进程内 `Mutex` 序列化写入，并额外提供 [`lockfile`] 供多进程场景使用。
//!
//! ## 为什么全是 JSON 文件而不是 SQLite
//!
//! 这些数据的总量很小（目录缓存 ≤ 32 MiB、追剧 ≤ 数万条），且需要**人可读、
//! 可导出、可手工修复**——用户丢了追剧列表是很严重的体验事故。JSON + 原子写
//! 在这个量级上足够快（全量重写一次 32 MiB 约 30 ms，且写入是防抖的），
//! 而 SQLite 会引入一个无法手工编辑的不透明文件。

pub mod atomic;
pub mod cache;
pub mod library;
pub mod lockfile;
pub mod paths;
pub mod settings;
pub mod users;

pub use atomic::{read_json, write_atomic, write_json_atomic};
pub use cache::{CatalogCache, CacheStats, CachedValue};
pub use library::{Follow, HistoryItem, Library};
pub use paths::DataDirs;
pub use settings::{PlaybackPrefs, ResourceSettings};
pub use users::{Profile, UserStore};

use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

/// 全局数据目录。
static DIRS: OnceLock<Mutex<Option<DataDirs>>> = OnceLock::new();

fn dirs_slot() -> &'static Mutex<Option<DataDirs>> {
    DIRS.get_or_init(|| Mutex::new(None))
}

/// 设置数据目录（`init` op 调用）。
///
/// 重复调用以最后一次为准，并**复位所有依赖该目录的内存表**——
/// 否则旧目录的数据会在新目录下继续被服务（原实现踩过这个坑）。
pub fn set_data_dirs(dirs: DataDirs) {
    let normalized = if dirs.data_dir.as_os_str().is_empty() {
        None
    } else {
        Some(dirs)
    };
    *dirs_slot().lock().expect("data dirs poisoned") = normalized;
    cache::reset_for_data_dir();
    library::reset_for_data_dir();
    users::reset_for_data_dir();
}

/// 清除数据目录（回到纯内存模式）；供测试与生命周期收尾使用。
pub fn clear_data_dirs() {
    *dirs_slot().lock().expect("data dirs poisoned") = None;
    cache::reset_for_data_dir();
    library::reset_for_data_dir();
    users::reset_for_data_dir();
}

/// 当前数据目录（未初始化时 `None`，调用方退化为内存模式）。
pub fn data_dirs() -> Option<DataDirs> {
    dirs_slot()
        .lock()
        .expect("data dirs poisoned")
        .clone()
        .filter(|d| !d.data_dir.as_os_str().is_empty())
}

/// 数据目录下的某个文件路径；未初始化时返回 `None`。
pub fn file_in_data_dir(name: &str) -> Option<PathBuf> {
    data_dirs().map(|d| d.data_dir.join(name))
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    /// 测试用临时目录（进程内唯一，Drop 时清理）。
    pub struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        pub fn new(tag: &str) -> Self {
            use std::sync::atomic::{AtomicU64, Ordering};
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let pid = std::process::id();
            let path = std::env::temp_dir().join(format!("drama-store-{tag}-{pid}-{n}"));
            std::fs::create_dir_all(&path).expect("create temp dir");
            TempDir { path }
        }

        pub fn path(&self) -> &std::path::Path {
            &self.path
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    /// 串行锁：多个测试共享进程级全局数据目录，必须串行。
    #[allow(dead_code)]
    pub fn serial() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }
}
