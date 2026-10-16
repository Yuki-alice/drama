import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';
import '../../../../domain/models/source.dart';
import '../../../../router/routes.dart';
import '../../../core/errors.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/drama_cover.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/glass_top_bar.dart';
import '../view_models/home_view_model.dart';

/// 首页：视频卡片信息流（Kazumi 式）。
///
/// - 顶部是**固定液态玻璃条**（`GlassTopBar`：标题 / 选择源 / 搜索），
///   内容从它下面滚过；
/// - 主体是纯色底上的卡片流：封面 2:3 + 标题两行 + 元信息一行，
///   3–6 列随可用宽度自适应；触底自动续拉下一页。
class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider);
    final isStale = ref.watch(staleDataNoticeProvider);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // ── 信息流本体（从固定顶栏下方穿过） ─────────────────────
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // 距底部一屏内预取下一页；loadMore 自带去重与在途保护。
            if (notification.metrics.extentAfter < 480) {
              ref.read(homeFeedProvider.notifier).loadMore();
            }
            return false;
          },
          child: CustomScrollView(
            slivers: <Widget>[
              const SliverGlassTopBarInset(),
              if (isStale) const SliverToBoxAdapter(child: StaleNotice()),
              ...feed.when<List<Widget>>(
                data: (value) => _dataSlivers(context, ref, value),
                loading: () => const <Widget>[
                  SliverToBoxAdapter(child: _FeedSkeleton()),
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
              const SliverNavBarBottomInset(),
            ],
          ),
        ),

        // ── 固定液态玻璃顶栏（标题 / 选择源 / 搜索） ──────────────
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: GlassTopBar(
            title: '首页',
            // 从左到右：选择源、搜索（搜索贴最右缘）。
            actions: <Widget>[
              GlassIconAction(
                icon: Icons.swap_horiz_rounded,
                semanticLabel: '选择源',
                onPressed: () => _showSourceSheet(context, ref),
              ),
              GlassIconAction(
                icon: Icons.search_rounded,
                semanticLabel: '搜索',
                onPressed: () => context.push(AppRoutes.search),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _dataSlivers(
    BuildContext context,
    WidgetRef ref,
    HomeFeed value,
  ) {
    if (value.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xxl),
            child: EmptyView(
              message: '这个源暂时没有剧目',
              icon: Icons.movie_filter_outlined,
              hint: '试试切换其他内容源',
              action: InkPill(
                label: '选择源',
                onTap: () => _showSourceSheet(context, ref),
              ),
            ),
          ),
        ),
      ];
    }

    return <Widget>[
      _FeedGrid(items: value.items),
      // 追加失败**保留**已加载列表，只在尾部给一条重试行。
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
                  ? const LoadingView(
                      padding: EdgeInsets.zero,
                      label: '正在加载更多',
                    )
                  : OutlinePill(
                      label: '加载更多',
                      icon: Icons.expand_more_rounded,
                      onTap: () =>
                          ref.read(homeFeedProvider.notifier).loadMore(),
                    ),
            ),
          ),
        ),
    ];
  }

  /// 「选择源」：列出有目录能力的源（能力表为空时兜底主源单行）。
  Future<void> _showSourceSheet(BuildContext context, WidgetRef ref) async {
    final current = ref.read(homeSourceProvider);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final colors = AppColors.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: GlassSurfaceCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      '选择内容源',
                      style: AppText.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  Consumer(
                    builder: (context, sheetRef, _) {
                      final sourcesAsync =
                          sheetRef.watch(availableSourcesProvider);
                      return sourcesAsync.when(
                        loading: () => const Padding(
                          padding: EdgeInsets.all(AppSpacing.xl),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (error, _) => _sourceChoices(
                            context, sheetRef, current, const []),
                        data: (sources) {
                          // 有目录能力的源才是可浏览的源；表非空但不含任何
                          // 目录源时不过滤（宁可多列，也不凭空隐藏）。
                          final browsable = sources
                              .where((source) => source.caps.catalog)
                              .toList();
                          return _sourceChoices(
                            context,
                            sheetRef,
                            current,
                            browsable.isEmpty ? sources : browsable,
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sourceChoices(
    BuildContext context,
    WidgetRef sheetRef,
    String current,
    List<SourceInfo> sources,
  ) {
    if (sources.isEmpty) {
      // 核心不可用 / 未声明任何源：兜底主源单行，不静默造源。
      return _SheetChoice(label: '红果（默认）', selected: true, onTap: () {});
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final source in sources)
          _SheetChoice(
            label: _sourceLabel(source.id),
            selected: source.id == current,
            onTap: () {
              sheetRef.read(homeSourceProvider.notifier).select(source.id);
              Navigator.of(context).pop();
            },
          ),
      ],
    );
  }
}

String _sourceLabel(String id) => switch (id) {
      'hongguo' => '红果（默认）',
      'huangguoai' => '黄果 AI',
      _ => id,
    };

/// 信息流卡片：封面 2:3 + 标题（至多两行）+ 元信息一行。
class _FeedCard extends StatelessWidget {
  const _FeedCard({required this.drama, required this.onTap});

  final Drama drama;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final meta = drama.episodeCount > 0
        ? '${drama.status.label} · 共 ${drama.episodeCount} 集'
        : drama.status.label;

    return PressableScale(
      scale: .96,
      borderRadius: AppRadii.md,
      onTap: onTap,
      semanticLabel: '${drama.title}，$meta',
      semanticHint: '双击查看详情',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 2 / 3,
            child: CoverHero(
              source: drama.source,
              id: drama.id,
              child: DramaCover(
                seed: drama.coverSeed,
                cover: drama.cover,
                title: drama.title,
                radius: AppRadii.md,
                showTitleOverlay: false,
                fill: true,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.callout.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 元信息用 textSecondary：集数/状态是用户真的会读的信息。
            style: AppText.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 信息流主网格：列数与单格高度由可用宽度推导（手机 3 列，随宽递增到 6 列；
/// 单格高度 = 封面 2:3 + 文本区）。
class _FeedGrid extends StatelessWidget {
  const _FeedGrid({required this.items});

  final List<Drama> items;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) => SliverPadding(
        padding: AppSpacing.pageH,
        sliver: SliverGrid(
          gridDelegate: _feedDelegate(context, constraints.crossAxisExtent),
          delegate: SliverChildBuilderDelegate((context, index) {
            final drama = items[index];
            return _FeedCard(
              drama: drama,
              onTap: () => context.push(
                AppRoutes.detail(drama.id, source: drama.source),
                // 带上卡片数据：详情页在数据到达前就能先画出海报头，
                // Hero 转场才有落点（深链进入时为 null，正常降级加载）。
                extra: drama,
              ),
            );
          }, childCount: items.length),
        ),
      ),
    );
  }
}

/// 信息流的列数与单格高度：`extent = 封面(2:3 高) + 文本区`。
SliverGridDelegate _feedDelegate(BuildContext context, double width) {
  final columns = switch (width) {
    >= 1080 => 6,
    >= 840 => 5,
    >= 600 => 4,
    _ => 3,
  };
  const gap = AppSpacing.md;
  final itemWidth =
      (width - AppSpacing.gutter * 2 - gap * (columns - 1)) / columns;
  final textScaler = MediaQuery.textScalerOf(context);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: gap,
    crossAxisSpacing: gap,
    mainAxisExtent: itemWidth * 1.5 + textScaler.scale(54) + 12,
  );
}

/// 首屏加载骨架：与真实网格同列数、同形状（加载完成不跳版）。
///
/// 是**盒子版**（放在 `SliverToBoxAdapter` 里）：`Semantics` 会引入
/// RenderBox 语义节点，不能直接坐在 sliver 列表里。
class _FeedSkeleton extends StatefulWidget {
  const _FeedSkeleton();

  @override
  State<_FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<_FeedSkeleton>
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

    Widget bar({required double width}) => Container(
          height: 11,
          width: width,
          decoration: BoxDecoration(
            color: colors.posterFallback,
            borderRadius: BorderRadius.circular(AppRadii.xs),
          ),
        );

    Widget tile() => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 2 / 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.posterFallback,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            bar(width: 92),
            const SizedBox(height: 6),
            bar(width: 56),
          ],
        );

    final grid = LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        padding: AppSpacing.pageH,
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        itemCount: 9,
        gridDelegate: _feedDelegate(context, constraints.maxWidth),
        itemBuilder: (context, index) => tile(),
      ),
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

/// sheet 内的一行选项（**内容层**行，不是玻璃控件——玻璃不嵌套）。
class _SheetChoice extends StatelessWidget {
  const _SheetChoice({
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
    return PressableScale(
      scale: .98,
      onTap: onTap,
      borderRadius: AppRadii.md,
      semanticLabel: label,
      child: Container(
        height: AppSpacing.minTapTarget,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        alignment: AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: selected ? colors.accentSubtle : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
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
