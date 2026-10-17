//! 设置：网络/并发/播放偏好。
//!
//! **校验一律拒绝，不夹取**。设置页的越界输入是用户错误，应该看到明确提示，
//! 而不是被悄悄改成边界值——后者会让用户以为「我设成 10 并发生效了」。

use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::atomic::{read_json, write_json_atomic};

const MAX_FILE_BYTES: usize = 64 * 1024;
const SNAPSHOT_VERSION: u32 = 1;

/// 网络与并发设置。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceSettings {
    /// `auto` / `direct` / `manual`。
    #[serde(default = "default_proxy_mode")]
    pub proxy_mode: String,
    #[serde(default)]
    pub proxy_url: String,
    /// 目录并发（1..=6）。
    #[serde(default = "default_concurrency")]
    pub catalog_concurrency: u8,
    /// 同源请求最小间隔（0..=5000 ms）。
    #[serde(default = "default_interval")]
    pub catalog_interval_ms: u32,
    /// 下载并行任务数（1..=6）。
    #[serde(default = "default_download_concurrency")]
    pub download_concurrency: u8,
    /// 下载按源分目录。
    #[serde(default)]
    pub download_by_source: bool,
    /// 上次保存的告警（只读，不参与校验）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub warning: String,
}

fn default_proxy_mode() -> String {
    "auto".to_owned()
}
fn default_concurrency() -> u8 {
    3
}
fn default_interval() -> u32 {
    250
}
fn default_download_concurrency() -> u8 {
    2
}

impl Default for ResourceSettings {
    fn default() -> Self {
        ResourceSettings {
            proxy_mode: default_proxy_mode(),
            proxy_url: String::new(),
            catalog_concurrency: default_concurrency(),
            catalog_interval_ms: default_interval(),
            download_concurrency: default_download_concurrency(),
            download_by_source: false,
            warning: String::new(),
        }
    }
}

/// 设置校验错误。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SettingsError(pub String);

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SettingsError {}

impl ResourceSettings {
    /// 校验。
    ///
    /// 错误文案直接面向用户，故写中文并给出具体范围。
    pub fn validate(&self) -> Result<(), SettingsError> {
        if !(1..=6).contains(&self.catalog_concurrency) {
            return Err(SettingsError("目录并发应为 1 至 6".to_owned()));
        }
        if self.catalog_interval_ms > 5000 {
            return Err(SettingsError("请求间隔应为 0 至 5000 毫秒".to_owned()));
        }
        if !(1..=6).contains(&self.download_concurrency) {
            return Err(SettingsError("下载并发应为 1 至 6".to_owned()));
        }
        match self.proxy_mode.as_str() {
            "auto" | "direct" => {}
            "manual" => {
                drama_net_validate_proxy(&self.proxy_url)?;
            }
            _ => return Err(SettingsError("代理模式无效".to_owned())),
        }
        Ok(())
    }

    /// 目录并发对应的限流设置。
    pub fn limiter(&self) -> (usize, std::time::Duration) {
        (
            self.catalog_concurrency as usize,
            std::time::Duration::from_millis(u64::from(self.catalog_interval_ms)),
        )
    }
}

/// 代理地址校验（复用 drama-net 的规则，保持单一真相）。
fn drama_net_validate_proxy(url: &str) -> Result<(), SettingsError> {
    if url.trim().is_empty() {
        return Err(SettingsError("请输入代理地址".to_owned()));
    }
    // 这里只做「形状」校验；真正的 reqwest 构造在 drama-net 侧。
    let Ok(parsed) = url::Url::parse(url.trim()) else {
        return Err(SettingsError(
            "请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址".to_owned(),
        ));
    };
    if !matches!(parsed.scheme(), "http" | "https" | "socks5" | "socks5h") {
        return Err(SettingsError(
            "请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址".to_owned(),
        ));
    }
    if parsed.host_str().is_none_or(str::is_empty) {
        return Err(SettingsError(
            "请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址".to_owned(),
        ));
    }
    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(SettingsError("代理地址不能包含查询参数或片段".to_owned()));
    }
    if !matches!(parsed.path(), "" | "/") {
        return Err(SettingsError("代理地址不能包含路径".to_owned()));
    }
    Ok(())
}

/// 播放偏好。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackPrefs {
    /// 期望清晰度上限（0 = 最高）。
    #[serde(default)]
    pub quality: i64,
    /// 倍速（必须在允许集合内）。
    #[serde(default = "default_speed")]
    pub speed: f64,
    /// 自动连播。
    #[serde(default = "default_true")]
    pub auto_next: bool,
    /// 进入即播。
    #[serde(default = "default_true")]
    pub autoplay: bool,
    /// 弹幕开关。
    #[serde(default = "default_true")]
    pub danmaku: bool,
}

fn default_speed() -> f64 {
    1.0
}
fn default_true() -> bool {
    true
}

/// 允许的倍速集合。
pub const ALLOWED_SPEEDS: [f64; 7] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

impl Default for PlaybackPrefs {
    fn default() -> Self {
        PlaybackPrefs {
            quality: 0,
            speed: 1.0,
            auto_next: true,
            autoplay: true,
            danmaku: true,
        }
    }
}

impl PlaybackPrefs {
    pub fn validate(&self) -> Result<(), SettingsError> {
        if !(0..=4320).contains(&self.quality) {
            return Err(SettingsError("清晰度应为 0 至 4320".to_owned()));
        }
        // 浮点比较用「足够接近」，避免 1.25 的二进制表示误差。
        if !ALLOWED_SPEEDS
            .iter()
            .any(|s| (s - self.speed).abs() < 1e-9)
        {
            return Err(SettingsError(format!(
                "倍速应为 {} 之一",
                ALLOWED_SPEEDS
                    .iter()
                    .map(|s| s.to_string())
                    .collect::<Vec<_>>()
                    .join(" / ")
            )));
        }
        Ok(())
    }
}

/// 落盘快照。
#[derive(Debug, Serialize, Deserialize)]
struct Snapshot {
    version: u32,
    resource: ResourceSettings,
    playback: PlaybackPrefs,
}

/// 设置库。
#[derive(Debug)]
pub struct SettingsStore {
    inner: Mutex<State>,
}

#[derive(Debug)]
struct State {
    resource: ResourceSettings,
    playback: PlaybackPrefs,
    path: Option<std::path::PathBuf>,
}

static STORE: once_cell::sync::Lazy<SettingsStore> = once_cell::sync::Lazy::new(|| SettingsStore {
    inner: Mutex::new(State {
        resource: ResourceSettings::default(),
        playback: PlaybackPrefs::default(),
        path: None,
    }),
});

/// 全局设置。
pub fn global() -> &'static SettingsStore {
    &STORE
}

impl SettingsStore {
    /// 绑定落盘路径并加载。
    ///
    /// 文件损坏时**用默认值启动但保留原文件**——不能因为设置读不出来就让
    /// 应用打不开，也不能覆盖用户可能还想抢救的配置。
    pub fn attach(&self, path: std::path::PathBuf) {
        let loaded = read_json::<Snapshot>(&path).ok().flatten();
        let mut state = self.inner.lock().expect("settings poisoned");
        state.path = Some(path);
        if let Some(snapshot) = loaded
            && snapshot.version == SNAPSHOT_VERSION
        {
            // 加载时也校验：旧版本写入的非法值不该直接生效。
            if snapshot.resource.validate().is_ok() {
                state.resource = snapshot.resource;
            }
            if snapshot.playback.validate().is_ok() {
                state.playback = snapshot.playback;
            }
        }
    }

    pub fn resource(&self) -> ResourceSettings {
        self.inner.lock().expect("settings poisoned").resource.clone()
    }

    pub fn playback(&self) -> PlaybackPrefs {
        self.inner.lock().expect("settings poisoned").playback.clone()
    }

    /// 保存网络设置。
    pub fn save_resource(&self, settings: ResourceSettings) -> Result<(), SettingsError> {
        settings.validate()?;
        {
            let mut state = self.inner.lock().expect("settings poisoned");
            state.resource = settings;
        }
        self.persist().map_err(SettingsError)
    }

    /// 保存播放偏好。
    pub fn save_playback(&self, prefs: PlaybackPrefs) -> Result<(), SettingsError> {
        prefs.validate()?;
        {
            let mut state = self.inner.lock().expect("settings poisoned");
            state.playback = prefs;
        }
        self.persist().map_err(SettingsError)
    }

    fn persist(&self) -> Result<(), String> {
        let (path, snapshot) = {
            let state = self.inner.lock().expect("settings poisoned");
            (
                state.path.clone(),
                Snapshot {
                    version: SNAPSHOT_VERSION,
                    resource: state.resource.clone(),
                    playback: state.playback.clone(),
                },
            )
        };
        let Some(path) = path else {
            return Ok(());
        };
        write_json_atomic(&path, &snapshot, Some(MAX_FILE_BYTES)).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    #[test]
    fn defaults_are_valid() {
        assert!(ResourceSettings::default().validate().is_ok());
        assert!(PlaybackPrefs::default().validate().is_ok());
    }

    #[test]
    fn rejects_out_of_range_instead_of_clamping() {
        let mut s = ResourceSettings::default();
        s.catalog_concurrency = 0;
        assert!(s.validate().is_err());
        s.catalog_concurrency = 7;
        assert!(s.validate().is_err());
        s.catalog_concurrency = 3;

        s.catalog_interval_ms = 5001;
        assert!(s.validate().is_err());
        s.catalog_interval_ms = 250;

        s.download_concurrency = 0;
        assert!(s.validate().is_err());
    }

    #[test]
    fn proxy_validation() {
        let mut s = ResourceSettings::default();
        s.proxy_mode = "manual".to_owned();
        s.proxy_url = String::new();
        assert!(s.validate().is_err());

        s.proxy_url = "http://127.0.0.1:7890".to_owned();
        assert!(s.validate().is_ok());

        s.proxy_url = "http://127.0.0.1:7890/path".to_owned();
        assert!(s.validate().is_err());

        // auto/direct 模式下代理地址被忽略。
        s.proxy_mode = "direct".to_owned();
        s.proxy_url = "garbage".to_owned();
        assert!(s.validate().is_ok());
    }

    #[test]
    fn rejects_unknown_proxy_mode() {
        let mut s = ResourceSettings::default();
        s.proxy_mode = "weird".to_owned();
        assert!(s.validate().is_err());
    }

    #[test]
    fn playback_speed_must_be_in_set() {
        let mut p = PlaybackPrefs::default();
        p.speed = 1.25;
        assert!(p.validate().is_ok());
        p.speed = 1.1;
        assert!(p.validate().is_err());
        p.speed = 3.0;
        assert!(p.validate().is_ok());
        p.speed = 4.0;
        assert!(p.validate().is_err());
    }

    #[test]
    fn playback_quality_range() {
        let mut p = PlaybackPrefs::default();
        p.quality = 4320;
        assert!(p.validate().is_ok());
        p.quality = 5000;
        assert!(p.validate().is_err());
        p.quality = -1;
        assert!(p.validate().is_err());
    }

    #[test]
    fn limiter_reflects_settings() {
        let s = ResourceSettings {
            catalog_concurrency: 5,
            catalog_interval_ms: 400,
            ..Default::default()
        };
        let (concurrency, interval) = s.limiter();
        assert_eq!(concurrency, 5);
        assert_eq!(interval, std::time::Duration::from_millis(400));
    }

    #[test]
    fn persists_and_reloads() {
        let dir = TempDir::new("settings");
        let path = dir.path().join("settings.json");

        let store = SettingsStore {
            inner: Mutex::new(State {
                resource: ResourceSettings::default(),
                playback: PlaybackPrefs::default(),
                path: None,
            }),
        };
        store.attach(path.clone());
        let mut resource = ResourceSettings::default();
        resource.catalog_concurrency = 5;
        store.save_resource(resource).expect("save");

        let mut prefs = PlaybackPrefs::default();
        prefs.speed = 1.5;
        store.save_playback(prefs).expect("save");

        let reloaded = SettingsStore {
            inner: Mutex::new(State {
                resource: ResourceSettings::default(),
                playback: PlaybackPrefs::default(),
                path: None,
            }),
        };
        reloaded.attach(path);
        assert_eq!(reloaded.resource().catalog_concurrency, 5);
        assert!((reloaded.playback().speed - 1.5).abs() < 1e-9);
    }

    #[test]
    fn invalid_settings_are_not_saved() {
        let store = SettingsStore {
            inner: Mutex::new(State {
                resource: ResourceSettings::default(),
                playback: PlaybackPrefs::default(),
                path: None,
            }),
        };
        let mut bad = ResourceSettings::default();
        bad.catalog_concurrency = 99;
        assert!(store.save_resource(bad).is_err());
        // 旧值保持不变。
        assert_eq!(store.resource().catalog_concurrency, 3);
    }

    #[test]
    fn corrupt_file_falls_back_to_defaults() {
        let dir = TempDir::new("settings-corrupt");
        let path = dir.path().join("settings.json");
        std::fs::write(&path, b"not json").expect("write");

        let store = SettingsStore {
            inner: Mutex::new(State {
                resource: ResourceSettings::default(),
                playback: PlaybackPrefs::default(),
                path: None,
            }),
        };
        store.attach(path.clone());
        assert_eq!(store.resource().catalog_concurrency, 3);
        // 原文件保留。
        assert!(path.exists());
    }
}
