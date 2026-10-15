import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/progress_repository.dart';

/// 「我的」页统计：追剧数与观看历史数取自 Rust 持久化；下载数暂无实现。
class ProfileStats {
  const ProfileStats({
    required this.favorites,
    required this.history,
    required this.downloads,
  });

  /// 追剧数。
  final int favorites;

  /// 观看历史数。
  final int history;

  /// 已下载数（下载能力未实现，恒为 0）。
  final int downloads;

  /// 全零统计（核心不可用 / 加载中 / 出错时的占位）。
  static const ProfileStats empty = ProfileStats(
    favorites: 0,
    history: 0,
    downloads: 0,
  );
}

/// 真实统计：并发读取追剧表与历史表长度。
///
/// 核心不可用（`rustCoreProvider` 为 null）时返回 [ProfileStats.empty]
/// 而非抛错——「我的」页是入口页，不该因计数失败而整体报错。
final profileStatsProvider = FutureProvider<ProfileStats>((ref) async {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) return ProfileStats.empty;

  final follows = ref.watch(followListProvider.future);
  final history = ref.watch(historyListProvider.future);
  final results = await (follows, history).wait;
  return ProfileStats(
    favorites: results.$1.length,
    history: results.$2.length,
    // 下载能力尚未实现；不猜测数字。
    downloads: 0,
  );
});
