//! 运行时源注册表（源集合由注册表决定，**禁止编译期源开关**）。

pub mod traits;

use std::sync::Arc;

use once_cell::sync::Lazy;
use traits::{SourceError, SourceProvider};

/// 默认源 id。
pub const DEFAULT_SOURCE_ID: &str = "hongguo";

/// 注册表：P0 只注册 `hongguo`（默认源）。P2 扩展源在此追加即可，引擎与 Dart 侧零改动。
static REGISTRY: Lazy<Vec<Arc<dyn SourceProvider>>> = Lazy::new(|| {
    vec![Arc::new(crate::sources::hongguo::HongguoProvider::new()) as Arc<dyn SourceProvider>]
});

/// 按 `source` 取实现：`None` 用默认源；未注册返回 [`SourceError::NotFound`]。
pub fn provider(source: Option<&str>) -> Result<Arc<dyn SourceProvider>, SourceError> {
    let key = source.unwrap_or(DEFAULT_SOURCE_ID);
    REGISTRY
        .iter()
        .find(|p| p.id() == key)
        .cloned()
        .ok_or(SourceError::NotFound)
}

/// 已注册源（供 `version` op 列 caps）。
pub fn registered() -> &'static [Arc<dyn SourceProvider>] {
    REGISTRY.as_slice()
}
