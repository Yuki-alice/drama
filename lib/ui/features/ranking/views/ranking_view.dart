import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../data/repositories/catalog_repository.dart';
import '../../../../router/routes.dart';
import '../../../core/errors.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/lockups.dart';
import '../view_models/ranking_view_model.dart';

/// 榜单。
///
/// 与首页的分工：首页负责「逛」，榜单负责「比」。所以这里第一件事是
/// **口径切换**（热度 / 上新 / …），先给口径再给名次；名次用大号等宽数字
/// （数字即视觉），行高压到 64，一屏能读完八条。
class RankingView extends ConsumerWidget {
  const RankingView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedBoard = ref.watch(rankingBoardProvider);
    final dramasAsync = ref.watch(rankingListProvider);
    final boardName =
        RankingBoards.all.firstWhere((board) => board.id == selectedBoard).name;

    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: AppSpacing.pageH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const GlassContentTopInset(extra: AppSpacing.sm),
                PageHead(
                  title: '榜单',
                  trailingText: dramasAsync.value == null
                      ? null
                      : '${dramasAsync.value!.length} 条',
                  actions: <Widget>[
                    GlassIconAction(
                      icon: Icons.search_rounded,
                      semanticLabel: '搜索',
                      onPressed: () => context.push(AppRoutes.search),
                    ),
                  ],
                ),
                // 口径切换：8 个板以内用分段控件，超过走可滚动变体。
                GlassSegmentedControl.scrollable(
                  height: 40,
                  segments: <GlassSegment>[
                    for (final board in RankingBoards.all)
                      GlassSegment(label: board.name, id: board.id),
                  ],
                  selectedIndex: RankingBoards.all.indexWhere(
                    (board) => board.id == selectedBoard,
                  ),
                  onSegmentSelected: (index) => ref
                      .read(rankingBoardProvider.notifier)
                      .select(RankingBoards.all[index].id),
                  useOwnLayer: true,
                  selectedTextStyle: AppText.callout.copyWith(
                    color: AppColors.of(context).textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                  unselectedTextStyle: AppText.callout.copyWith(
                    color: AppColors.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),

        // 口径说明 + 发丝分隔：名次表的语境，不是装饰。
        SliverToBoxAdapter(
          child: Padding(
            padding: AppSpacing.pageH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '$boardName · 每小时更新',
                  style: AppText.mono.copyWith(
                    color: AppColors.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Divider(color: AppColors.of(context).divider, height: 1),
              ],
            ),
          ),
        ),

        dramasAsync.when(
          data: (dramas) => dramas.isEmpty
              ? const SliverToBoxAdapter(
                  child: EmptyView(
                    message: '该榜单暂无剧集',
                    icon: Icons.leaderboard_outlined,
                    hint: '换个口径看看',
                  ),
                )
              : SliverPadding(
                  padding: AppSpacing.pageH,
                  sliver: SliverList.separated(
                    itemCount: dramas.length,
                    separatorBuilder: (context, index) => Divider(
                      color: AppColors.of(context).divider,
                      height: 1,
                    ),
                    itemBuilder: (context, index) {
                      final drama = dramas[index];
                      return Reveal(
                        index: index,
                        child: RankRow(
                          drama: drama,
                          rank: index + 1,
                          onTap: () => context.push(
                            AppRoutes.detail(drama.id, source: drama.source),
                            // 携带卡片数据供详情页立即渲染海报头（Hero 落点）。
                            extra: drama,
                          ),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: AppColors.of(context).textDisabled,
                          ),
                        ),
                      );
                    },
                  ),
                ),
          loading: () => const SliverToBoxAdapter(
            child: LoadingView(label: '正在加载榜单'),
          ),
          error: (error, _) => SliverToBoxAdapter(
            child: ErrorView(
              message: errorMessage(error),
              onRetry: () => ref.invalidate(rankingListProvider),
            ),
          ),
        ),

        const SliverNavBarBottomInset(),
      ],
    );
  }
}
