//! 已安装源的管理：安装、卸载、启停、更新检查。
//!
//! ## 目录布局
//!
//! ```text
//! {dataDir}/sources/
//!   ├── index.json              ← 已安装清单（版本、哈希、来源、启停）
//!   └── {id}.json               ← 每个源的规范化 JSON
//! ```
//!
//! ## 失败语义
//!
//! 安装是**先校验后落盘**：新包校验失败时，已安装的同 id 源保持原样。
//! 卸载是先删清单条目再删文件——中断后最多留下一个孤儿文件（无害），
//! 不会出现「清单说有、文件没有」。

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use drama_types::SourceId;

use crate::manifest::Manifest;
use crate::validate;

/// 安装错误。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum InstallError {
    #[error("读取规则包失败: {0}")]
    Read(String),
    #[error("解析规则包失败: {0}")]
    Parse(String),
    #[error("规则包校验失败: {0}")]
    Invalid(String),
    #[error("源 {0} 已安装（版本 {1}），如需覆盖请用 update")]
    AlreadyInstalled(String, String),
    #[error("源 {0} 未安装")]
    NotInstalled(String),
    #[error("内置源 {0} 不可卸载")]
    Builtin(String),
    #[error("落盘失败: {0}")]
    Persist(String),
}

/// 安装记录。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InstalledSource {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    /// 内容哈希（sha256 前 32 hex）。
    pub content_hash: String,
    /// 安装时间（Unix 毫秒）。
    pub installed_at_ms: i64,
    /// 是否启用（默认安装后启用）。
    pub enabled: bool,
    /// 来源（官方仓库 URL 或 `local`）。
    pub origin: String,
}

/// 索引快照。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndexSnapshot {
    version: u32,
    sources: BTreeMap<String, InstalledSource>,
}

/// 索引版本常量。
const INDEX_VERSION: u32 = 1;

/// 源仓库。
#[derive(Debug)]
pub struct SourceStore {
    inner: Mutex<State>,
}

#[derive(Debug, Default)]
struct State {
    sources: BTreeMap<String, InstalledSource>,
    dir: Option<PathBuf>,
}

static STORE: once_cell::sync::Lazy<SourceStore> =
    once_cell::sync::Lazy::new(|| SourceStore {
        inner: Mutex::new(State::default()),
    });

/// 全局源仓库。
pub fn global() -> &'static SourceStore {
    &STORE
}

/// [`global`] 的 crate 级别名（供其他 crate 以 `drama_rules::store::global_store()` 引用）。
pub use global as global_store;

impl SourceStore {
    /// 全局实例。
    pub fn shared() -> &'static SourceStore {
        &STORE
    }
}

impl SourceStore {
    /// 绑定落盘目录并加载。
    pub fn attach(&self, dir: PathBuf) {
        let index_path = dir.join("index.json");
        let mut state = self.inner.lock().expect("source store poisoned");
        state.dir = Some(dir);
        // 损坏/版本不符：按空仓库启动，但**不覆盖原文件**（供用户恢复）。
        if let Ok(bytes) = std::fs::read(&index_path)
            && let Ok(snapshot) = serde_json::from_slice::<IndexSnapshot>(&bytes)
            && snapshot.version == INDEX_VERSION
        {
            state.sources = snapshot.sources;
        }
    }

    /// 复位（数据目录切换）。
    pub fn reset(&self) {
        let mut state = self.inner.lock().expect("source store poisoned");
        *state = State::default();
    }

    fn persist(&self, state: &State) -> Result<(), InstallError> {
        let Some(dir) = state.dir.clone() else {
            return Ok(());
        };
        let snapshot = IndexSnapshot {
            version: INDEX_VERSION,
            sources: state.sources.clone(),
        };
        let bytes = serde_json::to_vec_pretty(&snapshot)
            .map_err(|e| InstallError::Persist(e.to_string()))?;
        drama_store::write_atomic(&dir.join("index.json"), &bytes, Some(1024 * 1024))
            .map_err(|e| InstallError::Persist(e.to_string()))
    }

    /// 已安装列表。
    pub fn list(&self) -> Vec<InstalledSource> {
        self.inner
            .lock()
            .expect("source store poisoned")
            .sources
            .values()
            .cloned()
            .collect()
    }

    /// 查询单个源。
    pub fn get(&self, id: &str) -> Option<InstalledSource> {
        self.inner
            .lock()
            .expect("source store poisoned")
            .sources
            .get(id)
            .cloned()
    }

    /// 读取已安装源的清单。
    pub fn manifest(&self, id: &str) -> Result<Manifest, InstallError> {
        let dir = self
            .inner
            .lock()
            .expect("source store poisoned")
            .dir
            .clone()
            .ok_or_else(|| InstallError::Persist("数据目录未初始化".to_owned()))?;
        let path = dir.join(format!("{id}.json"));
        let bytes =
            std::fs::read(&path).map_err(|e| InstallError::Read(format!("{}: {e}", path.display())))?;
        Manifest::from_bytes(&bytes).map_err(|e| InstallError::Parse(e.to_string()))
    }

    /// 安装（校验通过才落盘）。
    pub fn install(
        &self,
        manifest: &Manifest,
        origin: &str,
    ) -> Result<InstalledSource, InstallError> {
        let errors = validate::validate_default(manifest);
        if !errors.is_empty() {
            return Err(InstallError::Invalid(
                errors
                    .iter()
                    .map(std::string::ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("；"),
            ));
        }
        let content_hash = manifest
            .content_hash()
            .map_err(|e| InstallError::Parse(e.to_string()))?;

        let mut state = self.inner.lock().expect("source store poisoned");
        if let Some(existing) = state.sources.get(&manifest.id)
            && existing.content_hash == content_hash
        {
            // 同内容重复安装：幂等成功。
            return Ok(existing.clone());
        }

        let record = InstalledSource {
            id: manifest.id.clone(),
            name: manifest.name.clone(),
            version: manifest.version.clone(),
            author: manifest.author.clone(),
            content_hash,
            installed_at_ms: now_ms(),
            enabled: true,
            origin: origin.to_owned(),
        };
        // 先写源文件，再更新索引（顺序保证「索引说有」时文件一定在）。
        if let Some(dir) = state.dir.clone() {
            let _ = std::fs::create_dir_all(&dir);
            let json = manifest
                .to_canonical_json()
                .map_err(|e| InstallError::Parse(e.to_string()))?;
            drama_store::write_atomic(
                &dir.join(format!("{}.json", manifest.id)),
                json.as_bytes(),
                Some(validate::MAX_PACKAGE_BYTES),
            )
            .map_err(|e| InstallError::Persist(e.to_string()))?;
        }
        state
            .sources
            .insert(manifest.id.clone(), record.clone());
        self.persist(&state)?;
        Ok(record)
    }

    /// 卸载。
    pub fn uninstall(&self, id: &str) -> Result<(), InstallError> {
        if id == drama_types::BUILTIN_SOURCE {
            return Err(InstallError::Builtin(id.to_owned()));
        }
        let mut state = self.inner.lock().expect("source store poisoned");
        if state.sources.remove(id).is_none() {
            return Err(InstallError::NotInstalled(id.to_owned()));
        }
        // 先更新索引再删文件：中断后最多留孤儿文件。
        self.persist(&state)?;
        if let Some(dir) = state.dir.clone() {
            let _ = std::fs::remove_file(dir.join(format!("{id}.json")));
        }
        Ok(())
    }

    /// 启停。
    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<(), InstallError> {
        let mut state = self.inner.lock().expect("source store poisoned");
        let record = state
            .sources
            .get_mut(id)
            .ok_or_else(|| InstallError::NotInstalled(id.to_owned()))?;
        record.enabled = enabled;
        self.persist(&state)
    }

    /// 已启用且非内置的源 id。
    pub fn enabled_rule_sources(&self) -> Vec<SourceId> {
        self.list()
            .into_iter()
            .filter(|s| s.enabled)
            .map(|s| SourceId::new(s.id))
            .collect()
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    const GOOD: &str = r#"
schema: 1
id: testsrc
name: 测试源
version: 1.0.0
author: official
base: https://www.example.com
ops:
  catalog:
    request:
      url: "{{base}}/list/{{page}}.html"
    items: "css:.item"
"#;

    fn store_with_dir(tag: &str) -> (SourceStore, drama_store::test_support::TempDir) {
        let temp = drama_store::test_support::TempDir::new(tag);
        let store = SourceStore {
            inner: Mutex::new(State::default()),
        };
        store.attach(temp.path().join("sources"));
        (store, temp)
    }

    fn manifest() -> Manifest {
        Manifest::from_yaml(GOOD).expect("load")
    }

    #[test]
    fn install_and_list() {
        let (store, _dir) = store_with_dir("store-install");
        let record = store.install(&manifest(), "local").expect("install");
        assert_eq!(record.id, "testsrc");
        assert!(record.enabled);
        assert_eq!(store.list().len(), 1);
        assert!(store.get("testsrc").is_some());
    }

    #[test]
    fn install_is_idempotent_for_same_content() {
        let (store, _dir) = store_with_dir("store-idempotent");
        let first = store.install(&manifest(), "local").expect("first");
        let second = store.install(&manifest(), "local").expect("second");
        assert_eq!(first.content_hash, second.content_hash);
        assert_eq!(store.list().len(), 1);
    }

    #[test]
    fn install_rejects_invalid_manifest() {
        let (store, _dir) = store_with_dir("store-invalid");
        let mut bad = manifest();
        bad.id = "hongguo".to_owned();
        let err = store.install(&bad, "local").unwrap_err();
        assert!(matches!(err, InstallError::Invalid(_)));
        assert!(store.list().is_empty(), "校验失败不能落盘");
    }

    #[test]
    fn failed_reinstall_keeps_existing() {
        let (store, _dir) = store_with_dir("store-keep");
        store.install(&manifest(), "local").expect("install");

        // 更新到坏包：已安装版本必须保持原样。
        let mut broken = manifest();
        broken.id = "testsrc".to_owned();
        broken.name = String::new();
        assert!(store.install(&broken, "local").is_err());
        let existing = store.get("testsrc").expect("still there");
        assert_eq!(existing.name, "测试源");
    }

    #[test]
    fn update_replaces_content() {
        let (store, _dir) = store_with_dir("store-update");
        store.install(&manifest(), "local").expect("install");
        let mut updated = manifest();
        updated.version = "2.0.0".to_owned();
        updated.name = "测试源 v2".to_owned();
        let record = store.install(&updated, "local").expect("update");
        assert_eq!(record.version, "2.0.0");
        assert_eq!(store.get("testsrc").expect("get").version, "2.0.0");
    }

    #[test]
    fn uninstall_and_reinstall() {
        let (store, _dir) = store_with_dir("store-uninstall");
        store.install(&manifest(), "local").expect("install");
        store.uninstall("testsrc").expect("uninstall");
        assert!(store.get("testsrc").is_none());
        // 重新安装成功。
        store.install(&manifest(), "local").expect("reinstall");
    }

    #[test]
    fn cannot_uninstall_builtin() {
        let (store, _dir) = store_with_dir("store-builtin");
        let err = store.uninstall("hongguo").unwrap_err();
        assert!(matches!(err, InstallError::Builtin(_)));
    }

    #[test]
    fn uninstall_unknown_is_an_error() {
        let (store, _dir) = store_with_dir("store-unknown");
        assert!(matches!(
            store.uninstall("nope").unwrap_err(),
            InstallError::NotInstalled(_)
        ));
    }

    #[test]
    fn enable_disable_roundtrip() {
        let (store, _dir) = store_with_dir("store-enable");
        store.install(&manifest(), "local").expect("install");
        store.set_enabled("testsrc", false).expect("disable");
        assert!(!store.get("testsrc").expect("get").enabled);
        assert!(store.enabled_rule_sources().is_empty());
        store.set_enabled("testsrc", true).expect("enable");
        assert_eq!(store.enabled_rule_sources().len(), 1);
        // 未安装的源不能启停。
        assert!(matches!(
            store.set_enabled("nope", true).unwrap_err(),
            InstallError::NotInstalled(_)
        ));
    }

    #[test]
    fn persists_across_attach() {
        let temp = drama_store::test_support::TempDir::new("store-persist");
        let dir = temp.path().join("sources");

        let store = SourceStore {
            inner: Mutex::new(State::default()),
        };
        store.attach(dir.clone());
        store.install(&manifest(), "https://official.example/repo").expect("install");
        store.set_enabled("testsrc", false).expect("disable");

        let reloaded = SourceStore {
            inner: Mutex::new(State::default()),
        };
        reloaded.attach(dir.clone());
        let record = reloaded.get("testsrc").expect("persisted");
        assert_eq!(record.name, "测试源");
        assert!(!record.enabled);
        assert_eq!(record.origin, "https://official.example/repo");
        // 源文件也在。
        assert!(dir.join("testsrc.json").exists());
    }

    #[test]
    fn corrupt_index_starts_empty_and_keeps_file() {
        let temp = drama_store::test_support::TempDir::new("store-corrupt");
        let dir = temp.path().join("sources");
        std::fs::create_dir_all(&dir).expect("mkdir");
        std::fs::write(dir.join("index.json"), b"{broken").expect("write");

        let store = SourceStore {
            inner: Mutex::new(State::default()),
        };
        store.attach(dir.clone());
        assert!(store.list().is_empty());
        // 原文件保留。
        assert!(dir.join("index.json").exists());
    }

    #[test]
    fn manifest_roundtrip_after_install() {
        let (store, _dir) = store_with_dir("store-roundtrip");
        let original = manifest();
        store.install(&original, "local").expect("install");
        let loaded = store.manifest("testsrc").expect("manifest");
        assert_eq!(loaded.id, original.id);
        assert_eq!(loaded.base, original.base);
    }

    #[test]
    fn manifest_missing_is_an_error() {
        let (store, _dir) = store_with_dir("store-missing");
        assert!(store.manifest("nope").is_err());
    }
}
