import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';
import '../../../../router/routes.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_surface.dart';
import '../../../core/widgets/lockups.dart';
import '../../../core/widgets/source_sheet.dart';
import '../view_models/search_view_model.dart';

/// 搜索：**筛选优先**（对齐 Kazumi，无热门趋势）。
///
/// - **无导航**（push 进来的子页），所以搜索框左侧自带一枚返回圆钮
///   （浅雾底，不是玻璃——它在纯色上）；
/// - 搜索框是 44px **浅雾底圆角槽**，随内容滚动，因此不能用玻璃；
/// - 引导态只做两件事：「按条件筛选」主入口 + 最近搜索；
/// - 结果态：「搜索结果」+ 计数 + 排序 chip + 筛选钮（有筛选时带 Badge）
///   + 一行筛选摘要；网格**复用发现的密度公式**，视觉语言不换挡；
/// - 内容最大宽：引导态 760、结果态 1120，居中留白。
class SearchView extends ConsumerStatefulWidget {
  const SearchView({super.key, this.initialEntry = SearchEntry.plain});

  /// 从发现页「筛选」钮进来时直接打开筛选 sheet。
  final SearchEntry initialEntry;

  @override
  ConsumerState<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends ConsumerState<SearchView> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  final _SearchFilters _filters = _SearchFilters();

  @override
  void initState() {
    super.initState();
    if (widget.initialEntry == SearchEntry.filters) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openFilters();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 输入防抖 300ms：这才叫「联想」，不是每敲一个字打一次网络。
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(searchProvider.notifier).onQueryChanged(value);
    });
  }

  void _submit(String value) {
    _debounce?.cancel();
    _controller.text = value;
    ref.read(searchProvider.notifier).submit(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final state = ref.watch(searchProvider);
    final results = _filters.narrow(state.results);
    final maxWidth = state.submitted ? 1120.0 : 760.0;
    final sizeClass = Breakpoints.classify(MediaQuery.sizeOf(context).width);
    final hpad = _hpad(sizeClass, maxWidth);
    final bottomPad = AppSpacing.xxl + MediaQuery.paddingOf(context).bottom;

    return Material(
      // 本页是 push 出来的子页，没有 Scaffold；`TextField` 与语义都需要一个
      // Material 祖先（同时装上前景文本样式，避免继承 MaterialApp 的
      // 「缺少 Material 祖先」兜底样式：红字 + 黄色双下划线）。
      type: MaterialType.transparency,
      child: ColoredBox(
        color: colors.background,
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              const SizedBox(height: AppSpacing.md),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: hpad),
                child: Row(
                  children: <Widget>[
                    AppPlainRoundButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      iconSize: 16,
                      semanticLabel: '返回',
                      onPressed: () => context.pop(),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: _buildField(state, colors)),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: hpad),
                child: state.submitted
                    ? _ResultsHead(
                        count: results.length,
                        sortLabel: _SearchFilters.sortLabels[_filters.sort],
                        active: _filters.isActive,
                        summary: _filters.summary(),
                        onSort: _openSortMenu,
                        onFilters: _openFilters,
                      )
                    : _GuideBody(
                        suggestions: state.suggestions,
                        query: state.query,
                        searching: state.searching,
                        recent: state.recentSearches,
                        colors: colors,
                        onFilters: _openFilters,
                        onPick: _submit,
                        onRemoveRecent: _removeRecent,
                        onClearRecent: () =>
                            ref.read(searchProvider.notifier).clearRecent(),
                      ),
              ),
              if (state.submitted)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: hpad),
                  child: _ResultGrid(items: results, innerWidth: _innerWidth),
                ),
              SizedBox(height: bottomPad),
            ],
          ),
        ),
      ),
    );
  }

  double _hpad(WindowSizeClass sizeClass, double maxWidth) {
    final gutter = Breakpoints.gutter(sizeClass);
    final contentWidth =
        MediaQuery.sizeOf(context).width -
        Breakpoints.railPlaceholder(sizeClass);
    return math.max(gutter, (contentWidth - maxWidth) / 2);
  }

  double get _innerWidth {
    final sizeClass = Breakpoints.classify(MediaQuery.sizeOf(context).width);
    final contentWidth =
        MediaQuery.sizeOf(context).width -
        Breakpoints.railPlaceholder(sizeClass);
    return math.min(contentWidth, 1120) - 2 * _hpad(sizeClass, 1120);
  }

  Widget _buildField(SearchState state, AppColors colors) => Container(
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: colors.sunken,
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      children: <Widget>[
        Icon(Icons.search, size: 17, color: colors.textSecondary),
        const SizedBox(width: 9),
        Expanded(
          child: TextField(
            controller: _controller,
            onChanged: _onChanged,
            onSubmitted: _submit,
            textInputAction: TextInputAction.search,
            style: AppText.body.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '搜索剧名、题材',
              hintStyle: AppText.body.copyWith(color: colors.textTertiary),
            ),
          ),
        ),
        if (state.query.isNotEmpty)
          GestureDetector(
            onTap: () {
              _controller.clear();
              ref.read(searchProvider.notifier).clear();
            },
            child: Icon(Icons.close, size: 18, color: colors.textTertiary),
          ),
      ],
    ),
  );

  Future<void> _openSortMenu() async {
    final value = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: AppGlassSurface(
          radius: AppRadii.sheet,
          blur: 26,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (var i = 0; i < _SearchFilters.sortLabels.length; i++)
                    _SheetRow(
                      label: _SearchFilters.sortLabels[i],
                      selected: i == _filters.sort,
                      onTap: () => Navigator.of(sheetContext).pop(i),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (value != null && mounted) setState(() => _filters.sort = value);
  }

  /// 筛选 sheet：题材（多选）/ 状态 / 集数 / 排序 / 内容源。
  Future<void> _openFilters() async {
    // sheet 直接在草稿上改，应用时把草稿覆盖回本状态。
    final draft = _filters.copy();
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _FilterSheet(
        draft: draft,
        currentSource: ref.read(searchProvider).source,
      ),
    );
    if (applied != true || !mounted) return;

    final switchSource =
        draft.source != null && draft.source != ref.read(searchProvider).source;
    setState(() => _filters.overrideWith(draft));
    if (switchSource) {
      await ref.read(searchProvider.notifier).selectSource(draft.source!);
    }
    // 题材选中时用题材词去查（源站的搜索只吃关键词）。
    _submit(
      _filters.tags.isNotEmpty ? _filters.tags.join(' ') : _controller.text,
    );
  }

  void _removeRecent(String word) {
    final current = ref.read(searchProvider).recentSearches;
    ref.read(searchProvider.notifier).setRecent(<String>[
      for (final item in current)
        if (item != word) item,
    ]);
  }
}

/// 「搜索结果」头：标题 + 计数 + 排序菜单 + 筛选钮（可带 Badge）+ 摘要行。
class _ResultsHead extends StatelessWidget {
  const _ResultsHead({
    required this.count,
    required this.sortLabel,
    required this.active,
    required this.summary,
    required this.onSort,
    required this.onFilters,
  });

  final int count;
  final String sortLabel;
  final bool active;
  final String summary;
  final VoidCallback onSort;
  final VoidCallback onFilters;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '搜索结果',
                  style: AppText.body.copyWith(
                    fontSize: 15,
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _SortChip(label: sortLabel, onTap: onSort),
              const SizedBox(width: AppSpacing.sm),
              AppPlainRoundButton(
                icon: Icons.tune_rounded,
                semanticLabel: '筛选',
                showBadge: active,
                onPressed: onFilters,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$count 部剧集',
            style: AppText.mono.copyWith(
              fontSize: 11.5,
              color: colors.textSecondary,
            ),
          ),
          if (active && summary.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              summary,
              style: AppText.caption.copyWith(
                fontSize: 11.5,
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 排序 chip（浅雾底胶囊 + 排序图标）。
class _SortChip extends StatelessWidget {
  const _SortChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: '排序：$label',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: colors.sunken,
            borderRadius: BorderRadius.circular(AppRadii.capsule),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.sort_rounded, size: 14, color: colors.textSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppText.caption.copyWith(
                  fontSize: 12.5,
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 引导态：按条件筛选入口 + 最近搜索（**没有热门趋势**）。
///
/// 输入未提交时改为联想行（首行「搜索『词』」直接提交）。
class _GuideBody extends StatelessWidget {
  const _GuideBody({
    required this.suggestions,
    required this.query,
    required this.searching,
    required this.recent,
    required this.colors,
    required this.onFilters,
    required this.onPick,
    required this.onRemoveRecent,
    required this.onClearRecent,
  });

  final List<String> suggestions;
  final String query;
  final bool searching;
  final List<String> recent;
  final AppColors colors;
  final VoidCallback onFilters;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onRemoveRecent;
  final VoidCallback onClearRecent;

  @override
  Widget build(BuildContext context) {
    final trimmed = query.trim();

    if (trimmed.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: AppSpacing.sm),
          _RecentRow(
            icon: Icons.search_rounded,
            word: '搜索「$trimmed」',
            colors: colors,
            onTap: () => onPick(trimmed),
          ),
          for (final word in suggestions)
            if (word != trimmed)
              _RecentRow(
                icon: Icons.north_west_rounded,
                word: word,
                colors: colors,
                onTap: () => onPick(word),
              ),
          if (searching)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.textTertiary,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: AppSpacing.sm),
        // 「按条件筛选」是引导态的主入口。
        Semantics(
          button: true,
          label: '按条件筛选',
          child: GestureDetector(
            onTap: onFilters,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.sunken,
                borderRadius: BorderRadius.circular(AppRadii.lg),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colors.background,
                      borderRadius: BorderRadius.circular(AppRadii.thumbnail),
                    ),
                    child: Icon(
                      Icons.tune_rounded,
                      size: 17,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '按条件筛选',
                          style: AppText.body.copyWith(
                            fontSize: 14.5,
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '题材、状态、集数与排序',
                          style: AppText.caption.copyWith(
                            fontSize: 11.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: colors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),

        if (recent.isNotEmpty) ...<Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: SectionLabel(text: '最近搜索')),
              GestureDetector(
                onTap: onClearRecent,
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: 22,
                    left: AppSpacing.sm,
                    bottom: 10,
                  ),
                  child: Text(
                    '清空',
                    style: AppText.caption.copyWith(
                      fontSize: 12.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          for (final word in recent)
            _RecentRow(
              icon: Icons.history_rounded,
              word: word,
              colors: colors,
              onTap: () => onPick(word),
              onRemove: () => onRemoveRecent(word),
            ),
        ],
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.icon,
    required this.word,
    required this.colors,
    this.onTap,
    this.onRemove,
  });

  final IconData icon;
  final String word;
  final AppColors colors;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 19, color: colors.textTertiary),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              word,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.body.copyWith(
                fontSize: 14.5,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (onRemove != null)
            GestureDetector(
              onTap: onRemove,
              child: Icon(Icons.close, size: 17, color: colors.textTertiary),
            ),
        ],
      ),
    ),
  );
}

/// 结果网格：**复用发现的密度公式**，视觉语言不换挡。
class _ResultGrid extends StatelessWidget {
  const _ResultGrid({required this.items, required this.innerWidth});

  final List<Drama> items;
  final double innerWidth;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有找到相关剧集',
        description: '换个词，或者用按条件筛选试试。',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: FeedGrid.delegate(innerWidth),
          itemCount: items.length,
          itemBuilder: (context, index) => DramaPosterCard(
            drama: items[index],
            onTap: () => context.push(
              AppRoutes.detail(items[index].id, source: items[index].source),
              extra: items[index],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xl),
          child: Center(
            child: Text(
              '已经看到全部结果',
              style: AppText.caption.copyWith(
                fontSize: 11.5,
                color: AppColors.of(context).textTertiary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 筛选 sheet。
class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({required this.draft, required this.currentSource});

  final _SearchFilters draft;
  final String currentSource;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  static const List<String> tags = <String>[
    '都市',
    '甜宠',
    '霸总',
    '重生',
    '古装',
    '虐恋',
    '爽文',
    '逆袭',
    '穿越',
    '职场',
    '医术',
    '校园',
  ];
  static const List<String> status = <String>['全部', '连载中', '已完结'];
  static const List<String> eps = <String>[
    '全部',
    '30 集以内',
    '30-60 集',
    '60-100 集',
    '100 集以上',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final draft = widget.draft;
    final sources = ref.watch(availableSourcesProvider).value;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: AppGlassSurface(
        radius: AppRadii.sheet,
        blur: 26,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '筛选',
                          style: AppText.headline.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(draft.reset),
                        child: Text(
                          '重置',
                          style: AppText.callout.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _Group(
                    label: '题材（可多选）',
                    children: <Widget>[
                      for (final tag in tags)
                        _Chip(
                          label: tag,
                          selected: draft.tags.contains(tag),
                          onTap: () => setState(() {
                            if (!draft.tags.remove(tag)) draft.tags.add(tag);
                          }),
                        ),
                    ],
                  ),
                  _Group(
                    label: '状态',
                    children: <Widget>[
                      for (var i = 0; i < status.length; i++)
                        _Chip(
                          label: status[i],
                          selected: draft.status == i,
                          onTap: () => setState(() => draft.status = i),
                        ),
                    ],
                  ),
                  _Group(
                    label: '集数',
                    children: <Widget>[
                      for (var i = 0; i < eps.length; i++)
                        _Chip(
                          label: eps[i],
                          selected: draft.eps == i,
                          onTap: () => setState(() => draft.eps = i),
                        ),
                    ],
                  ),
                  _Group(
                    label: '排序',
                    children: <Widget>[
                      for (var i = 0; i < _SearchFilters.sortLabels.length; i++)
                        _Chip(
                          label: _SearchFilters.sortLabels[i],
                          selected: draft.sort == i,
                          onTap: () => setState(() => draft.sort = i),
                        ),
                    ],
                  ),
                  if (sources != null && sources.isNotEmpty)
                    _Group(
                      label: '内容源',
                      children: <Widget>[
                        for (final source in sources)
                          _Chip(
                            label: sourceLabel(source.id),
                            selected:
                                (draft.source ?? widget.currentSource) ==
                                source.id,
                            onTap: () =>
                                setState(() => draft.source = source.id),
                          ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _FootButton(
                          label: '取消',
                          filled: false,
                          onTap: () => Navigator.of(context).pop(false),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: _FootButton(
                          label: '应用筛选',
                          filled: true,
                          onTap: () => Navigator.of(context).pop(true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: AppText.caption.copyWith(
              fontSize: 12,
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: children,
          ),
        ],
      ),
    );
  }
}

/// 筛选 chip：未选中 = 浅雾底石墨字；选中 = 墨色填充 + 反白字。
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: selected ? colors.textPrimary : colors.sunken,
            borderRadius: BorderRadius.circular(AppRadii.capsule),
          ),
          child: Center(
            child: Text(
              label,
              style: AppText.caption.copyWith(
                fontSize: 12.5,
                color: selected ? colors.onInk : colors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FootButton extends StatelessWidget {
  const _FootButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? colors.textPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.capsule),
            border: filled
                ? null
                : Border.all(color: colors.divider, width: .5),
          ),
          child: Text(
            label,
            style: AppText.body.copyWith(
              color: filled ? colors.onInk : colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// sheet 里的一行（排序菜单用）。
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: AppSpacing.minTapTarget,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        alignment: AlignmentDirectional.centerStart,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: AppText.body.copyWith(
                  color: colors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 18, color: colors.textPrimary),
          ],
        ),
      ),
    );
  }
}

/// 搜索页的筛选状态（**视图局部状态**：它只影响结果列表的排列与收窄，
/// 不进仓库——源站的搜索接口只吃关键词）。
class _SearchFilters {
  _SearchFilters();

  /// 排序选项刻意只用能真正兑现的三档：源站的「热度 / 最新」不可得，
  /// 摆出来却不能排序，比没有这个菜单更糟。
  static const List<String> sortLabels = <String>['默认排序', '集数多', '集数少'];

  final Set<String> tags = <String>{};

  /// 0 全部 / 1 连载中 / 2 已完结。
  int status = 0;

  /// 0 全部 / 1 ≤30 / 2 30-60 / 3 60-100 / 4 >100。
  int eps = 0;

  int sort = 0;

  /// 选中的搜索源；null = 沿用当前源。
  String? source;

  bool get isActive => tags.isNotEmpty || status > 0 || eps > 0;

  _SearchFilters copy() => _SearchFilters()
    ..tags.addAll(tags)
    ..status = status
    ..eps = eps
    ..sort = sort
    ..source = source;

  /// 用 sheet 的草稿覆盖本状态。
  void overrideWith(_SearchFilters other) {
    tags
      ..clear()
      ..addAll(other.tags);
    status = other.status;
    eps = other.eps;
    sort = other.sort;
    source = other.source;
  }

  void reset() {
    tags.clear();
    status = 0;
    eps = 0;
    sort = 0;
    source = null;
  }

  /// 一行筛选摘要（有筛选生效时展示在计数下方）。
  String summary() {
    final parts = <String>[
      ...tags,
      if (status > 0) const <String>['', '连载中', '已完结'][status],
      if (eps > 0)
        const <String>['', '30 集以内', '30-60 集', '60-100 集', '100 集以上'][eps],
      sortLabels[sort],
    ];
    return parts.join(' · ');
  }

  /// 客户端收窄：状态与集数可以就地判定。
  List<Drama> narrow(List<Drama> input) {
    Iterable<Drama> out = input;
    if (status == 1) {
      out = out.where((drama) => drama.status == DramaStatus.ongoing);
    } else if (status == 2) {
      out = out.where((drama) => drama.status == DramaStatus.finished);
    }
    if (eps > 0) {
      out = out.where((drama) {
        final count = drama.episodeCount;
        return switch (eps) {
          1 => count > 0 && count <= 30,
          2 => count > 30 && count <= 60,
          3 => count > 60 && count <= 100,
          4 => count > 100,
          _ => true,
        };
      });
    }
    final list = out.toList();
    if (sort == 1) {
      list.sort((a, b) => b.episodeCount.compareTo(a.episodeCount));
    } else if (sort == 2) {
      list.sort((a, b) => a.episodeCount.compareTo(b.episodeCount));
    }
    return list;
  }
}
