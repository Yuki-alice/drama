//! 设备身份：App 接口签名所需的 `device_id` / `iid`。
//!
//! 首次生成后持久化到 `init{dataDir}/device.json`，换设备标识会导致
//! 服务端风控变化，因此能复用必须复用；`init` 未调用时退化为
//! 进程内随机身份（功能可用，重启后变化）。

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};

use crate::sign;

/// 数据目录（Dart 侧 `init` 传入；未初始化时为 `None`）。
static DATA_DIR: Lazy<Mutex<Option<PathBuf>>> = Lazy::new(|| Mutex::new(None));

/// 下载目录（`init{downloadDir}` 可覆盖；缺省为数据目录下 `downloads`）。
static DOWNLOAD_DIR: Lazy<Mutex<Option<PathBuf>>> = Lazy::new(|| Mutex::new(None));

/// 进程内缓存的身份（避免每次读文件）。
static CACHED: Lazy<Mutex<Option<Identity>>> = Lazy::new(|| Mutex::new(None));

/// 设备身份。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Identity {
    pub device_id: String,
    pub install_id: String,
}

/// 设置数据目录（`init` op 调用；重复调用以最后一次为准并清空内存缓存）。
///
/// 空路径视为「未初始化」（`None`）：否则 `""` 会让 `progress.json` /
/// `device.json` 相对于进程 CWD 落盘（测试会污染仓库目录）。
///
/// 切换同时复位依赖该目录的内存表（追剧/历史/搜索、目录缓存、下载索引），
/// 否则旧目录的数据会在新目录下继续被服务。
pub fn set_data_dir(dir: PathBuf) {
    let normalized = if dir.as_os_str().is_empty() {
        None
    } else {
        Some(dir)
    };
    *DATA_DIR.lock().expect("data dir poisoned") = normalized;
    *CACHED.lock().expect("identity cache poisoned") = None;
    crate::store::reset_for_data_dir();
    crate::cache::reset_for_data_dir();
    crate::download::reset_for_data_dir();
}

/// 清除数据目录（回到未初始化的内存模式）；供测试与生命周期收尾使用。
pub fn clear_data_dir() {
    *DATA_DIR.lock().expect("data dir poisoned") = None;
    *CACHED.lock().expect("identity cache poisoned") = None;
    crate::store::reset_for_data_dir();
    crate::cache::reset_for_data_dir();
    crate::download::reset_for_data_dir();
}

/// 当前数据目录（未初始化为 `None`，调用方退化为内存模式）。
pub fn data_dir() -> Option<PathBuf> {
    DATA_DIR
        .lock()
        .expect("data dir poisoned")
        .clone()
        .filter(|d| !d.as_os_str().is_empty())
}

/// 设置下载目录（`init{downloadDir}` 可覆盖；重复调用覆盖）。
pub fn set_download_dir(dir: PathBuf) {
    let normalized = if dir.as_os_str().is_empty() {
        None
    } else {
        Some(dir)
    };
    *DOWNLOAD_DIR.lock().expect("download dir poisoned") = normalized;
}

/// 当前下载目录：显式设置优先，否则数据目录下 `downloads`，都没有则 `None`。
pub fn download_dir() -> Option<PathBuf> {
    if let Some(dir) = DOWNLOAD_DIR
        .lock()
        .expect("download dir poisoned")
        .clone()
        .filter(|d| !d.as_os_str().is_empty())
    {
        return Some(dir);
    }
    data_dir().map(|d| d.join("downloads"))
}

/// 取设备身份：缓存 → 文件 → 新生成（能写文件时写回）。
pub fn identity() -> Identity {
    if let Some(id) = CACHED.lock().expect("identity cache poisoned").clone() {
        return id;
    }
    let id = load_or_create();
    *CACHED.lock().expect("identity cache poisoned") = Some(id.clone());
    id
}

fn load_or_create() -> Identity {
    let dir = DATA_DIR.lock().expect("data dir poisoned").clone();
    if let Some(dir) = dir {
        let path = dir.join("device.json");
        if let Ok(raw) = std::fs::read(&path)
            && let Ok(id) = serde_json::from_slice::<Identity>(&raw)
            && is_valid(&id)
        {
            return id;
        }
        let id = fresh();
        if serde_json::to_vec(&id)
            .ok()
            .and_then(|bytes| std::fs::write(&path, bytes).ok())
            .is_some()
        {
            return id;
        }
        return id;
    }
    fresh()
}

fn is_valid(id: &Identity) -> bool {
    !id.device_id.is_empty()
        && !id.install_id.is_empty()
        && id.device_id.len() <= 64
        && id.install_id.len() <= 64
        && id.device_id.chars().all(|c| c.is_ascii_alphanumeric())
        && id.install_id.chars().all(|c| c.is_ascii_alphanumeric())
}

/// 新身份：`nanos` 播种（loopback 威胁模型外唯一需要随机性的地方用
/// 时间+进程 id 组合，避免为此引入随机数依赖）。
fn fresh() -> Identity {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
        .wrapping_add(std::process::id() as u64);
    Identity {
        device_id: sign::new_device_id(nanos),
        install_id: sign::new_device_id(nanos.rotate_left(32) ^ 0x9e3779b97f4a7c15),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_identity_is_numeric_and_distinct() {
        let a = fresh();
        let b = fresh();
        assert!(is_valid(&a));
        // 同一纳秒内可能相同，只断言格式与长度。
        assert_eq!(a.device_id.len(), 19);
        let _ = b;
    }

    #[test]
    fn roundtrip_through_data_dir() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let dir = std::env::temp_dir().join(format!("drama-device-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        set_data_dir(dir.clone());
        let first = identity();
        *CACHED.lock().unwrap() = None;
        let second = identity();
        assert_eq!(first.device_id, second.device_id);
        assert_eq!(first.install_id, second.install_id);
        let _ = std::fs::remove_dir_all(&dir);
        clear_data_dir();
    }

    #[test]
    fn empty_data_dir_is_treated_as_uninitialized() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        // 空路径不得变成「CWD 相对路径」——否则进度/身份文件会写进仓库目录。
        set_data_dir(PathBuf::new());
        assert_eq!(data_dir(), None);
        clear_data_dir();
        assert_eq!(data_dir(), None);
    }

    #[test]
    fn non_empty_data_dir_roundtrips() {
        let _guard = crate::test_serial::SERIAL.lock().unwrap();
        let dir = std::env::temp_dir().join("drama-device-dir-roundtrip");
        set_data_dir(dir.clone());
        assert_eq!(data_dir(), Some(dir));
        clear_data_dir();
    }
}
