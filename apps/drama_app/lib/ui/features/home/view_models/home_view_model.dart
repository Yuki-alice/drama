import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';
import '../../../../domain/models/drama_category.dart';

/// 排序口径（PRD F-01「排序/连载筛选」）。
enum HomeSort {
  latest('最新'),
  popular('最热');

  const HomeSort(this.label);

  final String label;
}

/// 连载状态筛选（PRD F-01）。
enum HomeStatusFilter {
  all('全部'),
  ongoing('连载'),
  finished('完结');

  const HomeStatusFilter(this.label);

  final String label;
}

/// 首页浏览条件（切类 / 排序 / 状态）。**只放条件，分页由 [HomeFeed] 承载。**
@immutable
class HomeFilter {
  const HomeFilter({
    this.categoryId = 'recommend',
    this.sort = HomeSort.latest,
    this.status = HomeStatusFilter.all,
  });

  final String categoryId;
  final HomeSort sort;
  final HomeStatusFilter status;

  HomeFilter copyWith({
    String? categoryId,
    HomeSort? sort,
    HomeStatusFilter? status,
  }) => HomeFilter(
    categoryId: categoryId ?? this.categoryId,
    sort: sort ?? this.sort,
    status: status ?? this.status,
  );
}

class HomeFilterNotifier extends Notifier<HomeFilter> {
  @override
  HomeFilter build() => const HomeFilter();

  /// 切类要重置筛选（PRD F-01：切类不丢状态只针对导航位置）。
  void selectCategory(String categoryId) =>
      state = HomeFilter(categoryId: categoryId);

  void selectSort(HomeSort sort) => state = state.copyWith(sort: sort);

  void selectStatus(HomeStatusFilter status) =>
      state = state.copyWith(status: status);
}

final homeFilterProvider =
    NotifierProvider<HomeFilterNotifier, HomeFilter>(HomeFilterNotifier.new);

/// 首页聚合结果：过滤/排序后的条目 + 是否还有下一页 + 已加载页数。
@immutable
class HomeFeed {
  const HomeFeed({
    required this.items,
    required this.hasMore,
    required this.loadedPages,
    this.loadingMore = false,
  });

  final List<Drama> items;

  /// 是否还能「加载更多」（PRD F-01 的兜底入口）。
  final bool hasMore;

  /// 已加载页数——触底分页（PRD F-01）。
  final int loadedPages;

  /// 是否正在追加下一页（用于展示加载态，同时保留旧列表避免整页闪）。
  final bool loadingMore;
}

/// 首页目录流：切类/筛选变化 → 自动重建重取；触底 → [loadMore] 追加。
final homeFeedProvider = AsyncNotifierProvider<HomeFeedNotifier, HomeFeed>(
  HomeFeedNotifier.new,
);

class HomeFeedNotifier extends AsyncNotifier<HomeFeed> {
  @override
  Future<HomeFeed> build() async {
    final filter = ref.watch(homeFilterProvider); // 条件变化 → 自动重建重取
    final repository = ref.watch(catalogRepositoryProvider);
    final store = ref.watch(cacheStoreProvider);

    // 重启续载：此前已加载多页（水位 depth>1）时，按顺序取回 page 0..depth-1
    // （缓存命中即瞬时返回，不发网络），把 loadedPages 设为 depth，
    // 使重启后不丢已加载的分页。取回后仍做排序/状态过滤。
    final depth = store?.catalogDepth(filter.categoryId) ?? 0;
    if (depth > 1) {
      final items = <Drama>[];
      var hasMore = true;
      for (var page = 0; page < depth; page++) {
        final result = await repository.catalog(
          categoryId: filter.categoryId,
          page: page,
        );
        items.addAll(_applyFilter(result.items, filter));
        hasMore = result.hasMore; // 以最后一页为准
      }
      return HomeFeed(items: items, hasMore: hasMore, loadedPages: depth);
    }

    final first = await repository.catalog(
      categoryId: filter.categoryId,
      page: 0,
    );
    return HomeFeed(
      items: _applyFilter(first.items, filter),
      hasMore: first.hasMore,
      loadedPages: 1,
    );
  }

  /// 追加下一页；失败保留旧数据并让错误态可见（plan §8）。
  Future<void> loadMore() async {
    // Riverpod 3 移除了 `valueOrNull`，`AsyncValue.value` 本身即为可空。
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    final filter = ref.read(homeFilterProvider);
    final repository = ref.read(catalogRepositoryProvider);
    // 保留旧列表、仅标记追加中，避免整页闪（不触发 AsyncLoading）。
    state = AsyncData(
      HomeFeed(
        items: current.items,
        hasMore: current.hasMore,
        loadedPages: current.loadedPages,
        loadingMore: true,
      ),
    );
    try {
      final page = await repository.catalog(
        categoryId: filter.categoryId,
        page: current.loadedPages,
      );
      state = AsyncData(
        HomeFeed(
          items: <Drama>[...current.items, ..._applyFilter(page.items, filter)],
          hasMore: page.hasMore,
          loadedPages: current.loadedPages + 1,
        ),
      );
    } catch (error, stack) {
      state = AsyncError<HomeFeed>(error, stack); // 顶部「加载更多」失败要让用户看到
    }
  }
}

/// 客户端筛选/排序（真源无排序参数，故取回后本地处理）。
List<Drama> _applyFilter(List<Drama> items, HomeFilter filter) {
  var result = items
      .where(
        (drama) => switch (filter.status) {
          HomeStatusFilter.all => true,
          HomeStatusFilter.ongoing => drama.status == DramaStatus.ongoing,
          HomeStatusFilter.finished => drama.status == DramaStatus.finished,
        },
      )
      .toList();
  if (filter.sort == HomeSort.popular) {
    result = result.reversed.toList();
  }
  return result;
}

/// 推荐位（PRD F-03）。
final homeRecommendationsProvider = FutureProvider<List<Drama>>(
  (ref) => ref.watch(catalogRepositoryProvider).recommendations(),
);

/// 分类列表（PRD F-01）——保持「数据来自仓库」。
final homeCategoriesProvider = FutureProvider<List<DramaCategory>>(
  (ref) => ref.watch(catalogRepositoryProvider).categories(),
);
