import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../domain/models/drama.dart';

/// 榜单板选中态（PRD F-03）。默认落在首个板（热搜榜）。
final rankingBoardProvider =
    NotifierProvider<RankingBoardNotifier, String>(RankingBoardNotifier.new);

class RankingBoardNotifier extends Notifier<String> {
  @override
  String build() => RankingBoards.all.first.id;

  /// 切换到指定榜单板。
  void select(String boardId) => state = boardId;
}

/// 当前榜单板下的剧目列表（W2 由红果免签轨①供给；核心不可用时回退 mock）。
final rankingListProvider = FutureProvider<List<Drama>>(
  (ref) => ref.watch(catalogRepositoryProvider).ranking(
    boardId: ref.watch(rankingBoardProvider),
  ),
);
