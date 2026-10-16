import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/progress_repository.dart';

/// 追剧库分档：0 想看 / 1 在看 / 2 已看 / 3 有更新。
final libraryTabProvider = NotifierProvider<LibraryTabNotifier, int>(
  LibraryTabNotifier.new,
);

class LibraryTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// 切换到指定档位。
  void select(int index) => state = index;
}

/// 追剧库条目：由 Rust `followList` 的真实记录派生。
class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.title,
    required this.watchedEpisode,
    required this.totalEpisode,
    required this.position,
    this.cover = '',
    this.source = 'hongguo',
  });

  final String id;
  final String title;

  /// 所属源（详情/播放按源解析；跨源同 id 是不同剧）。
  final String source;

  /// 封面地址（本机代理 URL）；空串回落渐变占位。
  final String cover;

  /// 已看到第几集。
  final int watchedEpisode;

  /// 总集数；`0` = 未知（加追时未提供，或旧记录）。
  final int totalEpisode;

  /// 该集内的播放位置。
  final Duration position;

  /// 是否**一集都没看过**：位置为 0 且仍在第一集。
  ///
  /// 加追时写入 `episode=1, positionSecs=0`，故这等价于「加入追剧但未开看」。
  bool get isPlanned =>
      watchedEpisode <= 1 && position == Duration.zero;

  /// 是否已看完：总集数已知且已看到（或超过）最后一集。
  bool get isFinished =>
      totalEpisode > 0 && watchedEpisode >= totalEpisode;

  /// 是否「在看」：已开看、且尚有未看集数。
  bool get isWatching => !isPlanned && !isFinished;

  /// 是否还有未看的集数。
  ///
  /// 注意：这是「还剩几集没看」，**不是**「源站新更新了几集」——
  /// 后者需要重新拉取详情对比集数，离线无法判定。因此 `totalEpisode`
  /// 未知（`0`）时一律为 `false`，不臆断「有更新」。
  bool get hasUnwatched => totalEpisode > 0 && watchedEpisode < totalEpisode;

  /// 观看进度 0..1；总集数未知时为 0。
  double get progress =>
      totalEpisode <= 0 ? 0 : (watchedEpisode / totalEpisode).clamp(0.0, 1.0);
}

/// 追剧库列表：Rust 持久化的追剧记录（含总集数与观看进度）。
///
/// **核心不可用时返回空列表**（而非抛错）：与全局约定一致——核心挂了全站
/// 仍可导航（见 `catalog_providers.dart` 的 mock 回退），追剧页表现为空态，
/// 不该整页报错。这里**不回退 mock 数据**：追剧库是用户数据，造假比留白更糟。
///
/// 真实错误（如持久化读写失败）仍向上抛，由视图渲染错误态并可重试。
final libraryItemsProvider = FutureProvider<List<LibraryItem>>((ref) async {
  if (ref.watch(rustCoreProvider) == null) return const <LibraryItem>[];
  final follows = await ref.watch(followListProvider.future);
  return <LibraryItem>[
    for (final entry in follows)
      LibraryItem(
        id: entry.id,
        source: entry.source,
        title: entry.title.isEmpty ? entry.id : entry.title,
        watchedEpisode: entry.episode,
        totalEpisode: entry.totalEpisode,
        position: entry.position,
        cover: entry.cover,
      ),
  ];
});

/// 按当前分档过滤（纯函数，便于单测）。
///
/// 0 想看 / 1 在看 / 2 已看 / 3 有更新（= 尚有未看集数）。
List<LibraryItem> filterByTab(List<LibraryItem> items, int tab) {
  bool keep(LibraryItem item) {
    switch (tab) {
      case 0:
        return item.isPlanned;
      case 1:
        return item.isWatching;
      case 2:
        return item.isFinished;
      case 3:
        return item.hasUnwatched;
      default:
        return true;
    }
  }

  return <LibraryItem>[
    for (final item in items)
      if (keep(item)) item,
  ];
}

/// 当前分档下的条目（视图消费）。
final visibleLibraryItemsProvider = FutureProvider<List<LibraryItem>>((
  ref,
) async {
  final items = await ref.watch(libraryItemsProvider.future);
  return filterByTab(items, ref.watch(libraryTabProvider));
});
