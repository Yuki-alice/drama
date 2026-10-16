import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../domain/models/drama.dart';
import '../../../../router/routes.dart';
import '../../../core/errors.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/lockups.dart';
import '../view_models/library_view_model.dart';

/// 追剧。
///
/// 分档的思路值得保留：「想看 / 在看 / 已看 / 有更新」四种意图混在一个
/// 列表里就只是一坨历史记录；分开之后每个桶都有自己的空态文案与排序逻辑。
///
/// 每行是**墨色发丝进度线 + 更新徽章 + 「继续看」黑胶囊**的形状
/// （与榜单行的区别就在这条进度：短剧的核心痛点是「上次看到哪了」）。
class LibraryView extends ConsumerWidget {
  const LibraryView({super.key});

  static const List<String> _tabs = <String>['想看', '在看', '已看', '有更新'];

  /// 各档位的空态文案（分档后为空的含义不同，不共用一句话）。
  static const List<String> _emptyMessages = <String>[
    '还没有加入追剧的剧集',
    '没有正在观看的剧集',
    '还没有看完的剧集',
    '没有未看完的剧集',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final selectedTab = ref.watch(libraryTabProvider);
    final itemsAsync = ref.watch(visibleLibraryItemsProvider);
    final allAsync = ref.watch(libraryItemsProvider);

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
                  title: '追剧',
                  trailingText: allAsync.value == null
                      ? null
                      : '共 ${allAsync.value!.length} 部',
                  actions: <Widget>[
                    GlassIconAction(
                      icon: Icons.tune_rounded,
                      semanticLabel: '追剧管理',
                      onPressed: () => _showManageSheet(context, ref),
                    ),
                  ],
                ),
                // 分档：4 档以内用分段控件（浅雾底 + 白色滑块）。
                GlassSegmentedControl(
                  height: 36,
                  segments: <GlassSegment>[
                    for (final tab in _tabs) GlassSegment(label: tab, id: tab),
                  ],
                  selectedIndex: selectedTab,
                  onSegmentSelected: (index) =>
                      ref.read(libraryTabProvider.notifier).select(index),
                  useOwnLayer: true,
                  // 滑块用白色镜片 + 墨色加粗字，与底部导航的选中态同一逻辑。
                  indicatorColor: colors.contentSurface,
                  selectedTextStyle: AppText.callout.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                  unselectedTextStyle: AppText.callout.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
        itemsAsync.when(
          data: (items) => items.isEmpty
              ? SliverToBoxAdapter(
                  child: EmptyView(
                    message: _emptyMessages[selectedTab.clamp(
                      0,
                      _emptyMessages.length - 1,
                    )],
                    icon: Icons.bookmark_border,
                    hint: '在剧详情页点书签图标就能收进来',
                    action: InkPill(
                      label: '去逛首页',
                      icon: Icons.local_fire_department_outlined,
                      onTap: () => context.go(AppRoutes.home),
                    ),
                  ),
                )
              : SliverPadding(
                  padding: AppSpacing.pageH,
                  sliver: SliverList.separated(
                    itemCount: items.length,
                    separatorBuilder: (context, index) =>
                        Divider(color: colors.divider, height: 1),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return Reveal(
                        index: index,
                        child: LibraryRow(
                          title: item.title,
                          id: item.id,
                          source: item.source,
                          seed: item.id,
                          cover: item.cover,
                          watchedEpisode: item.watchedEpisode,
                          totalEpisode: item.totalEpisode,
                          progress: item.progress,
                          statusLine: _statusLine(item),
                          updatedLabel: item.hasUnwatched ? '还有未看的' : null,
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
        const SliverNavBarBottomInset(),
      ],
    );
  }

  /// 状态行：明确区分「加追了但没开看」与「看到第几集」。
  static String _statusLine(LibraryItem item) {
    if (item.isPlanned) {
      return item.totalEpisode > 0 ? '还没开始 · 共 ${item.totalEpisode} 集' : '还没开始';
    }
    if (item.totalEpisode > 0) {
      return '看到第 ${item.watchedEpisode} 集 / 共 ${item.totalEpisode} 集';
    }
    return '看到第 ${item.watchedEpisode} 集';
  }

  /// 管理：分档说明 + 跳转下载管理（低频动作收进 sheet，不占首屏）。
  Future<void> _showManageSheet(BuildContext context, WidgetRef ref) async {
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
                      '追剧管理',
                      style: AppText.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  Text(
                    '「想看 / 在看 / 已看 / 有更新」是四种不同意图。'
                    '「有更新」只表示还有未看的集数；源站是否新更新了集数'
                    '需要重新拉取详情，离线无法判定。',
                    style: AppText.callout.copyWith(
                      color: colors.textSecondary,
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
        );
      },
    );
  }
}
