//! 播放交付面：本机回环媒体代理、CENC 解密、封面代理。
//!
//! ## 为什么需要本机代理
//!
//! 播放器只打开 `http://127.0.0.1:{port}/play/{token}/video.mp4`，
//! **不直接碰源站**。三件事因此可以集中处理：
//!
//! 1. **Referer 鉴权**——CDN 要求特定 Referer，不能散落到播放器配置；
//! 2. **CENC 解密**——加密流在首读时解析 moov、重写、按样本解密，
//!    播放器拿到的是干净 MP4，不需要任何密钥配置；
//! 3. **封面代理**——封面换成无状态签名地址，重启后仍有效，
//!    且本机其他进程无法借它当开放代理。
//!
//! ## 安全模型
//!
//! 只绑 `127.0.0.1`；每次取流颁发 token（30 分钟过期）；token 即能力，
//! 不做额外鉴权——同一设备上的其他应用理论上可探测端口，
//! 但拿不到 token 就拿不到内容，会话过期即失效。

pub mod covers;
pub mod decrypt;
pub mod gateway;

pub use covers::{proxy_url, rewrite_to_current_port};
pub use gateway::{ensure_port, register, register_file, warm_first_window};

use std::sync::Mutex;

/// 数据目录（`init` op 注入）。
static DATA_DIR: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);

/// 设置数据目录。
pub fn set_data_dir(dir: std::path::PathBuf) {
    let normalized = if dir.as_os_str().is_empty() {
        None
    } else {
        Some(dir)
    };
    *DATA_DIR.lock().expect("gateway data dir poisoned") = normalized;
}

/// 当前数据目录。
pub fn data_dir() -> Option<std::path::PathBuf> {
    DATA_DIR
        .lock()
        .expect("gateway data dir poisoned")
        .clone()
        .filter(|d| !d.as_os_str().is_empty())
}

/// 安装标识：封面签名的密钥。
///
/// 从 `{dataDir}/device.json` 读 `installId`；读不到时用进程内随机值
/// （重启后封面签名失效，表现为封面重新拉一次——可接受降级）。
fn install_id() -> String {
    static CACHED: Mutex<Option<String>> = Mutex::new(None);
    if let Some(id) = CACHED.lock().expect("install id poisoned").clone() {
        return id;
    }
    let loaded = data_dir()
        .map(|d| d.join("device.json"))
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|v| {
            v.get("installId")
                .and_then(|x| x.as_str())
                .map(str::to_owned)
        })
        .unwrap_or_else(|| {
            format!("{:016x}", std::process::id() as u64)
        });
    *CACHED.lock().expect("install id poisoned") = Some(loaded.clone());
    loaded
}
