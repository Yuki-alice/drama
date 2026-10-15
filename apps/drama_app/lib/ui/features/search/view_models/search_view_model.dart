import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';

/// 搜索页状态（PRD F-02）。
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

  SearchState copyWith({
    String? query,
    List<String>? suggestions,
    List<Drama>? results,
    bool? searching,
    bool? submitted,
    List<String>? recentSearches,
  }) => SearchState(
    query: query ?? this.query,
    suggestions: suggestions ?? this.suggestions,
    results: results ?? this.results,
    searching: searching ?? this.searching,
    submitted: submitted ?? this.submitted,
    recentSearches: recentSearches ?? this.recentSearches,
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
    try {
      final suggestions = await ref
          .read(catalogRepositoryProvider)
          .suggest(keyword);
      // stale 抑制：等待期间用户已改字 → 丢弃这条迟到响应（plan §4 W2 关键任务 5）。
      if (state.query.trim() != keyword) return;
      state = state.copyWith(suggestions: suggestions, searching: false);
    } catch (_) {
      // 联想失败静默降级（不打断输入）。
      if (state.query.trim() != keyword) return;
      state = state.copyWith(searching: false);
    }
  }

  /// 提交查询：出结果并写入最近搜索。
  Future<void> submit(String q) async {
    final keyword = q.trim();
    if (keyword.isEmpty) return;
    state = state.copyWith(
      query: keyword,
      suggestions: const <String>[],
      results: const <Drama>[],
      searching: true,
      submitted: false,
      recentSearches: _pushRecent(state.recentSearches, keyword),
    );
    try {
      final results = await ref.read(catalogRepositoryProvider).search(keyword);
      // stale 抑制：已被更新的查询取代 → 丢弃迟到结果。
      if (state.query.trim() != keyword) return;
      state = state.copyWith(results: results, searching: false, submitted: true);
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
