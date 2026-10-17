//! 播放交付面：解析出的媒体、清晰度档位、播放计划。
//!
//! **关键设计**：解析结果里的 `url` 是**源站直链**，前端永远看不到它。
//! 播放器只打开本机回环代理的 `proxyUrl`——Referer 鉴权、加密密钥、
//! Range 处理全部留在 Rust 侧。

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// 清晰度档位（以画面高度标识）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct MediaQuality(pub i64);

impl MediaQuality {
    /// `0` 表示未知。
    pub const UNKNOWN: MediaQuality = MediaQuality(0);

    pub fn height(self) -> i64 {
        self.0
    }

    pub fn is_known(self) -> bool {
        self.0 > 0
    }

    /// 档位标签：`2160→4K`、`1440→2K`，其余 `{h}P`。
    ///
    /// 标签规则归 Rust：档位命名是业务口径，不是渲染细节。
    pub fn label(self) -> String {
        match self.0 {
            2160 => "4K".to_owned(),
            1440 => "2K".to_owned(),
            0 => "默认".to_owned(),
            h => format!("{h}P"),
        }
    }
}

/// 一条候选线路。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Variant {
    pub url: String,
    pub quality: i64,
    /// 需要加密密钥才能解（CENC）。
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub encrypted: bool,
}

/// 解析出的可播媒体。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedMedia {
    /// 选中的直链。
    pub url: String,
    /// 取流所需的 Referer（源站防盗链）。
    pub referer: String,
    /// 时长（秒）；`0` = 未知。
    pub duration_secs: f64,
    /// 选中档位。
    pub quality: i64,
    /// 是否加密。
    pub encrypted: bool,
    /// CENC 密钥（16 字节，十六进制小写）；未加密时为空。
    pub key_hex: String,
    /// 全部候选线路（含不同清晰度）。
    pub variants: Vec<Variant>,
    /// 该集的弹幕 id（`vid`），供 `danmaku` op 使用。
    pub danmaku_vid: String,
}

impl ResolvedMedia {
    /// 按期望清晰度挑候选。
    ///
    /// `preferred > 0` 时取 `quality <= preferred` 里最高的；无满足则**回退最低档**
    /// （宁可糊也不要断流）。`preferred <= 0` 取最高档。
    pub fn pick(variants: &[Variant], preferred: i64) -> Option<&Variant> {
        let mut best: Option<&Variant> = None;
        let mut lowest: Option<&Variant> = None;
        for v in variants {
            if lowest.is_none_or(|l| v.quality < l.quality) {
                lowest = Some(v);
            }
            if preferred <= 0 {
                if best.is_none_or(|b| v.quality > b.quality) {
                    best = Some(v);
                }
            } else if v.quality <= preferred && best.is_none_or(|b| v.quality > b.quality) {
                best = Some(v);
            }
        }
        best.or(lowest)
    }

    /// 可切换档位（去重、**降序**）。
    pub fn quality_options(variants: &[Variant]) -> Vec<QualityOption> {
        let mut heights: Vec<i64> = variants
            .iter()
            .map(|v| v.quality)
            .filter(|q| *q > 0)
            .collect();
        heights.sort_unstable();
        heights.dedup();
        heights
            .into_iter()
            .rev()
            .map(|h| QualityOption {
                height: h,
                label: MediaQuality(h).label(),
            })
            .collect()
    }

    /// 以「另一个候选」替换当前选择（换档用，零网络）。
    pub fn with_variant(&self, variant: &Variant) -> ResolvedMedia {
        let mut out = self.clone();
        out.url = variant.url.clone();
        out.quality = variant.quality;
        out.encrypted = variant.encrypted;
        out
    }
}

/// 可切换档位。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QualityOption {
    pub height: i64,
    pub label: String,
}

/// 播放计划：前端拿到的东西。
///
/// `url` 与 `proxy_url` 都出现是**故意的**：`proxy_url` 是播放器真正打开的地址，
/// `url` 保留给诊断与「复制链接」这类显式动作，且**在网关不可用时**前端仍能
/// 降级直连（此时 Referer 由播放器自己带，多数 CDN 不校验）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayPlan {
    pub proxy_url: String,
    pub url: String,
    pub vid: String,
    pub encrypted: bool,
    pub quality: i64,
    pub duration_secs: f64,
    pub variants: Vec<Variant>,
    pub quality_options: Vec<QualityOption>,
    /// 是否来自本地已下载文件。
    pub offline: bool,
    /// 是否来自缓存（网络失败后的兜底）。
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub stale: bool,
    /// 弹幕 id（前端据此请求弹幕）。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub danmaku_vid: String,
}

impl PlayPlan {
    /// 从解析结果构造（`proxy_url` 由网关填充）。
    pub fn from_media(media: &ResolvedMedia, vid: &str, proxy_url: String) -> Self {
        PlayPlan {
            proxy_url,
            url: media.url.clone(),
            vid: vid.to_owned(),
            encrypted: media.encrypted,
            quality: media.quality,
            duration_secs: media.duration_secs,
            variants: media.variants.clone(),
            quality_options: ResolvedMedia::quality_options(&media.variants),
            offline: false,
            stale: false,
            danmaku_vid: media.danmaku_vid.clone(),
        }
    }

    /// 转 wire JSON。
    pub fn to_wire(&self) -> Value {
        serde_json::to_value(self).unwrap_or_else(|_| json!({}))
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn variant(url: &str, quality: i64) -> Variant {
        Variant {
            url: url.to_owned(),
            quality,
            encrypted: false,
        }
    }

    #[test]
    fn pick_highest_when_no_preference() {
        let variants = vec![variant("a", 360), variant("b", 1080), variant("c", 720)];
        assert_eq!(ResolvedMedia::pick(&variants, 0).unwrap().url, "b");
    }

    #[test]
    fn pick_ceiling_below_preference() {
        let variants = vec![variant("a", 360), variant("b", 1080), variant("c", 720)];
        assert_eq!(ResolvedMedia::pick(&variants, 800).unwrap().url, "c");
        assert_eq!(ResolvedMedia::pick(&variants, 1080).unwrap().url, "b");
    }

    #[test]
    fn pick_falls_back_to_lowest_rather_than_nothing() {
        // 要 480 但只有 720 以上：宁可糊/清都要给一条，不能返回 None。
        let variants = vec![variant("a", 720), variant("b", 1080)];
        assert_eq!(ResolvedMedia::pick(&variants, 480).unwrap().url, "a");
    }

    #[test]
    fn pick_empty_is_none() {
        assert!(ResolvedMedia::pick(&[], 0).is_none());
    }

    #[test]
    fn quality_options_sorted_desc_and_deduped() {
        let variants = vec![
            variant("a", 360),
            variant("b", 1080),
            variant("c", 1080),
            variant("d", 0),
        ];
        let options = ResolvedMedia::quality_options(&variants);
        assert_eq!(
            options.iter().map(|o| o.height).collect::<Vec<_>>(),
            vec![1080, 360]
        );
        assert_eq!(options[0].label, "1080P");
    }

    #[test]
    fn quality_labels() {
        assert_eq!(MediaQuality(2160).label(), "4K");
        assert_eq!(MediaQuality(1440).label(), "2K");
        assert_eq!(MediaQuality(720).label(), "720P");
        assert_eq!(MediaQuality(0).label(), "默认");
    }
}
