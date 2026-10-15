import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';

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

/// 追剧库条目（W2 由真实目录造 mock 观看进度）。
class LibraryItem {
  const LibraryItem({
    required this.drama,
    required this.watchedEpisode,
    required this.totalEpisode,
    required this.hasUpdate,
  });

  final Drama drama;

  /// 已看到第几集。
  final int watchedEpisode;

  /// 总集数。
  final int totalEpisode;

  /// 是否有更新。
  final bool hasUpdate;

  /// 观看进度 0..1。
  double get progress => totalEpisode == 0 ? 0 : watchedEpisode / totalEpisode;
}

/// W2 mock：取「推荐」分类首 8 条构造追剧记录（真实进度 W4 落地）。
///
/// 注意：`episodeCount` 可能为 0（真实源个别条目缺 `episode_cnt`），
/// 故进度取值必须先判零——否则 `% 0` 会抛 `IntegerDivisionByZeroException`
/// （W2 实机验收发现，追剧页曾因此崩溃）。
final libraryItemsProvider = FutureProvider<List<LibraryItem>>((ref) async {
  final page = await ref
      .watch(catalogRepositoryProvider)
      .catalog(categoryId: 'recommend', page: 0);
  final dramas = page.items.take(8).toList(growable: false);
  return <LibraryItem>[
    for (var index = 0; index < dramas.length; index++)
      LibraryItem(
        drama: dramas[index],
        watchedEpisode: _mockWatchedEpisode(index, dramas[index].episodeCount),
        totalEpisode: dramas[index].episodeCount,
        hasUpdate: index.isEven,
      ),
  ];
});

/// 确定性 mock 进度；`total` 为 0 时返回 0（不参与取模）。
int _mockWatchedEpisode(int index, int total) =>
    total <= 0 ? 0 : (index * 7 + 3) % total;
