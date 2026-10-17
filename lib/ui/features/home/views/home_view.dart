import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';
import '../../../../router/routes.dart';
import '../../../core/errors.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_fixed_top_bar.dart';
import '../../../core/widgets/app_glass_surface.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/lockups.dart';
import '../../../core/widgets/source_sheet.dart';
import '../view_models/home_view_model.dart';

/// 发现页：**全屏就是一张竖卡网格**。
///
/// - 固定顶栏（`发现` + 搜索 / 切换源 / 筛选三枚浅雾圆钮），全程不变形；
/// - 纯网格，**无横滑区、无 banner、无分区头条**；
/// - 封面 3:4 不裁切，标题 + 集数叠在封面下缘 scrim 上，卡片无独立文本区；
/// - 未看过的卡左上角题材角标；看过的卡右上角白胶囊「继续看 N」+ 下缘进度线；
/// - 滚过一屏后右下出现返回顶部圆钮。
class HomeView extends ConsumerStatefulWidget {
  const HomeView({super.key});

  @override
  ConsumerState<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends ConsumerState<HomeView> {
  final ScrollController _controller = ScrollController();
  bool _showBackToTop = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    final show = _controller.offset > 600;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
    // 距底部一屏内预取下一页；loadMore 自带去重与在途保护。
    if (_controller.position.extentAfter < 480) {
      ref.read(homeFeedProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(homeFeedProvider);
    final isStale = ref.watch(staleDataNoticeProvider);
    final bottomInset = tabPageBottomInset(context);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        CustomScrollView(
          controller: _controller,
          slivers: <Widget>[
            const SliverFixedTopBarInset(hasSubBar: false),
            if (isStale) const SliverToBoxAdapter(child: StaleNotice()),
            ...feed.when<List<Widget>>(
              data: (value) => _dataSlivers(value),
              loading: () => const <Widget>[
                SliverToBoxAdapter(child: FeedSkeleton()),
              ],
              error: (error, _) => <Widget>[
                SliverToBoxAdapter(
                  child: ErrorView(
                    message: errorMessage(error),
                    onRetry: () => ref.invalidate(homeFeedProvider),
                  ),
                ),
              ],
            ),
            SliverToBoxAdapter(child: SizedBox(height: bottomInset + 26)),
          ],
        ),

        // 固定顶栏：**全程不变形**，内容从它下方滚过。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FixedTopBar(
            title: '发现',
            actions: <Widget>[
              AppPlainRoundButton(
                icon: Icons.search_rounded,
                semanticLabel: '搜索',
                onPressed: () => context.push(AppRoutes.search),
              ),
              AppPlainRoundButton(
                icon: Icons.swap_horiz_rounded,
                semanticLabel: '切换内容源',
                onPressed: () => showSourceSheet(context, ref),
              ),
              AppPlainRoundButton(
                icon: Icons.tune_rounded,
                semanticLabel: '按条件筛选',
                onPressed: () =>
                    context.push(AppRoutes.search, extra: SearchEntry.filters),
              ),
            ],
          ),
        ),

        // 返回顶部：滚过一屏后才出现（浮在内容之上，玻璃成立）。
        PositionedDirectional(
          end: AppSpacing.gutter,
          bottom: bottomInset + 16,
          child: AnimatedOpacity(
            opacity: _showBackToTop ? 1 : 0,
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            child: IgnorePointer(
              ignoring: !_showBackToTop,
              child: AppGlassRoundButton(
                icon: Icons.arrow_upward_rounded,
                visual: 38,
                iconSize: 16,
                semanticLabel: '回到顶部',
                onPressed: () => _controller.animateTo(
                  0,
                  duration: AppMotion.slow,
                  curve: AppMotion.settle,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _dataSlivers(HomeFeed value) {
    if (value.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.movie_filter_outlined,
            title: '这个源暂时没有剧目',
            description: '试试切换其他内容源，或稍后再来。',
            actionLabel: '选择源',
            onAction: () => showSourceSheet(context, ref),
          ),
        ),
      ];
    }

    return <Widget>[
      _FeedGrid(items: value.items),
      // 追加失败**保留**已加载列表，只在尾部给一条可重试行。
      if (value.loadMoreError != null)
        SliverToBoxAdapter(
          child: InlineRetry(
            message: '加载更多失败：${value.loadMoreError}',
            onRetry: () => ref.read(homeFeedProvider.notifier).loadMore(),
          ),
        )
      else if (value.hasMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Center(
              child: value.loadingMore
                  ? const LoadingView(padding: EdgeInsets.zero, label: '正在加载更多')
                  : InkPillSmall(
                      label: '加载更多',
                      onTap: () =>
                          ref.read(homeFeedProvider.notifier).loadMore(),
                    ),
            ),
          ),
        ),
    ];
  }
}

/// 信息流主网格：列数走**连续公式**（`FeedGrid`），手机固定 3 列。
class _FeedGrid extends ConsumerWidget {
  const _FeedGrid({required this.items});

  final List<Drama> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    final sizeClass = Breakpoints.classify(windowWidth);
    final gutter = Breakpoints.gutter(sizeClass);

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        // 网格上限 1120：超出即居中留白（左右各留 (width-1120)/2，但不小于 gutter）。
        final hpad = math.max(gutter, (width - Breakpoints.kGridMaxWidth) / 2);
        final inner = width - hpad * 2;
        return SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: hpad),
          sliver: SliverGrid(
            gridDelegate: FeedGrid.delegate(inner),
            delegate: SliverChildBuilderDelegate(
              (context, index) => DramaPosterCard(
                drama: items[index],
                onTap: () => context.push(
                  AppRoutes.detail(
                    items[index].id,
                    source: items[index].source,
                  ),
                  // 带上卡片数据：详情页在数据到达前先画海报头，Hero 转场才有落点。
                  extra: items[index],
                ),
              ),
              childCount: items.length,
            ),
          ),
        );
      },
    );
  }
}

/// 首屏加载骨架：与真实网格同列数、同形状（加载完成不跳版）。
class FeedSkeleton extends StatefulWidget {
  const FeedSkeleton({super.key});

  @override
  State<FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<FeedSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 减弱动效：不呼吸，静态骨架仍然完成「占位」这个主要功能。
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final windowWidth = MediaQuery.sizeOf(context).width;
    final gutter = Breakpoints.gutter(Breakpoints.classify(windowWidth));

    final grid = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hpad = math.max(gutter, (width - Breakpoints.kGridMaxWidth) / 2);
        final inner = width - hpad * 2;
        return GridView.builder(
          padding: EdgeInsets.symmetric(horizontal: hpad),
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          itemCount: FeedGrid.columns(inner) * 3,
          gridDelegate: FeedGrid.delegate(inner),
          itemBuilder: (context, index) => DecoratedBox(
            decoration: BoxDecoration(
              color: colors.posterFallback,
              borderRadius: BorderRadius.circular(AppRadii.lg),
            ),
          ),
        );
      },
    );

    return Semantics(
      label: '正在加载首页',
      liveRegion: true,
      child: reduce
          ? grid
          : FadeTransition(
              opacity: Tween<double>(begin: .55, end: 1).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              child: grid,
            ),
    );
  }
}
