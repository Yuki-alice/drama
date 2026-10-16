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
/// 不持久化带时效 URL：`cover` 为展示用地址，取流地址由 `PlaybackPlan`
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
    this.cover = '',
    this.source = 'hongguo',
  });

  /// 源内唯一 ID。
  final String id;

  /// 所属源（仓库按自身源盖章；跨源同 id 是不同剧目）。
  final String source;

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

  /// 封面地址。
  ///
  /// **始终是本机回环地址**（`http://127.0.0.1:{port}/img/{token}`）——
  /// Rust 在解析时就把源站 CDN 地址换成了代理地址（见 `covers` 模块），
  /// 因此 Dart 侧不需要、也不应该知道源站在哪。
  /// 空串 = 该条目无封面（回落 [coverSeed] 渐变占位）。
  final String cover;

  /// 封面占位种子（无 [cover] 时用确定性渐变，见 `DramaCover`）。
  String get coverSeed => '$id·$title';

  /// 是否有可用封面。
  bool get hasCover => cover.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Drama &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          source == other.source;

  @override
  int get hashCode => Object.hash(id, source);
}
