//! 红果短剧领域模型、wire 契约与错误语义。
//!
//! 本 crate **没有 IO、没有网络、没有全局状态**：它只定义「数据长什么样」与
//! 「错误怎么分类」。所有源实现、存储、下载、网关都依赖它，反向依赖一律禁止
//! （依赖方向：`types → net/store/rules → sources → engine → cli`）。
//!
//! ## 两套命名
//!
//! - **Rust 侧**：`Drama` / `Episode` / `PlayPlan`，字段 snake_case；
//! - **wire 侧**：JSON 字段是 **camelCase**（`sourceId`、`totalEpisode`、`proxyUrl`），
//!   因为 Flutter 前端按这套名字取字段。序列化统一经 `serde(rename_all = "camelCase")`，
//!   禁止在业务代码里手写 JSON 键名。
//!
//! 唯一例外是**归一化后的剧集对象**（[`Drama::to_wire`]）：它的字段集合是历史契约，
//! 必须逐字稳定，故单独手写。

pub mod contract;
pub mod drama;
pub mod error;
pub mod media;
pub mod source;

pub use contract::{
    ErrorBody, OpSpec, Request, Response, ENVELOPE_VERSION, MAX_INPUT_BYTES, OPS, budget_for,
    is_valid_session, ok, ok_items, op_spec, ops_json,
};
pub use drama::{
    Drama, DramaId, DramaStatus, Episode, EpisodeGroup, EpisodeGroups, RankingBoard, RankingItem,
    RankingPage, VipState, DEFAULT_GROUP_SIZE,
};
pub use error::{DramaError, ErrorCode, WireError};
pub use media::{MediaQuality, PlayPlan, QualityOption, ResolvedMedia, Variant};
pub use source::{
    BUILTIN_SOURCE, Caps, CatalogPage, DanmakuItem, DanmakuPage, DramaDetail, PlayRequest,
    SearchResult, SourceDescriptor, SourceId, SourceKind, SourceProvider,
};

/// 项目内统一的 `Result`。
pub type Result<T> = std::result::Result<T, DramaError>;
