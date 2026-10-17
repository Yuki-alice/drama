//! 领域模型：剧、集、榜单、选集分组。
//!
//! ## wire 契约稳定性
//!
//! 这些结构体序列化后直接喂给 Flutter。**字段名与类型是契约**，
//! 改动必须同步 Dart 侧 `lib/domain/models/`。归一化剧集对象用
//! [`Drama::to_wire`] 手工构造——它的字段集是历史契约（含 `accessibleEpisodes`
//! 这类只在前端用的派生值），不适合直接 derive。

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::source::SourceId;

/// 剧的连载状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DramaStatus {
    Ongoing,
    #[default]
    Finished,
}

impl DramaStatus {
    /// wire 字符串（`"ongoing"` / `"finished"`）。
    pub fn as_str(self) -> &'static str {
        match self {
            DramaStatus::Ongoing => "ongoing",
            DramaStatus::Finished => "finished",
        }
    }

    /// 从上游的 `series_status` 数值映射：`1` 连载中，其余完结。
    ///
    /// 口径与 App 轨一致；字典未经直播确证，以实测为准。
    pub fn from_series_status(code: Option<i64>) -> Self {
        if code == Some(1) {
            DramaStatus::Ongoing
        } else {
            DramaStatus::Finished
        }
    }
}

/// VIP 三态。
///
/// 三态是必要的：`Unknown` 表示**源站没告诉我们**，此时 UI 不能显示「免费」，
/// 也不能显示「VIP」，更不能被后续的「免费」覆盖掉已知的「VIP」。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VipState {
    #[default]
    Unknown,
    Free,
    Vip,
}

impl VipState {
    /// 合并两个状态：**已知优先于未知**，同为已知时以 `self` 为准。
    ///
    /// 这条规则来自实测：站源列表页常常不给 `pay_type`，详情页才给；
    /// 若让未知覆盖已知，用户点进详情再返回，卡片上的 VIP 角标就消失了。
    pub fn merge(self, other: VipState) -> VipState {
        match (self, other) {
            (VipState::Unknown, o) => o,
            (s, _) => s,
        }
    }

    /// 从 `pay_type` 数值映射：`0` 免费，非 0 VIP，缺失为未知。
    pub fn from_pay_type(pay_type: Option<i64>) -> Self {
        match pay_type {
            Some(0) => VipState::Free,
            Some(_) => VipState::Vip,
            None => VipState::Unknown,
        }
    }

    /// 是否确定需要授权。
    pub fn is_vip(self) -> bool {
        matches!(self, VipState::Vip)
    }
}

/// 跨源唯一标识：`{source}:{source_id}`。
///
/// 单一字符串而非结构体，是因为它会被大量用作 map key 与落盘主键；
/// 拆成结构体后每次查表都要拼一次。
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DramaId {
    pub source: SourceId,
    pub source_id: String,
}

impl DramaId {
    pub fn new(source: impl Into<SourceId>, source_id: impl Into<String>) -> Self {
        DramaId {
            source: source.into(),
            source_id: source_id.into(),
        }
    }

    /// 拼成 `{source}:{source_id}`。
    ///
    /// `source_id` 里可能含 `:`（某些站源用 `id#source` 形式），故只在**第一个**
    /// `:` 处切分——见 [`DramaId::parse`]。
    pub fn to_key(&self) -> String {
        format!("{}:{}", self.source, self.source_id)
    }

    /// 从 `{source}:{source_id}` 解析。只在第一个 `:` 处切分。
    pub fn parse(key: &str) -> Option<Self> {
        let (source, rest) = key.split_once(':')?;
        if source.is_empty() || rest.is_empty() {
            return None;
        }
        Some(DramaId {
            source: SourceId::new(source),
            source_id: rest.to_owned(),
        })
    }
}

/// 剧。
///
/// 这是**内部模型**：源实现往这里填，序列化交给 [`Drama::to_wire`]。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Drama {
    pub id: DramaId,
    pub title: String,
    pub cover: String,
    pub category_id: String,
    pub category_name: String,
    /// 总集数；`0` = 未知。
    pub episode_count: u32,
    /// 免授权可播的集数（红果「可试看集」）；`0` = 未知。
    pub accessible_episodes: u32,
    pub summary: String,
    pub tags: Vec<String>,
    pub status: DramaStatus,
    pub vip: VipState,
    /// 热度/播放量等展示用指标（原样保留源站字符串）。
    pub metric: String,
}

impl Drama {
    /// 序列化为 wire 剧卡对象。
    ///
    /// 字段名逐字对齐 Dart `Drama.fromJson`：`id`（**不带源前缀**）、`title`、
    /// `cover`、`categoryId`、`categoryName`、`episodeCount`、`accessibleEpisodes`、
    /// `summary`、`tags`、`status`、`vip`。
    ///
    /// `vip` 只有确定时才输出布尔值；未知时**省略字段**——Dart 侧缺省为
    /// `false`，但我们不主动断言「免费」。三态信息由 `vipState` 额外携带。
    pub fn to_wire(&self) -> Value {
        let mut map = Map::with_capacity(13);
        map.insert("id".into(), Value::String(self.id.source_id.clone()));
        map.insert("title".into(), Value::String(self.title.clone()));
        map.insert("cover".into(), Value::String(self.cover.clone()));
        map.insert("categoryId".into(), Value::String(self.category_id.clone()));
        map.insert(
            "categoryName".into(),
            Value::String(self.category_name.clone()),
        );
        map.insert("episodeCount".into(), json!(self.episode_count));
        map.insert(
            "accessibleEpisodes".into(),
            json!(self.accessible_episodes),
        );
        map.insert("summary".into(), Value::String(self.summary.clone()));
        map.insert(
            "tags".into(),
            Value::Array(
                self.tags
                    .iter()
                    .map(|t| Value::String(t.clone()))
                    .collect(),
            ),
        );
        map.insert("status".into(), Value::String(self.status.as_str().to_owned()));
        // 三态：已知才给布尔，未知显式给 "unknown"。
        match self.vip {
            VipState::Vip => map.insert("vip".into(), Value::Bool(true)),
            VipState::Free => map.insert("vip".into(), Value::Bool(false)),
            VipState::Unknown => map.insert("vipState".into(), Value::String("unknown".into())),
        };
        if !self.metric.is_empty() {
            map.insert("metric".into(), Value::String(self.metric.clone()));
        }
        Value::Object(map)
    }

    /// 从 wire 剧卡对象还原（读缓存时用）。
    pub fn from_wire(source: &SourceId, value: &Value) -> Option<Self> {
        let source_id = value.get("id")?.as_str()?;
        if source_id.is_empty() {
            return None;
        }
        let str_of = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let vip = match value.get("vip").and_then(Value::as_bool) {
            Some(true) => VipState::Vip,
            Some(false) => VipState::Free,
            None => VipState::Unknown,
        };
        Some(Drama {
            id: DramaId::new(source.clone(), source_id),
            title: str_of("title"),
            cover: str_of("cover"),
            category_id: str_of("categoryId"),
            category_name: str_of("categoryName"),
            episode_count: value
                .get("episodeCount")
                .and_then(Value::as_u64)
                .unwrap_or(0) as u32,
            accessible_episodes: value
                .get("accessibleEpisodes")
                .and_then(Value::as_u64)
                .unwrap_or(0) as u32,
            summary: str_of("summary"),
            tags: value
                .get("tags")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default(),
            status: match value.get("status").and_then(Value::as_str) {
                Some("ongoing") => DramaStatus::Ongoing,
                _ => DramaStatus::Finished,
            },
            vip,
            metric: str_of("metric"),
        })
    }

    /// 合并两个同 id 剧卡：**已知字段优先，未知字段被填充**。
    ///
    /// 列表页字段少、详情页字段全；先看列表再进详情时，两者必须收敛到
    /// 「并集」，否则返回列表会发现封面/简介退化了。
    pub fn merge(&self, other: &Drama) -> Drama {
        let pick = |a: &str, b: &str| {
            if a.is_empty() {
                b.to_owned()
            } else {
                a.to_owned()
            }
        };
        Drama {
            id: self.id.clone(),
            title: pick(&self.title, &other.title),
            cover: pick(&self.cover, &other.cover),
            category_id: pick(&self.category_id, &other.category_id),
            category_name: pick(&self.category_name, &other.category_name),
            episode_count: if self.episode_count == 0 {
                other.episode_count
            } else {
                self.episode_count
            },
            accessible_episodes: if self.accessible_episodes == 0 {
                other.accessible_episodes
            } else {
                self.accessible_episodes
            },
            summary: pick(&self.summary, &other.summary),
            tags: if self.tags.is_empty() {
                other.tags.clone()
            } else {
                self.tags.clone()
            },
            status: if self.status == DramaStatus::Finished && other.status == DramaStatus::Ongoing {
                // 只要任一侧说「连载中」就是连载中：完结是不可逆断言，
                // 而列表页常把未标注的剧默认为 finished。
                DramaStatus::Ongoing
            } else {
                self.status
            },
            vip: self.vip.merge(other.vip),
            metric: pick(&self.metric, &other.metric),
        }
    }
}

/// 单集。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Episode {
    /// 1-based 集号。
    pub index: u32,
    pub title: String,
    /// 源侧视频 ID（红果 `vid`）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vid: Option<String>,
    /// 秒；`0` = 未知。
    #[serde(default)]
    pub duration_seconds: u32,
    /// 该集是否需授权才能播放。
    ///
    /// **必须明示**：试看集之外的分集在 UI 上不能静默失败。
    #[serde(default)]
    pub locked: bool,
    /// 集内可播地址（网页类源直接给 mp4/m3u8）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub url: String,
}

impl Episode {
    /// 构造一个「第 N 集」的最小对象。
    pub fn numbered(index: u32, vid: Option<String>) -> Self {
        Episode {
            index,
            title: format!("第 {index} 集"),
            vid,
            ..Default::default()
        }
    }

    /// 序列化为 wire 对象。
    ///
    /// 标题缺省为「第 N 集」，`durationSeconds` 用 `f64`（Dart 侧按 double 读）。
    pub fn to_wire(&self) -> Value {
        let mut map = Map::with_capacity(6);
        map.insert("index".into(), json!(self.index));
        map.insert(
            "title".into(),
            Value::String(if self.title.is_empty() {
                format!("第 {} 集", self.index)
            } else {
                self.title.clone()
            }),
        );
        if let Some(vid) = self.vid.as_deref().filter(|v| !v.is_empty()) {
            map.insert("vid".into(), Value::String(vid.to_owned()));
        }
        if !self.url.is_empty() {
            map.insert("url".into(), Value::String(self.url.clone()));
        }
        map.insert("durationSeconds".into(), json!(self.duration_seconds));
        map.insert("locked".into(), Value::Bool(self.locked));
        Value::Object(map)
    }
}

/// 选集分组：`groupSize` 集一组。
///
/// **分组规则归 Rust**：组大小、起止、标签（`"1-50"`）都是业务口径，
/// 前端只按组渲染。这样详情页与播放页的分组结果天然一致。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EpisodeGroup {
    pub index: usize,
    pub start: u32,
    pub end: u32,
    pub label: String,
    pub episodes: Vec<Value>,
}

/// 分组结果的 wire 形态。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EpisodeGroups {
    pub group_size: u32,
    pub total: usize,
    pub group_count: usize,
    pub groups: Vec<EpisodeGroup>,
}

/// 分组大小的上下限：防误传 1（几百个组）或 10000（等于不分组）。
pub const MIN_GROUP_SIZE: u32 = 10;
pub const MAX_GROUP_SIZE: u32 = 200;
/// 默认每组集数：一屏放得下，又不至于组太多。
pub const DEFAULT_GROUP_SIZE: u32 = 50;

impl EpisodeGroups {
    /// 按 `group_size` 切分。`group_size` 会被夹到
    /// [`MIN_GROUP_SIZE`]..=[`MAX_GROUP_SIZE`]。
    ///
    /// 用 `drain` 搬运 `Value` 而不是 clone：100 集规模下这是几十 KB 的差别。
    pub fn build(mut episodes: Vec<Value>, group_size: u32) -> Self {
        let size = group_size.clamp(MIN_GROUP_SIZE, MAX_GROUP_SIZE) as usize;
        let total = episodes.len();
        let mut groups = Vec::with_capacity(total.div_ceil(size));
        let mut index = 0usize;
        while !episodes.is_empty() {
            let take = size.min(episodes.len());
            let chunk: Vec<Value> = episodes.drain(..take).collect();
            let start = (index * size + 1) as u32;
            let end = start + chunk.len() as u32 - 1;
            groups.push(EpisodeGroup {
                index,
                start,
                end,
                label: format!("{start}-{end}"),
                episodes: chunk,
            });
            index += 1;
        }
        EpisodeGroups {
            group_size: size as u32,
            total,
            group_count: groups.len(),
            groups,
        }
    }
}

/// 榜单板定义。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RankingBoard {
    /// 全局唯一 id，如 `hongguo-hot`。
    pub id: String,
    pub source: SourceId,
    pub name: String,
    pub description: String,
    /// 源内路由键（红果为 `hot-drama` 等）。
    #[serde(skip)]
    pub route: String,
}

/// 榜单条目。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RankingItem {
    pub rank: u32,
    pub drama: Value,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub metric: String,
}

/// 一页榜单。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RankingPage {
    pub board_id: String,
    pub page: u32,
    pub items: Vec<RankingItem>,
    pub has_more: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_pages: Option<u32>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub updated_text: String,
    pub fetched_at_ms: i64,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub stale: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub warning: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drama_id_roundtrip_with_colon_in_source_id() {
        let id = DramaId::parse("fanguo:123#abc").expect("parse");
        assert_eq!(id.source.as_str(), "fanguo");
        // 只在第一个冒号处切分——源 id 内部可能还有冒号。
        assert_eq!(id.source_id, "123#abc");
        assert_eq!(id.to_key(), "fanguo:123#abc");
    }

    #[test]
    fn drama_id_rejects_malformed() {
        assert!(DramaId::parse("no-colon").is_none());
        assert!(DramaId::parse(":empty-source").is_none());
        assert!(DramaId::parse("empty-id:").is_none());
    }

    #[test]
    fn vip_unknown_does_not_override_known() {
        // 列表页给了 VIP，详情页没给 → 仍然是 VIP。
        assert_eq!(VipState::Vip.merge(VipState::Unknown), VipState::Vip);
        // 反向：列表页没给，详情页给了免费 → 免费。
        assert_eq!(VipState::Unknown.merge(VipState::Free), VipState::Free);
    }

    #[test]
    fn merge_prefers_known_fields() {
        let list = Drama {
            id: DramaId::new("hongguo", "1"),
            title: "标题".into(),
            episode_count: 0,
            vip: VipState::Unknown,
            status: DramaStatus::Finished,
            ..Default::default()
        };
        let detail = Drama {
            id: DramaId::new("hongguo", "1"),
            title: "标题".into(),
            cover: "封面".into(),
            episode_count: 80,
            vip: VipState::Vip,
            status: DramaStatus::Ongoing,
            ..Default::default()
        };
        let merged = list.merge(&detail);
        assert_eq!(merged.cover, "封面");
        assert_eq!(merged.episode_count, 80);
        assert_eq!(merged.vip, VipState::Vip);
        // 任一侧说连载中就是连载中。
        assert_eq!(merged.status, DramaStatus::Ongoing);
    }

    #[test]
    fn wire_card_uses_camel_case_and_bare_id() {
        let drama = Drama {
            id: DramaId::new("hongguo", "7654321"),
            title: "测试剧".into(),
            episode_count: 80,
            accessible_episodes: 3,
            vip: VipState::Unknown,
            ..Default::default()
        };
        let wire = drama.to_wire();
        assert_eq!(wire["id"], "7654321");
        assert_eq!(wire["episodeCount"], 80);
        assert_eq!(wire["accessibleEpisodes"], 3);
        assert_eq!(wire["status"], "finished");
        // 未知 VIP 不输出布尔断言。
        assert!(wire.get("vip").is_none());
        assert_eq!(wire["vipState"], "unknown");
    }

    #[test]
    fn wire_card_roundtrips() {
        let drama = Drama {
            id: DramaId::new("hongguo", "1"),
            title: "剧".into(),
            cover: "http://x/y.jpg".into(),
            tags: vec!["都市".into()],
            episode_count: 12,
            vip: VipState::Vip,
            status: DramaStatus::Ongoing,
            ..Default::default()
        };
        let source = SourceId::new("hongguo");
        let back = Drama::from_wire(&source, &drama.to_wire()).expect("from_wire");
        assert_eq!(back.title, drama.title);
        assert_eq!(back.vip, VipState::Vip);
        assert_eq!(back.status, DramaStatus::Ongoing);
        assert_eq!(back.tags, drama.tags);
    }

    #[test]
    fn groups_clamp_and_label() {
        let episodes: Vec<Value> = (1..=120).map(|i| json!({ "index": i })).collect();
        let groups = EpisodeGroups::build(episodes, 1);
        // 1 被夹到下限 10。
        assert_eq!(groups.group_size, MIN_GROUP_SIZE);
        assert_eq!(groups.total, 120);
        assert_eq!(groups.group_count, 12);
        assert_eq!(groups.groups[0].label, "1-10");
        assert_eq!(groups.groups[11].label, "111-120");
    }

    #[test]
    fn groups_handle_empty_and_partial_tail() {
        let groups = EpisodeGroups::build(Vec::new(), 50);
        assert_eq!(groups.total, 0);
        assert_eq!(groups.group_count, 0);

        let episodes: Vec<Value> = (1..=7).map(|i| json!({ "index": i })).collect();
        let groups = EpisodeGroups::build(episodes, 10);
        assert_eq!(groups.group_count, 1);
        assert_eq!(groups.groups[0].label, "1-7");
    }

    #[test]
    fn episode_wire_defaults_title() {
        let ep = Episode {
            index: 3,
            vid: Some("abc".into()),
            ..Default::default()
        };
        let wire = ep.to_wire();
        assert_eq!(wire["title"], "第 3 集");
        assert_eq!(wire["vid"], "abc");
        assert_eq!(wire["locked"], false);
    }
}
