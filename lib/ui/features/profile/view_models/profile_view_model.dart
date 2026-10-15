import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「我的」页统计（W1 为占位 mock）。
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

  /// 已下载数。
  final int downloads;
}

/// W1 占位统计：未登录态全为 0，W2 起由真实账号数据供给。
final profileStatsProvider = Provider<ProfileStats>(
  (ref) => const ProfileStats(favorites: 0, history: 0, downloads: 0),
);
