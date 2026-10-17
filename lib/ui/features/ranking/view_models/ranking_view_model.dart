import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_repository.dart';
import '../../../../domain/models/drama.dart';
import '../../home/view_models/home_view_model.dart';

/// 榜单板选中态。默认落在首个板（热搜榜）。
final rankingBoardProvider = NotifierProvider<RankingBoardNotifier, String>(
  RankingBoardNotifier.new,
);

class RankingBoardNotifier extends Notifier<String> {
  @override
  String build() => RankingBoards.all.first.id;

  /// 切换到指定榜单板。
  void select(String boardId) => state = boardId;
}

/// 当前榜单板下的剧目列表。
///
/// **跟随「当前内容源」**（[homeSourceProvider]）：榜单页顶栏的「切换源」
/// 与发现页共用同一份选择——若这里仍写死默认源，那个按钮就等于说谎。
final rankingListProvider = FutureProvider<List<Drama>>((ref) {
  final source = ref.watch(homeSourceProvider);
  return ref
      .watch(homeRepositoryProvider(source))
      .ranking(boardId: ref.watch(rankingBoardProvider));
});
