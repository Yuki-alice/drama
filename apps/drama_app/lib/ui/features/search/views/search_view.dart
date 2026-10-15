import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../router/routes.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../view_models/search_view_model.dart';

/// 搜索页（PRD F-02，W1 纯 UI 外壳 / mock 数据）。
///
/// 用 [ConsumerStatefulWidget] 持有 [TextEditingController] 与防抖 [Timer]。
class SearchView extends ConsumerStatefulWidget {
  const SearchView({super.key});

  @override
  ConsumerState<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends ConsumerState<SearchView> {
  /// 输入防抖时长（PRD F-02：300ms）。
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 输入变化：中文输入法 composing 期间不请求，其余走 300ms 防抖。
  void _onChanged(String value) {
    if (_controller.value.composing.isValid) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      unawaited(ref.read(searchProvider.notifier).onQueryChanged(value));
    });
  }

  /// 填入并立即提交（回车 / 点击联想 / 点击最近搜索）。
  void _fillAndSubmit(String keyword) {
    _debounce?.cancel();
    _controller.value = TextEditingValue(
      text: keyword,
      selection: TextSelection.collapsed(offset: keyword.length),
    );
    unawaited(ref.read(searchProvider.notifier).submit(keyword));
  }

  /// 清空输入并重置查询（保留最近搜索）。
  void _clearSearch() {
    _debounce?.cancel();
    _controller.clear();
    ref.read(searchProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final colors = AppColors.of(context);

    return AppGlassScaffold(
      title: '搜索',
      leading: GlassIconAction(
        icon: Icons.arrow_back_ios_new,
        semanticLabel: '返回',
        onPressed: () => context.pop(),
      ),
      body: ContentWidthConstraint(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildSearchField(state, colors),
            Expanded(child: _buildContent(state, colors)),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(SearchState state, AppColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.md,
        AppSpacing.gutter,
        AppSpacing.sm,
      ),
      child: TextField(
        controller: _controller,
        onChanged: _onChanged,
        onSubmitted: _fillAndSubmit,
        textInputAction: TextInputAction.search,
        style: AppText.body.copyWith(color: colors.textPrimary),
        cursorColor: colors.accent,
        decoration: InputDecoration(
          filled: true,
          fillColor: colors.contentSurface,
          hintText: '搜索剧名 / 演员',
          hintStyle: AppText.body.copyWith(color: colors.textTertiary),
          prefixIcon: Icon(Icons.search, color: colors.textTertiary),
          suffixIcon: state.query.isEmpty
              ? null
              : IconButton(
                  onPressed: _clearSearch,
                  tooltip: '清空',
                  icon: Icon(Icons.close, size: 18, color: colors.textTertiary),
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildContent(SearchState state, AppColors colors) {
    // 空输入：展示最近搜索。
    if (state.query.trim().isEmpty) {
      return _buildRecentSearches(state.recentSearches, colors);
    }
    // 请求中：展示加载态（避免闪烁与误判「无结果」）。
    if (state.searching) {
      return const LoadingView();
    }
    // 已提交：展示结果网格。
    if (state.submitted) {
      if (state.results.isEmpty) {
        return const Center(child: EmptyView(message: '没有找到相关剧集'));
      }
      return DramaPosterGrid(
        dramas: state.results,
        onTap: (drama) => context.push(AppRoutes.detail(drama.id)),
      );
    }
    // 输入中且有联想：展示联想列表。
    if (state.suggestions.isNotEmpty) {
      return _buildSuggestions(state.suggestions, colors);
    }
    return const Center(child: EmptyView(message: '没有找到相关剧集'));
  }

  Widget _buildRecentSearches(List<String> recent, AppColors colors) {
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      children: <Widget>[
        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Text(
              '输入剧名 / 演员开始搜索',
              style: AppText.body.copyWith(color: colors.textTertiary),
            ),
          )
        else ...<Widget>[
          const SectionHeader(title: '最近搜索'),
          Padding(
            padding: AppSpacing.pageH,
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final keyword in recent)
                  ActionChip(
                    onPressed: () => _fillAndSubmit(keyword),
                    backgroundColor: colors.contentSurface,
                    side: BorderSide(color: colors.divider),
                    shape: const StadiumBorder(),
                    label: Text(
                      keyword,
                      style: AppText.callout.copyWith(color: colors.textPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSuggestions(List<String> suggestions, AppColors colors) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      itemCount: suggestions.length,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: colors.divider),
      itemBuilder: (context, index) {
        final keyword = suggestions[index];
        return ListTile(
          leading: Icon(Icons.search, size: 18, color: colors.textTertiary),
          title: Text(
            keyword,
            style: AppText.body.copyWith(color: colors.textPrimary),
          ),
          onTap: () => _fillAndSubmit(keyword),
        );
      },
    );
  }
}
