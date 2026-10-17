import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/repositories/catalog_repository.dart';
import '../../../../router/routes.dart';
import '../../../core/errors.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_fixed_top_bar.dart';
import '../../../core/widgets/app_glass_surface.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/lockups.dart';
import '../../../core/widgets/source_sheet.dart';
import '../view_models/ranking_view_model.dart';

/// 榜单：**数字即视觉**。
///
/// - 固定顶栏（`榜单` + 切换源 / 筛选两枚圆钮）+ **常驻副行**（日/周/月用
///   文字标签的选中态，不是分段控件：榜单的主角是名次，维度切换不该比它更重）；
/// - **限宽 760 居中**，否则宽屏上剧名贴左、热度贴右，中间空一大片；
/// - 序号大号等宽粗体，前三名墨黑、其余银灰；行间只 0.5px 发丝线；
/// - 底部留白加厚（浮起的 Tab 条是浮起的，不留白会把最后一行压住）。
class RankingView extends ConsumerWidget {
  const RankingView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedBoard = ref.watch(rankingBoardProvider);
    final dramasAsync = ref.watch(rankingListProvider);
    final boardIndex = RankingBoards.all.indexWhere(
      (board) => board.id == selectedBoard,
    );
    final boardName = RankingBoards.all[boardIndex < 0 ? 0 : boardIndex].name;
    final count = dramasAsync.value?.length;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        CustomScrollView(
          slivers: <Widget>[
            const SliverFixedTopBarInset(hasSubBar: true),

            // 口径说明（名次表的语境，不是装饰）。
            SliverToBoxAdapter(
              child: Padding(
                padding: _hpad(context).copyWith(top: 2, bottom: 10),
                child: Text(
                  count == null ? boardName : '$boardName · 共 $count 部',
                  style: AppText.mono.copyWith(
                    fontSize: 12.5,
                    color: AppColors.of(context).textSecondary,
                  ),
                ),
              ),
            ),

            dramasAsync.when(
              data: (dramas) => dramas.isEmpty
                  ? const SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.leaderboard_outlined,
                        title: '该榜单暂无剧集',
                        description: '换个口径，或者回到发现页看看。',
                      ),
                    )
                  : SliverPadding(
                      padding: _hpad(context),
                      sliver: SliverList.builder(
                        itemCount: dramas.length,
                        itemBuilder: (context, index) {
                          final drama = dramas[index];
                          return Reveal(
                            index: index,
                            child: RankRow(
                              drama: drama,
                              rank: index + 1,
                              onTap: () => context.push(
                                AppRoutes.detail(
                                  drama.id,
                                  source: drama.source,
                                ),
                                // 携带卡片数据供详情页立即渲染海报头（Hero 落点）。
                                extra: drama,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
              loading: () =>
                  const SliverToBoxAdapter(child: LoadingView(label: '正在加载榜单')),
              error: (error, _) => SliverToBoxAdapter(
                child: ErrorView(
                  message: errorMessage(error),
                  onRetry: () => ref.invalidate(rankingListProvider),
                ),
              ),
            ),

            SliverToBoxAdapter(
              child: SizedBox(height: tabPageBottomInset(context) + 34),
            ),
          ],
        ),

        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FixedTopBar(
            title: '榜单',
            actions: <Widget>[
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
            subBar: TextTabsBar(
              labels: <String>[
                for (final board in RankingBoards.all) board.name,
              ],
              selectedIndex: boardIndex < 0 ? 0 : boardIndex,
              onSelected: (index) => ref
                  .read(rankingBoardProvider.notifier)
                  .select(RankingBoards.all[index].id),
            ),
          ),
        ),
      ],
    );
  }
}

/// 列表类内容的居中留白（限宽 760）。宽屏上必须限宽，否则一行会被拉散。
EdgeInsets _hpad(BuildContext context) {
  final windowWidth = MediaQuery.sizeOf(context).width;
  final gutter = Breakpoints.gutter(Breakpoints.classify(windowWidth));
  // 用 LayoutBuilder 拿不到 sliver 的宽度，这里按窗口宽推导：
  // 内容区 = 窗口宽 − 侧栏占位，再被 760 封顶。
  final sizeClass = Breakpoints.classify(windowWidth);
  final contentWidth = windowWidth - Breakpoints.railPlaceholder(sizeClass);
  final pad = math.max(gutter, (contentWidth - 760) / 2);
  return EdgeInsets.symmetric(horizontal: pad);
}
