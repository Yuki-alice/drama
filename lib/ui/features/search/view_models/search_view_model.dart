import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';

/// 搜索页状态。
///
/// 最近搜索最多保留 [SearchNotifier.maxRecent] 条，纯内存不落盘（W4 再接持久化）。
class SearchState {
  const SearchState({
    this.query = '',
    this.suggestions = const <String>[],
    this.results = const <Drama>[],
    this.searching = false,
    this.submitted = false,
    this.recentSearches = const <String>[],
    this.source = 'hongguo',
  });

  /// 当前输入框内容。
  final String query;

  /// 联想词（300ms 防抖后由 `suggest` op 产生）。
  final List<String> suggestions;

  /// 提交后的搜索结果。
  final List<Drama> results;

  /// 是否正在请求（联想或搜索）。
  final bool searching;

  /// 是否已提交查询（用于区分「联想中」与「已出结果」两种展示）。
  final bool submitted;

  /// 最近搜索词（纯内存，最新在前）。
  final List<String> recentSearches;

  /// 当前搜索源（`availableSourcesProvider` 中 `search` 为真的子集里选）。
  final String source;

  SearchState copyWith({
    String? query,
    List<String>? suggestions,
    List<Drama>? results,
    bool? searching,
    bool? submitted,
    List<String>? recentSearches,
    String? source,
  }) =>
      SearchState(
        query: query ?? this.query,
        suggestions: suggestions ?? this.suggestions,
        results: results ?? this.results,
        searching: searching ?? this.searching,
        submitted: submitted ?? this.submitted,
        recentSearches: recentSearches ?? this.recentSearches,
        source: source ?? this.source,
      );
}

/// 搜索状态控制器。
final searchProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);

class SearchNotifier extends Notifier<SearchState> {
  /// 最近搜索最大保留条数。
  static const int maxRecent = 8;

  @override
  SearchState build() => const SearchState();

  /// 切换搜索源：清空旧源结果/联想，避免把 A 源的结果顶着 B 源的标展示；
  /// 若输入框有词，立即在新源重查。
  Future<void> selectSource(String source) async {
    if (source.isEmpty || source == state.source) return;
    state = state.copyWith(
      source: source,
      suggestions: const <String>[],
      results: const <Drama>[],
      searching: false,
      submitted: false,
    );
    if (state.query.trim().isNotEmpty) {
      await submit(state.query);
    }
  }

  /// 指定源是否声明了某能力；源表未加载时按“未知即允许”（只在显式 false
  /// 时隐藏入口，与后端「未声明返回错误」的纪律互补）。
  bool _capEnabled(String cap) {
    final sources = ref.read(availableSourcesProvider).value;
    if (sources == null) return true;
    for (final s in sources) {
      if (s.id != state.source) continue;
      return switch (cap) {
        'suggest' => s.caps.suggest,
        'search' => s.caps.search,
        _ => true,
      };
    }
    return true;
  }

  /// 输入变化（由视图在 300ms 防抖后调用）：拉取联想，不算提交。
  ///
  /// 联想失败静默降级（不打断输入），只把 `searching` 落回 false。
  Future<void> onQueryChanged(String q) async {
    state = state.copyWith(
      query: q,
      suggestions: const <String>[],
      results: const <Drama>[],
      submitted: false,
      searching: true,
    );
    final keyword = q.trim();
    if (keyword.isEmpty) {
      state = state.copyWith(searching: false);
      return;
    }
    // 无联想能力的源直接跳过（省一次必错的往返）。
    if (!_capEnabled('suggest')) {
      state = state.copyWith(searching: false);
      return;
    }
    final source = state.source;
    try {
      final suggestions = await ref
          .read(catalogRepositoryForSourceProvider(source))
          .suggest(keyword);
      // stale 抑制：等待期间用户已改字或切源 → 丢弃这条迟到响应。
      if (state.query.trim() != keyword || state.source != source) return;
      state = state.copyWith(suggestions: suggestions, searching: false);
    } catch (_) {
      // 联想失败静默降级（不打断输入）。
      if (state.query.trim() != keyword || state.source != source) return;
      state = state.copyWith(searching: false);
    }
  }

  /// 提交查询：出结果并写入最近搜索。
  Future<void> submit(String q) async {
    final keyword = q.trim();
    if (keyword.isEmpty) return;
    final source = state.source;
    state = state.copyWith(
      query: keyword,
      suggestions: const <String>[],
      results: const <Drama>[],
      searching: true,
      submitted: false,
      recentSearches: _pushRecent(state.recentSearches, keyword),
    );
    try {
      final results = await ref
          .read(catalogRepositoryForSourceProvider(source))
          .search(keyword);
      // stale 抑制：已被更新的查询取代 → 丢弃迟到结果。
      // 同时核对源：等待期间切了源 → 旧源结果不得写入新源态。
      if (state.query.trim() != keyword || state.source != source) return;
      state = state.copyWith(
        results: results,
        searching: false,
        submitted: true,
      );
    } catch (_) {
      // 搜索失败：降级为空结果（UI 呈现「没有找到相关剧集」）。
      if (state.query.trim() != keyword) return;
      state = state.copyWith(
        results: const <Drama>[],
        searching: false,
        submitted: true,
      );
    }
  }

  /// 清空当前查询（保留最近搜索）。
  void clear() {
    state = SearchState(recentSearches: state.recentSearches);
  }

  /// 清空最近搜索记录（引导页的「清除」动作）。
  ///
  /// 与 [clear] 分开：一个是「清掉这次的输入」，一个是「忘掉搜索历史」，
  /// 后者是用户的隐私意图，不该混进前者顺手做掉。
  void clearRecent() {
    state = state.copyWith(recentSearches: const <String>[]);
  }

  /// 覆盖整表（管理态单删的入口）。
  ///
  /// 词表上限 [maxRecent] 条且纯内存，重建整表比给 notifier 加单删状态便宜。
  void setRecent(List<String> recent) {
    state = state.copyWith(
      recentSearches: recent.take(maxRecent).toList(growable: false),
    );
  }

  /// 将 [keyword] 置顶且去重，超过上限时截断。
  List<String> _pushRecent(List<String> current, String keyword) => <String>[
        keyword,
        ...current.where((item) => item != keyword),
      ].take(maxRecent).toList(growable: false);
}

/// 最近搜索词（派生自 [searchProvider] 状态，供视图单独监听）。
final recentSearchesProvider = Provider<List<String>>(
  (ref) => ref.watch(searchProvider).recentSearches,
);
