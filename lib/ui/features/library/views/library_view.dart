import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../domain/models/drama.dart';
import '../../../../router/routes.dart';
import '../../../core/errors.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_fixed_top_bar.dart';
import '../../../core/widgets/app_glass_surface.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/lockups.dart';
import '../view_models/library_view_model.dart';

/// 追剧：**进度是主角**。
///
/// - 固定顶栏（`追剧` + 管理钮）+ **常驻副行**分段控件（带计数）；
/// - 三种态**各自有空态**：图标 + 一句说明 + 「去发现页逛逛」出口，不留白屏；
/// - 进度线 2px 墨色，贴剧名下方——全页唯一的「重量」；
/// - 右侧胶囊按状态换字：在追=「继续看」，看完=「重看」；
/// - 限宽 760 居中。
class LibraryView extends ConsumerWidget {
  const LibraryView({super.key});

  static const List<String> _labels = <String>['在看', '已看完', '全部'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedTab = ref.watch(libraryTabProvider);
    final itemsAsync = ref.watch(visibleLibraryItemsProvider);
    final allAsync = ref.watch(libraryItemsProvider);
    final all = allAsync.value ?? const <LibraryItem>[];

    final counts = <int>[
      all.where((item) => item.isWatching).length,
      all.where((item) => item.isFinished).length,
      all.length,
    ];

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        CustomScrollView(
          slivers: <Widget>[
            const SliverFixedTopBarInset(hasSubBar: true),
            itemsAsync.when(
              data: (items) => items.isEmpty
                  ? SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.favorite_border,
                        title: switch (selectedTab) {
                          LibraryTab.finished => '还没有看完的剧',
                          LibraryTab.all => '追剧库还是空的',
                          LibraryTab.watching => '还没有在追的剧',
                        },
                        description:
                            '在发现页点开任意一部，看过的剧会自动出现在这里，'
                            '进度也会记下来。',
                        actionLabel: '去发现页逛逛',
                        onAction: () => context.go(AppRoutes.home),
                      ),
                    )
                  : SliverPadding(
                      padding: _hpad(context),
                      sliver: SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return Reveal(
                            index: index,
                            child: FollowRow(
                              title: item.title,
                              id: item.id,
                              source: item.source,
                              seed: item.id,
                              cover: item.cover,
                              statusLine: _statusLine(item),
                              progress: item.progress,
                              actionLabel: item.isFinished ? '重看' : '继续看',
                              onTap: () => context.push(
                                AppRoutes.detail(item.id, source: item.source),
                                // 携带一份最小 Drama：详情页在数据到达前就能先画出
                                // 海报头，Hero 转场才有落点（深链进入时为 null）。
                                extra: Drama(
                                  id: item.id,
                                  source: item.source,
                                  title: item.title,
                                  cover: item.cover,
                                  categoryId: '',
                                  categoryName: '',
                                  episodeCount: item.totalEpisode,
                                ),
                              ),
                              onPlay: () => context.push(
                                AppRoutes.player(
                                  item.id,
                                  episode: item.watchedEpisode <= 0
                                      ? null
                                      : item.watchedEpisode,
                                  source: item.source,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
              loading: () => const SliverToBoxAdapter(
                child: LoadingView(label: '正在加载追剧列表'),
              ),
              error: (error, _) => SliverToBoxAdapter(
                child: ErrorView(
                  message: errorMessage(error),
                  onRetry: () => ref.invalidate(libraryItemsProvider),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: tabPageBottomInset(context) + 30),
            ),
          ],
        ),

        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FixedTopBar(
            title: '追剧',
            actions: <Widget>[
              AppPlainRoundButton(
                icon: Icons.more_horiz_rounded,
                semanticLabel: '追剧管理',
                onPressed: () => _showManageSheet(context),
              ),
            ],
            subBar: SegmentedBar(
              labels: _labels,
              counts: counts,
              selectedIndex: selectedTab.index,
              onSelected: (index) => ref
                  .read(libraryTabProvider.notifier)
                  .select(LibraryTab.values[index]),
            ),
          ),
        ),
      ],
    );
  }

  /// 状态行：明确区分「加追了但没开看」与「看到第几集」。
  static String _statusLine(LibraryItem item) {
    if (item.isFinished) {
      return '已看完 ${item.totalEpisode} 集';
    }
    if (item.isPlanned) {
      return item.totalEpisode > 0 ? '还没开始 · 共 ${item.totalEpisode} 集' : '还没开始';
    }
    if (item.totalEpisode > 0) {
      final next = math.min(item.totalEpisode, item.watchedEpisode + 4);
      return '看到 ${item.watchedEpisode} 集 · 更新至 $next 集';
    }
    return '看到 ${item.watchedEpisode} 集';
  }

  /// 管理：分档说明 + 跳转下载管理（低频动作收进 sheet，不占首屏）。
  Future<void> _showManageSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
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
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '追剧管理',
                    style: AppText.headline.copyWith(
                      color: AppColors.of(sheetContext).textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '「在看 / 已看完 / 全部」是三种不同意图。「在看」只表示还有未看的'
                    '集数；源站是否新更新了集数需要重新拉取详情，离线无法判定。',
                    style: AppText.callout.copyWith(
                      color: AppColors.of(sheetContext).textSecondary,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: InkPill(
                      label: '下载管理',
                      icon: Icons.download_outlined,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        context.push(AppRoutes.downloads);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表类内容的居中留白（限宽 760）。
EdgeInsets _hpad(BuildContext context) {
  final windowWidth = MediaQuery.sizeOf(context).width;
  final sizeClass = Breakpoints.classify(windowWidth);
  final gutter = Breakpoints.gutter(sizeClass);
  final contentWidth = windowWidth - Breakpoints.railPlaceholder(sizeClass);
  final pad = math.max(gutter, (contentWidth - 760) / 2);
  return EdgeInsets.symmetric(horizontal: pad);
}
