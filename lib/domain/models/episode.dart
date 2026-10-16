import 'package:flutter/foundation.dart';

/// 单集领域模型（「选集」）。
@immutable
class Episode {
  const Episode({
    required this.index,
    required this.title,
    this.vid,
    this.duration,
    this.locked = false,
  });

  /// 1-based 集号。
  final int index;

  /// 集标题（默认「第 N 集」）。
  final String title;

  /// 源侧视频 ID（红果 `vid_list[]` 的取值）——W3 取流时使用。
  final String? vid;

  final Duration? duration;

  /// 该集是否需授权才能播放。
  ///
  /// 轨① 免签只覆盖可试看集；锁定集在 UI 上必须**明示**
  /// 「该集需 App 授权」，不得静默失败。
  final bool locked;

  /// 与 `HongguoCatalogRepository._episode` **同一口径**（字段名 `durationSeconds`、
  /// 标题缺省「第 N 集」）：分组结果走的是同一批剧集 JSON，两边解析必须一致。
  factory Episode.fromJson(Map<String, Object?> json) {
    final seconds = (json['durationSeconds'] as num?)?.toDouble();
    final index = (json['index'] as num?)?.toInt() ?? 0;
    return Episode(
      index: index,
      title: json['title'] as String? ?? '第 $index 集',
      vid: json['vid'] as String?,
      duration: seconds == null
          ? null
          : Duration(milliseconds: (seconds * 1000).round()),
      locked: json['locked'] == true,
    );
  }
}

/// 选集分组（Rust `episodeGroups` op 的结果）。
///
/// **分组规则归 Rust**：组大小、起止、标签（"1-50"）都是业务口径，Dart 只按组
/// 渲染、不自己切片。此前播放页 `take(60)` 硬截（60 集以上的剧点不到后面），
/// 详情页又各有一套常量——现在两处共用同一份结果，口径统一。
@immutable
class EpisodeGroup {
  const EpisodeGroup({
    required this.index,
    required this.start,
    required this.end,
    required this.label,
    required this.episodes,
  });

  /// 0-based 组号。
  final int index;

  /// 本组首集 / 末集（1-based，闭区间）。
  final int start;
  final int end;

  /// 组标签（如 `1-50`），直接用于 chip 文案。
  final String label;

  /// 本组剧集（每组自带，Dart 无需再切片）。
  final List<Episode> episodes;

  factory EpisodeGroup.fromJson(Map<String, Object?> json) {
    final raw = json['episodes'];
    return EpisodeGroup(
      index: (json['index'] as num?)?.toInt() ?? 0,
      start: (json['start'] as num?)?.toInt() ?? 0,
      end: (json['end'] as num?)?.toInt() ?? 0,
      label: json['label'] as String? ?? '',
      episodes: raw is List
          ? <Episode>[
              for (final item in raw)
                if (item is Map)
                  Episode.fromJson(Map<String, Object?>.from(item)),
            ]
          : const <Episode>[],
    );
  }
}

/// 选集分组结果。
@immutable
class EpisodeGroups {
  const EpisodeGroups({
    required this.groupSize,
    required this.total,
    required this.groups,
  });

  /// 实际生效的每组集数（Rust 会把误传值夹到上下限内）。
  final int groupSize;

  /// 总集数。
  final int total;

  final List<EpisodeGroup> groups;

  factory EpisodeGroups.fromJson(Map<String, Object?> json) {
    final raw = json['groups'];
    return EpisodeGroups(
      groupSize: (json['groupSize'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      groups: raw is List
          ? <EpisodeGroup>[
              for (final item in raw)
                if (item is Map)
                  EpisodeGroup.fromJson(Map<String, Object?>.from(item)),
            ]
          : const <EpisodeGroup>[],
    );
  }
}
