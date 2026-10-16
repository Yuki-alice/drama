import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../data/services/rust_core.dart';
import '../../../../domain/models/drama.dart';
import '../../../../domain/models/drama_category.dart';

/// 首页当前内容源（默认主源 `hongguo`）。
///
/// 顶栏「选择源」切换它；[homeFeedProvider] 跟随重建并重取。
final homeSourceProvider = NotifierProvider<HomeSourceNotifier, String>(
  HomeSourceNotifier.new,
);

class HomeSourceNotifier extends Notifier<String> {
  @override
  String build() => 'hongguo';

  void select(String source) {
    if (source.isNotEmpty) state = source;
  }
}

/// 源对应的首页默认分类（真实源的首个内容分类；未知源退回 `recommend`）。
String homeDefaultCategoryOf(String source) => switch (source) {
      'hongguo' => 'real-drama',
      'huangguoai' => 'ai-duanju',
      _ => 'recommend',
    };

/// 当前源对应的目录仓库。
///
/// 主源走默认装配（含核心不可用时的 mock 回退）；其余源走按源仓库。
final homeRepositoryProvider = Provider.family<CatalogRepository, String>(
  (ref, source) => source == 'hongguo'
      ? ref.watch(catalogRepositoryProvider)
      : ref.watch(catalogRepositoryForSourceProvider(source)),
);

/// 首页聚合结果：条目 + 是否还有下一页 + 已加载页数。
@immutable
class HomeFeed {
  const HomeFeed({
    required this.items,
    required this.hasMore,
    required this.loadedPages,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<Drama> items;

  /// 是否还能「加载更多」（的兜底入口）。
  final bool hasMore;

  /// 已加载页数——分页水位。
  final int loadedPages;

  /// 是否正在追加下一页（用于展示加载态，同时保留旧列表避免整页闪）。
  final bool loadingMore;

  /// 追加失败的原因；`null` = 上次追加成功或尚未追加。
  ///
  /// **失败只标记错误，不动 [items]**：此前失败时 `state = AsyncError(...)`
  /// 会把已加载的 `items` 整个丢掉，视图随之渲染整页 `ErrorView`——用户翻到
  /// 第 5 页时一次网络抖动，整个信息流就消失了。现在失败只在列表尾部出现
  /// 一条可重试的提示。
  final String? loadMoreError;

  /// 是否列表为空（首屏失败才会整页报错，见 [loadMoreError]）。
  bool get isEmpty => items.isEmpty;

  /// 只改「追加中 / 追加失败」两个瞬时标记，列表本身**原样保留**。
  HomeFeed markLoadMore({
    bool? loadingMore,
    String? error,
    bool clearError = false,
  }) =>
      HomeFeed(
        items: items,
        hasMore: hasMore,
        loadedPages: loadedPages,
        loadingMore: loadingMore ?? this.loadingMore,
        loadMoreError: clearError ? null : (error ?? loadMoreError),
      );

  /// 追加一页（成功路径）。
  HomeFeed append(
    List<Drama> more, {
    required bool hasMore,
    required int loadedPages,
  }) =>
      HomeFeed(
        items: <Drama>[...items, ...more],
        hasMore: hasMore,
        loadedPages: loadedPages,
      );
}

/// 首页目录流：源变化 → 自动重建重取；触底 → [loadMore] 追加。
final homeFeedProvider = AsyncNotifierProvider<HomeFeedNotifier, HomeFeed>(
  HomeFeedNotifier.new,
);

class HomeFeedNotifier extends AsyncNotifier<HomeFeed> {
  @override
  Future<HomeFeed> build() async {
    final source = ref.watch(homeSourceProvider);
    final repository = ref.watch(homeRepositoryProvider(source));

    // 重启续载：**一次往返**取回此前已加载的 0..depth-1 页。
    //
    // 分页水位由 Rust 侧记录（`catalogPages` 不传 depth 即跟随水位），
    // 缓存命中的页在 Rust 内瞬时返回 —— 往返数从 N 降到 1，
    // 也省掉 N 次 JSON 编解码。
    final pages = await repository.catalogPages(
      categoryId: homeDefaultCategoryOf(source),
    );
    if (pages.isEmpty) {
      return const HomeFeed(items: <Drama>[], hasMore: false, loadedPages: 0);
    }
    return HomeFeed(
      items: <Drama>[
        for (final page in pages) ...page.items,
      ],
      hasMore: pages.last.hasMore, // 以最后一页为准
      loadedPages: pages.length,
    );
  }

  /// 追加下一页。
  ///
  /// **失败不丢数据**：catch 分支只把错误记进 [HomeFeed.loadMoreError]，
  /// 已加载的 `items` 原样保留，视图在列表尾部渲染一条可重试的提示。
  /// 只有 `build()` 的首载失败才让 `AsyncError` 冒到整页 `ErrorView`。
  Future<void> loadMore() async {
    // Riverpod 3 移除了 `valueOrNull`，`AsyncValue.value` 本身即为可空。
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    final source = ref.read(homeSourceProvider);
    final repository = ref.read(homeRepositoryProvider(source));
    // 保留旧列表、仅标记追加中，避免整页闪（不触发 AsyncLoading）。
    // 同时清掉上一次的错误：重试期间不该继续显示「上次失败了」。
    state =
        AsyncData(current.markLoadMore(loadingMore: true, clearError: true));
    try {
      final page = await repository.catalog(
        categoryId: homeDefaultCategoryOf(source),
        page: current.loadedPages,
      );
      state = AsyncData(
        current.append(
          page.items,
          hasMore: page.hasMore,
          loadedPages: current.loadedPages + 1,
        ),
      );
    } catch (error) {
      final message =
          error is RustCoreException ? '${error.msg}（${error.code}）' : '$error';
      state = AsyncData(
        current.markLoadMore(loadingMore: false, error: message),
      );
    }
  }
}

/// 推荐位（其它页面的推荐货架可用）。
final homeRecommendationsProvider = FutureProvider<List<Drama>>(
  (ref) => ref.watch(catalogRepositoryProvider).recommendations(),
);

/// 分类列表——保持「数据来自仓库」。
final homeCategoriesProvider = FutureProvider<List<DramaCategory>>(
  (ref) => ref.watch(catalogRepositoryProvider).categories(),
);
