import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/progress_repository.dart';
import '../../library/view_models/library_view_model.dart';

/// 「我的」页统计：三项**由数据算出**，不是写死的。
///
/// 在看 / 看完 取自追剧记录的分档判定；累计小时按**每集约 3 分钟**估
/// （短剧单集普遍 2–4 分钟，这是估值而不是精确时长——界面上以「约」呈现）。
class ProfileStats {
  const ProfileStats({
    this.following = 0,
    this.watching = 0,
    this.finished = 0,
    this.history = 0,
    this.watchedMinutes = 0,
  });

  /// 追剧总数。
  final int following;

  /// 在看（已开看、尚有未看）。
  final int watching;

  /// 已看完。
  final int finished;

  /// 观看历史条数。
  final int history;

  /// 累计观看分钟（按每集约 3 分钟估）。
  final int watchedMinutes;

  /// 累计小时（一位小数）。
  double get hours => watchedMinutes / 60;

  /// 全零统计（核心不可用 / 加载中 / 出错时的占位）。
  static const ProfileStats empty = ProfileStats();
}

/// 问候语（按本机时刻）。
///
/// 做成 provider 而**不是**在视图里直接读 `DateTime.now()`：视图里读时钟会让
/// 「早上好 / 下午好」随时间漂移，golden 基线永远不稳（同一份代码不同时刻跑出
/// 不同像素）。放进 provider 后，测试可以把它 override 成固定值，真机仍按真实
/// 时刻问候。
final greetingProvider = Provider<String>((ref) => greetingFor(DateTime.now()));

/// 由时刻推出问候语（纯函数，便于单测）。
String greetingFor(DateTime now) {
  final hour = now.hour;
  if (hour < 6) return '夜深了';
  if (hour < 11) return '早上好';
  if (hour < 14) return '中午好';
  if (hour < 18) return '下午好';
  return '晚上好';
}

/// 真实统计。
///
/// 核心不可用（`rustCoreProvider` 为 null）时返回 [ProfileStats.empty]
/// 而非抛错——「我的」页是入口页，不该因计数失败而整体报错。
final profileStatsProvider = FutureProvider<ProfileStats>((ref) async {
  if (ref.watch(rustCoreProvider) == null) return ProfileStats.empty;

  final items = await ref.watch(libraryItemsProvider.future);
  final history = await ref.watch(historyListProvider.future);
  return ProfileStats(
    following: items.length,
    watching: items.where((item) => item.isWatching).length,
    finished: items.where((item) => item.isFinished).length,
    history: history.length,
    watchedMinutes: items.fold<int>(
      0,
      (sum, item) => sum + item.watchedEpisode * LibraryItem.minutesPerEpisode,
    ),
  );
});
