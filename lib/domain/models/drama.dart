import 'package:flutter/foundation.dart';

/// 剧集状态（「排序/连载筛选」）。
enum DramaStatus {
  ongoing('连载'),
  finished('完结');

  const DramaStatus(this.label);

  final String label;
}

/// 剧目领域模型（W1 由 mock 仓库供给，W2 起由 Rust 免签轨①供给）。
///
/// 不持久化带时效 URL：`cover` 为展示用地址/占位，取流地址由 `PlaybackPlan`
/// 另行承载（W3）。
@immutable
class Drama {
  const Drama({
    required this.id,
    required this.title,
    required this.categoryId,
    required this.categoryName,
    required this.episodeCount,
    this.summary = '',
    this.tags = const <String>[],
    this.status = DramaStatus.finished,
    this.vip = false,
  });

  /// 源内唯一 ID。
  final String id;

  final String title;

  final String categoryId;

  final String categoryName;

  /// 总集数。
  final int episodeCount;

  /// 简介。
  final String summary;

  /// 标签（题材）。
  final List<String> tags;

  final DramaStatus status;

  /// VIP 三态字段预留（Q4）：W1 仅作展示标记，UI 后置。
  final bool vip;

  /// 封面占位种子（W1 用确定性渐变代替真封面，见 [PosterArtwork]）。
  String get coverSeed => '$id·$title';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Drama && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
