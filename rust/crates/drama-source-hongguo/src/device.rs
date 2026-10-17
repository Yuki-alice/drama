//! 设备身份：App 接口签名所需的 `device_id` / `install_id`。
//!
//! ## 为什么必须持久化
//!
//! 换设备标识会触发服务端风控变化（可能直接返回空 body）。因此首次生成后
//! 写入 `{dataDir}/device.json`，之后一直复用；`init` 未调用时退化为
//! 进程内随机身份（功能可用，但重启后变化）。

use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::sign::new_device_id;

/// 数据目录（`init` 传入；未初始化时为 `None`）。
static DATA_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);
/// 进程内缓存的身份（避免每次读文件）。
static CACHED: Mutex<Option<Identity>> = Mutex::new(None);

/// 设备身份。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub device_id: String,
    pub install_id: String,
}

/// 设置数据目录（`init` op 调用）。
///
/// 重复调用以最后一次为准并清空内存缓存。
pub fn set_data_dir(dir: PathBuf) {
    let normalized = if dir.as_os_str().is_empty() {
        None
    } else {
        Some(dir)
    };
    *DATA_DIR.lock().expect("data dir poisoned") = normalized;
    *CACHED.lock().expect("identity cache poisoned") = None;
}

/// 当前数据目录。
pub fn data_dir() -> Option<PathBuf> {
    DATA_DIR
        .lock()
        .expect("data dir poisoned")
        .clone()
        .filter(|d| !d.as_os_str().is_empty())
}

/// 取设备身份（首次生成并持久化）。
///
/// 持久化失败时**不报错**：退化为进程内身份仍能让功能跑起来，
/// 只是重启后会变化。这里宁可降级也不让整个源不可用。
pub fn identity() -> Identity {
    {
        let guard = CACHED.lock().expect("identity cache poisoned");
        if let Some(cached) = guard.as_ref() {
            return cached.clone();
        }
    }

    let loaded = data_dir()
        .map(|dir| dir.join("device.json"))
        .and_then(|path| load_identity(&path))
        .unwrap_or_else(generate_identity);

    if let Some(dir) = data_dir() {
        let path = dir.join("device.json");
        // 已有文件时不重写（避免无谓的磁盘写入）。
        if !path.exists() {
            let _ = save_identity(&path, &loaded);
        }
    }

    *CACHED.lock().expect("identity cache poisoned") = Some(loaded.clone());
    loaded
}

fn generate_identity() -> Identity {
    let mut buf = [0u8; 16];
    // 随机源不可用时用时间戳兜底（仍是 19 位数字，能通过 `is_numeric_id`）。
    if fill_random(&mut buf).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        buf[..8].copy_from_slice(&nanos.to_be_bytes());
        buf[8..].copy_from_slice(&nanos.wrapping_mul(6364136223846793005).to_be_bytes());
    }
    let device = u64::from_be_bytes(buf[..8].try_into().expect("8 bytes"));
    let install = u64::from_be_bytes(buf[8..].try_into().expect("8 bytes"));
    Identity {
        device_id: new_device_id(device),
        install_id: new_device_id(install),
    }
}

fn load_identity(path: &std::path::Path) -> Option<Identity> {
    let bytes = std::fs::read(path).ok()?;
    let identity: Identity = serde_json::from_slice(&bytes).ok()?;
    // 形状不对就当作没有：宁可重新生成，也不要拿一个非法 id 去签名。
    if crate::is_numeric_id(&identity.device_id) && crate::is_numeric_id(&identity.install_id) {
        Some(identity)
    } else {
        None
    }
}

fn save_identity(path: &std::path::Path, identity: &Identity) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let bytes = serde_json::to_vec_pretty(identity).map_err(|e| e.to_string())?;
    std::fs::write(path, bytes).map_err(|e| e.to_string())
}

/// 填充随机字节。
///
/// 优先系统 CSPRNG；失败时返回错误让调用方决定降级策略
/// （签名 nonce 失败必须报错，设备 id 可以退化为时间戳）。
pub fn fill_random(buf: &mut [u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::io::Read;
        let mut file =
            std::fs::File::open("/dev/urandom").map_err(|e| format!("无法读取随机源: {e}"))?;
        file.read_exact(buf)
            .map_err(|e| format!("无法读取随机源: {e}"))?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        // 非 Unix 平台：用系统时间 + 进程地址派生（足够区分设备，非密码学强度）。
        use std::collections::hash_map::RandomState;
        use std::hash::{BuildHasher, Hasher};
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        );
        let mut state = hasher.finish();
        for byte in buf.iter_mut() {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            *byte = (state >> 33) as u8;
        }
        Ok(())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    /// 这些测试共享进程级全局，必须串行。
    static SERIAL: StdMutex<()> = StdMutex::new(());

    #[test]
    fn identity_is_persisted_and_stable() {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("drama-device-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create");

        set_data_dir(dir.clone());
        let first = identity();
        assert!(crate::is_numeric_id(&first.device_id));
        assert!(crate::is_numeric_id(&first.install_id));

        // 清缓存后重新读取，应当拿到同一个身份。
        set_data_dir(dir.clone());
        let second = identity();
        assert_eq!(first, second);

        let _ = std::fs::remove_dir_all(&dir);
        set_data_dir(PathBuf::new());
    }

    #[test]
    fn missing_file_generates_identity() {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("drama-device-new-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create");

        set_data_dir(dir.clone());
        let id = identity();
        assert!(crate::is_numeric_id(&id.device_id));
        // 生成后应当落盘。
        assert!(dir.join("device.json").exists());

        let _ = std::fs::remove_dir_all(&dir);
        set_data_dir(PathBuf::new());
    }

    #[test]
    fn invalid_stored_identity_is_regenerated() {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("drama-device-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create");
        std::fs::write(
            dir.join("device.json"),
            br#"{"deviceId":"not-a-number","installId":"123"}"#,
        )
        .expect("write");

        set_data_dir(dir.clone());
        let id = identity();
        // 重新生成了合法身份。
        assert!(crate::is_numeric_id(&id.device_id));

        let _ = std::fs::remove_dir_all(&dir);
        set_data_dir(PathBuf::new());
    }

    #[test]
    fn no_data_dir_still_works() {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        set_data_dir(PathBuf::new());
        let id = identity();
        assert!(crate::is_numeric_id(&id.device_id));
    }

    #[test]
    fn fill_random_changes_output() {
        let mut a = [0u8; 16];
        let mut b = [0u8; 16];
        fill_random(&mut a).expect("random");
        fill_random(&mut b).expect("random");
        assert_ne!(a, b, "two random fills should differ");
    }
}
