//! 规则扩展源：声明式引擎。
//!
//! ## 设计要点（详见 docs/backend/EXTENSION_SOURCES.md）
//!
//! - **红果是唯一内置源**；其余源是运行期安装的规则包。
//! - **规则是受限的声明式程序**：没有循环、没有任意代码执行。
//!   这让审阅成为可能，也让「安装了恶意规则」的后果可控。
//! - **YAML 只用于编写**，客户端运行期只认规范化 JSON——
//!   少一个解析器，也避免 YAML 的注释/顺序影响内容哈希。
//!
//! ## 模块划分
//!
//! - [`manifest`]：规则包 schema 与加载（YAML/JSON → [`Manifest`]）
//! - [`template`]：`{{var}}` 模板渲染
//! - [`extract`]：JSON 点路径 / CSS 选择器 / 正则 取值
//! - [`transform`]：过滤器（strip_tags / absolutize / episode_number ...）
//! - [`engine`]：请求-解析-映射 的执行管线
//! - [`validate`]：结构 + 语义校验
//! - [`store`]：已安装源的管理（安装/卸载/启停）

pub mod extract;
pub mod manifest;
pub mod template;
pub mod transform;

pub use manifest::{Auth, ChapterSpec, Manifest, ManifestError, Method, Operation, Pagination,
    PlaybackSpec, RequestSpec};
