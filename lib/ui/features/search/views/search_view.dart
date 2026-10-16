import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../domain/models/drama.dart';
import '../../../../router/routes.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/drama_cover.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/glass_top_bar.dart';
import '../../../core/widgets/lockups.dart';
import '../../ranking/view_models/ranking_view_model.dart';
import '../view_models/search_view_model.dart';

/// 搜索范围（结果过滤口径，客户端本地过滤）。
enum _Scope {
  all('全部'),
  ongoing('连载中'),
  finished('完结');

  const _Scope(this.label);

  final String label;

  bool matches(Drama drama) => switch (this) {
        _Scope.all => true,
        _Scope.ongoing => drama.status == DramaStatus.ongoing,
        _Scope.finished => drama.status == DramaStatus.finished,
      };
}

/// 页面模式：引导 / 输入中（联想）/ 结果。
enum _Mode { guide, suggesting, results }

/// 搜索页（布局对齐 Kazumi `search_page.dart`，材质换液态玻璃）。
///
/// 三段结构：
/// 1. **固定玻璃顶栏**：返回圆钮 + 标题 + 常驻玻璃搜索框（`GlassSearchBar`
///    自带玻璃质感与清除钮；框与栏体同在一次毛玻璃罩里，不构成玻璃套玻璃）；
/// 2. **引导态**（未提交查询）：最近搜索（Kazumi 的「管理/清空」列表行）
///    + 热门趋势（榜单缓存，命中零网络）；
/// 3. **结果态**：「搜索结果」头（计数 + 范围菜单）+ Kazumi 网格公式
///    （列数 = ⌊宽/180⌋、封面 0.7、标题两行、元信息行）+ 底部状态行。
///
/// 输入未提交时显示**联想行**（原设计的「猜你想搜」在空查询下永远是空态，
/// 联想词只有输入中才存在——所以它属于这一段而不是引导态）。
class SearchView extends ConsumerStatefulWidget {
  const SearchView({super.key});

  @override
  ConsumerState<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends ConsumerState<SearchView> {
  /// 输入防抖时长（300ms）。
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  /// 顶栏内搜索槽高度：40 框 + 8 底距。与顶栏 `bottom` 实测一致。
  static const double _searchSlotHeight = 48;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  _Scope _scope = _Scope.all;
  bool _managingRecent = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
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
    _focus.unfocus();
    unawaited(ref.read(searchProvider.notifier).submit(keyword));
  }

  _Mode _modeOf(SearchState state) {
    if (state.query.trim().isEmpty) return _Mode.guide;
    return state.submitted ? _Mode.results : _Mode.suggesting;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final colors = AppColors.of(context);
    final mode = _modeOf(state);

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // ── 滚动内容（从固定顶栏下方穿过） ───────────────────────
          LayoutBuilder(
            builder: (context, constraints) {
              // 内容宽度与 Kazumi 同式：引导 760、结果 1120，居中收边。
              final horizontal = constraints.maxWidth >= 700 ? 32.0 : 20.0;
              final contentWidth = math.min(
                mode == _Mode.guide ? 760.0 : 1120.0,
                constraints.maxWidth - horizontal * 2,
              );
              final inset = (constraints.maxWidth - contentWidth) / 2;
              return CustomScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: <Widget>[
                  const SliverGlassTopBarInset(
                    bottomHeight: _searchSlotHeight,
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 0, inset, 24),
                    sliver: SliverMainAxisGroup(
                      slivers: _sliversFor(state, mode),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height:
                          MediaQuery.paddingOf(context).bottom + AppSpacing.xxl,
                    ),
                  ),
                ],
              );
            },
          ),

          // ── 固定液态玻璃顶栏（返回 + 标题 + 搜索框槽） ────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: '搜索',
              leading: GlassIconAction(
                icon: Icons.chevron_left_rounded,
                semanticLabel: '返回',
                onPressed: () => context.pop(),
              ),
              bottom: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.gutter,
                  0,
                  AppSpacing.gutter,
                  AppSpacing.sm,
                ),
                child: GlassSearchBar(
                  controller: _controller,
                  focusNode: _focus,
                  placeholder: '剧名、题材',
                  autofocus: true,
                  useOwnLayer: true,
                  height: 40,
                  onChanged: _onChanged,
                  onSubmitted: _fillAndSubmit,
                  textStyle: AppText.body.copyWith(color: colors.textPrimary),
                  placeholderStyle: AppText.body.copyWith(
                    color: colors.textSecondary,
                  ),
                  clearButtonSemanticLabel: '清空',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sliversFor(SearchState state, _Mode mode) => switch (mode) {
        _Mode.guide => _guideSlivers(state),
        _Mode.suggesting => _suggestingSlivers(state),
        _Mode.results => _resultSlivers(state),
      };

  // ── 引导态 ──────────────────────────────────────────────────────

  List<Widget> _guideSlivers(SearchState state) {
    final recent = state.recentSearches;
    return <Widget>[
      if (recent.isNotEmpty) ...<Widget>[
        SliverToBoxAdapter(
          child: _RecentHeader(
            managing: _managingRecent,
            onToggleManage: () =>
                setState(() => _managingRecent = !_managingRecent),
            onClearAll: () => ref.read(searchProvider.notifier).clearRecent(),
          ),
        ),
        SliverList.separated(
          itemCount: recent.length,
          itemBuilder: (context, index) => _RecentRow(
            keyword: recent[index],
            managing: _managingRecent,
            onTap: () => _fillAndSubmit(recent[index]),
            onDelete: () => _deleteRecent(recent[index]),
          ),
          separatorBuilder: (context, index) =>
              const SizedBox(height: AppSpacing.xs),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
      ],
      SliverToBoxAdapter(
        child: SectionHead(
          title: '热门趋势',
          subtitle: '此刻最多人在看',
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        ),
      ),
      // 盒子组件：必须包进 SliverToBoxAdapter 才能进 sliver 列表
      // （`SliverMainAxisGroup` 只接受 RenderSliver 子节点）。
      SliverToBoxAdapter(child: _HotList(onPick: _fillAndSubmit)),
    ];
  }

  /// 删一条最近搜索（notifier 无单删入口，本地过滤后回写整表）。
  ///
  /// 词表上限 8 条且纯内存：重建整表比给 notifier 加一个单删方法便宜。
  void _deleteRecent(String keyword) {
    final next = ref
        .read(searchProvider)
        .recentSearches
        .where((item) => item != keyword)
        .toList(growable: false);
    ref.read(searchProvider.notifier).setRecent(next);
  }

  // ── 输入中（联想） ──────────────────────────────────────────────

  List<Widget> _suggestingSlivers(SearchState state) {
    final query = state.query.trim();
    return <Widget>[
      if (state.searching)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: LoadingView(
              padding: EdgeInsets.zero,
              label: '正在联想',
            ),
          ),
        )
      else ...<Widget>[
        SliverToBoxAdapter(
          child: _SuggestionRow(
            text: '搜索「$query」',
            onTap: () => _fillAndSubmit(query),
            strong: true,
          ),
        ),
        for (final suggestion in state.suggestions)
          SliverToBoxAdapter(
            child: _SuggestionRow(
              text: suggestion,
              onTap: () => _fillAndSubmit(suggestion),
            ),
          ),
        if (state.suggestions.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.lg),
              child: Text(
                '输入剧名或题材，回车开始搜索',
                style: AppText.callout.copyWith(
                  color: AppColors.of(context).textTertiary,
                ),
              ),
            ),
          ),
      ],
    ];
  }

  // ── 结果态 ──────────────────────────────────────────────────────

  List<Widget> _resultSlivers(SearchState state) {
    final colors = AppColors.of(context);
    final results = state.results.where(_scope.matches).toList();
    final hidden = state.results.length - results.length;

    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '搜索结果',
                      style: AppText.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  _ScopeMenu(
                    value: _scope,
                    onChanged: (scope) => setState(() => _scope = scope),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                state.searching
                    ? '正在搜索…'
                    : '${results.length} 部匹配「${state.query}」'
                        '${hidden > 0 ? ' · 范围过滤 $hidden 部' : ''}',
                style: AppText.mono.copyWith(
                  fontSize: 11.5,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
      if (state.searching)
        const SliverToBoxAdapter(
          child: LoadingView(label: '正在搜索'),
        )
      else if (results.isEmpty)
        SliverToBoxAdapter(
          child: EmptyView(
            message: '没有匹配「${state.query}」的剧目',
            icon: Icons.search_off_rounded,
            hint: _scope == _Scope.all ? '换个说法试试' : '试试切到「全部」范围',
            action: _scope == _Scope.all
                ? null
                : OutlinePill(
                    label: '查看全部范围',
                    onTap: () => setState(() => _scope = _Scope.all),
                  ),
          ),
        )
      else
        _ResultGrid(
          dramas: results,
          query: state.query,
          onTap: (drama) => context.push(
            AppRoutes.detail(drama.id, source: drama.source),
            // 携带卡片数据供详情页立即渲染海报头（Hero 落点）。
            extra: drama,
          ),
        ),
      if (!state.searching && results.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
            child: Center(
              child: Text(
                '已显示全部 ${results.length} 部',
                style: AppText.caption.copyWith(color: colors.textTertiary),
              ),
            ),
          ),
        ),
    ];
  }
}

/// 最近搜索区头：标题 + 清空（管理态）/ 管理·完成。
class _RecentHeader extends StatelessWidget {
  const _RecentHeader({
    required this.managing,
    required this.onToggleManage,
    required this.onClearAll,
  });

  final bool managing;
  final VoidCallback onToggleManage;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '最近搜索',
              style: AppText.title.copyWith(color: colors.textPrimary),
            ),
          ),
          if (managing) ...<Widget>[
            _LinkText(label: '清空', onTap: onClearAll),
            const SizedBox(width: AppSpacing.md),
          ],
          _LinkText(label: managing ? '完成' : '管理', onTap: onToggleManage),
        ],
      ),
    );
  }
}

/// 最近搜索行（Kazumi ListTile 版式）：历史图标 + 词 + 右上箭头（管理态为删除）。
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.keyword,
    required this.managing,
    required this.onTap,
    required this.onDelete,
  });

  final String keyword;
  final bool managing;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: SizedBox(
          height: AppSpacing.minTapTarget,
          child: Row(
            children: <Widget>[
              Icon(
                Icons.history_rounded,
                size: 22,
                color: colors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(color: colors.textPrimary),
                ),
              ),
              if (managing)
                IconButton(
                  tooltip: '删除这条搜索记录',
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 20),
                )
              else
                Icon(
                  Icons.north_west_rounded,
                  size: 18,
                  color: colors.textTertiary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 联想行：搜索图标 + 词（首行为直接提交当前输入）。
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.text,
    required this.onTap,
    this.strong = false,
  });

  final String text;
  final VoidCallback onTap;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: SizedBox(
          height: AppSpacing.minTapTarget,
          child: Row(
            children: <Widget>[
              Icon(
                strong ? Icons.search_rounded : Icons.north_east_rounded,
                size: 20,
                color: strong ? colors.accentDeep : colors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 热门趋势：前 6 条榜单（缓存命中零网络）。
class _HotList extends ConsumerWidget {
  const _HotList({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final ranking = ref.watch(rankingListProvider);
    return ranking.when(
      data: (dramas) => Column(
        children: <Widget>[
          for (var i = 0; i < dramas.length && i < 6; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Reveal(
                index: i,
                child: RankRow(
                  drama: dramas[i],
                  rank: i + 1,
                  onTap: () => onPick(dramas[i].title),
                ),
              ),
            ),
        ],
      ),
      loading: () => const LoadingView(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        label: '正在加载热门',
      ),
      // 趋势是增强项：失败就不显示，不打断搜索主功能。
      error: (_, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Text(
          '热门趋势暂不可用',
          style: AppText.callout.copyWith(color: colors.textTertiary),
        ),
      ),
    );
  }
}

/// 结果头右侧的范围菜单（Kazumi 排序菜单的位置）。
class _ScopeMenu extends StatelessWidget {
  const _ScopeMenu({required this.value, required this.onChanged});

  final _Scope value;
  final ValueChanged<_Scope> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return PopupMenuButton<_Scope>(
      tooltip: '筛选范围',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => <PopupMenuEntry<_Scope>>[
        for (final scope in _Scope.values)
          CheckedPopupMenuItem<_Scope>(
            value: scope,
            checked: scope == value,
            child: Text(scope.label),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              value.label,
              style: AppText.callout.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(width: AppSpacing.xs),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索结果网格（Kazumi `_SearchResultGrid` 的公式）。
///
/// 列数 = max(2, ⌊可用宽/180⌋)；单格高度 = 封面(0.7) + 标题(实测两行)
/// + 元信息(实测) + 三处间距。标题/元信息高度按当前 textScaler 实测，
/// 大字模式（1.3×）下不裁字、不跳版。
class _ResultGrid extends StatelessWidget {
  const _ResultGrid({
    required this.dramas,
    required this.query,
    required this.onTap,
  });

  final List<Drama> dramas;
  final String query;
  final ValueChanged<Drama> onTap;

  static const double _coverAspectRatio = 0.7;
  static const double _titleSpacing = 10;
  static const double _metadataSpacing = 4;
  static const double _footerGap = 6;
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final titleStyle = AppText.body.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w600,
      height: 1.4,
    );
    final metaStyle = AppText.mono.copyWith(
      fontSize: 11.5,
      color: colors.textSecondary,
    );

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final columns = math.max(2, (width / 180).floor());
        final cardWidth = (width - (columns - 1) * _gap) / columns;
        final titleHeight = _measuredHeight(
          context,
          '剧目\n剧目',
          titleStyle,
        );
        final metadataHeight = math.max(
          14,
          _measuredHeight(context, '已完结 · 0000 集', metaStyle),
        );

        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _gap,
            mainAxisSpacing: 20,
            mainAxisExtent: cardWidth / _coverAspectRatio +
                titleHeight +
                metadataHeight +
                _titleSpacing +
                _metadataSpacing +
                _footerGap,
          ),
          itemCount: dramas.length,
          itemBuilder: (context, index) => _ResultCard(
            drama: dramas[index],
            query: query,
            titleHeight: titleHeight,
            titleStyle: titleStyle,
            metaStyle: metaStyle,
            onTap: () => onTap(dramas[index]),
          ),
        );
      },
    );
  }
}

/// 结果卡：封面 0.7 + 标题两行 + 元信息行。
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.drama,
    required this.query,
    required this.titleHeight,
    required this.titleStyle,
    required this.metaStyle,
    required this.onTap,
  });

  final Drama drama;
  final String query;
  final double titleHeight;
  final TextStyle titleStyle;
  final TextStyle metaStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      drama.status.label,
      if (drama.episodeCount > 0) '${drama.episodeCount} 集',
    ].join(' · ');

    return PressableScale(
      scale: .96,
      borderRadius: AppRadii.lg,
      onTap: onTap,
      semanticLabel: '${drama.title}，$meta',
      semanticHint: '双击查看详情',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: _ResultGrid._coverAspectRatio,
            child: CoverHero(
              source: drama.source,
              id: drama.id,
              child: DramaCover(
                seed: drama.coverSeed,
                cover: drama.cover,
                title: drama.title,
                radius: AppRadii.lg,
                showTitleOverlay: false,
                fill: true,
              ),
            ),
          ),
          const SizedBox(height: _ResultGrid._titleSpacing),
          SizedBox(
            height: titleHeight,
            child: Text.rich(
              _highlight(drama.title, query, titleStyle),
              style: titleStyle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: _ResultGrid._metadataSpacing),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: metaStyle,
          ),
        ],
      ),
    );
  }
}

/// 小号绿色链接文字（行内动作，非玻璃控件）。
class _LinkText extends StatelessWidget {
  const _LinkText({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return PressableScale(
      scale: .94,
      onTap: onTap,
      semanticLabel: label,
      child: SizedBox(
        height: AppSpacing.minTapTarget,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Align(
            alignment: AlignmentDirectional.center,
            child: Text(
              label,
              style: AppText.callout.copyWith(
                color: colors.accentDeep,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 按 textScaler 实测文字高度（Kazumi 同款做法：大字模式不跳版）。
double _measuredHeight(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
  )..layout();
  final height = painter.height.ceilToDouble();
  painter.dispose();
  return height;
}

/// 把命中的那段字加粗 + 加下划线（不用颜色标记命中，见 lockups 同款注释）。
InlineSpan _highlight(String text, String query, TextStyle style) {
  final index = text.toLowerCase().indexOf(query.toLowerCase());
  if (index < 0 || query.isEmpty) {
    return TextSpan(text: text, style: style);
  }
  return TextSpan(
    style: style,
    children: <InlineSpan>[
      TextSpan(text: text.substring(0, index)),
      TextSpan(
        text: text.substring(index, index + query.length),
        style: style.copyWith(
          fontWeight: FontWeight.w800,
          decoration: TextDecoration.underline,
          decorationThickness: 2,
        ),
      ),
      TextSpan(text: text.substring(index + query.length)),
    ],
  );
}
