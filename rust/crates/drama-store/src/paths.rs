//! 数据目录布局。
//!
//! 单一入口决定所有文件落在哪里，避免各模块自己拼路径（拼错了就是
//! 「缓存写到下载目录里」这类问题）。

use std::path::{Path, PathBuf};

/// 数据目录集合。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataDirs {
    /// 应用私有数据根目录（缓存、追剧、设置）。
    pub data_dir: PathBuf,
    /// 下载根目录（用户可见，可能在外部存储）。
    pub download_dir: PathBuf,
}

impl DataDirs {
    /// 用数据根目录构造，下载目录默认在其下 `downloads`。
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        let data_dir = data_dir.into();
        let download_dir = data_dir.join("downloads");
        DataDirs {
            data_dir,
            download_dir,
        }
    }

    /// 覆盖下载目录。
    pub fn with_download_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        let dir = dir.into();
        if !dir.as_os_str().is_empty() {
            self.download_dir = dir;
        }
        self
    }

    /// 创建所有必需目录（0700）。
    pub fn ensure(&self) -> std::io::Result<()> {
        create_private_dir(&self.data_dir)?;
        create_private_dir(&self.download_dir)?;
        create_private_dir(&self.covers_dir())?;
        create_private_dir(&self.sources_dir())?;
        Ok(())
    }

    pub fn catalog_file(&self) -> PathBuf {
        self.data_dir.join("catalogs.json")
    }

    pub fn library_file(&self) -> PathBuf {
        self.data_dir.join("library.json")
    }

    pub fn settings_file(&self) -> PathBuf {
        self.data_dir.join("settings.json")
    }

    pub fn users_file(&self) -> PathBuf {
        self.data_dir.join("users.json")
    }

    pub fn device_file(&self) -> PathBuf {
        self.data_dir.join("device.json")
    }

    pub fn sources_dir(&self) -> PathBuf {
        self.data_dir.join("sources")
    }

    pub fn covers_dir(&self) -> PathBuf {
        self.data_dir.join("covers")
    }

    pub fn downloads_index(&self) -> PathBuf {
        self.download_dir.join("index.json")
    }
}

/// 创建 0700 目录（已存在则忽略）。
#[cfg(unix)]
pub fn create_private_dir(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    if path.is_dir() {
        return Ok(());
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
}

#[cfg(not(unix))]
pub fn create_private_dir(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    #[test]
    fn default_download_dir_is_under_data_dir() {
        let dirs = DataDirs::new("/tmp/x");
        assert_eq!(dirs.download_dir, PathBuf::from("/tmp/x/downloads"));
    }

    #[test]
    fn explicit_download_dir_wins() {
        let dirs = DataDirs::new("/tmp/x").with_download_dir("/mnt/sd/drama");
        assert_eq!(dirs.download_dir, PathBuf::from("/mnt/sd/drama"));
    }

    #[test]
    fn empty_download_dir_is_ignored() {
        let dirs = DataDirs::new("/tmp/x").with_download_dir("");
        assert_eq!(dirs.download_dir, PathBuf::from("/tmp/x/downloads"));
    }

    #[test]
    fn ensure_creates_all_directories() {
        let temp = TempDir::new("paths");
        let dirs = DataDirs::new(temp.path().join("data"));
        dirs.ensure().expect("ensure");
        assert!(dirs.data_dir.is_dir());
        assert!(dirs.download_dir.is_dir());
        assert!(dirs.covers_dir().is_dir());
        assert!(dirs.sources_dir().is_dir());
        // 幂等。
        dirs.ensure().expect("ensure again");
    }
}
