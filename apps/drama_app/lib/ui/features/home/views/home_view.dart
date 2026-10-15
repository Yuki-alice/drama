import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/services/rust_core.dart';
import '../../../../router/routes.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/content_widgets.dart';
import '../view_models/home_view_model.dart';

/// 首页浏览（PRD F-01）——主导航分支页，只返回 body 内容。
///
/// 外壳（AppBar + 底部玻璃栏）由 `AppNavigationShell` 提供。
class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(homeFilterProvider);
    final notifier = ref.read(homeFilterProvider.notifier);
    final categoriesAsync = ref.watch(homeCategoriesProvider);
    final recommendationsAsync = ref.watch(homeRecommendationsProvider);
    final feed = ref.watch(homeFeedProvider);
    // W2 弱网：true 表示当前展示的是缓存兜底结果。
    final isStale = ref.watch(staleDataNoticeProvider);

    // 横滑推荐条的高度随字号自适应：海报高（132 × 4/3 = 176）+ 标题/元信息区，
    // 否则大字模式（F-09）下卡片下方文字会溢出。
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final stripHeight = 176.0 + 58.0 * textScale;

    // 分类是页面骨架（提供切类入口与标题），失败整页给错误态 + 重试。
    return categoriesAsync.when(
      loading: () => const LoadingView(),
      error: (error, _) => ErrorView(
        message: _errorMessage(error),
        onRetry: () => ref.invalidate(homeCategoriesProvider),
      ),
      data: (categories) {
        var categoryLabel = categories.isEmpty ? '推荐' : categories.first.name;
        for (final category in categories) {
          if (category.id == filter.categoryId) {
            categoryLabel = category.name;
            break;
          }
        }

        return CustomScrollView(
          slivers: <Widget>[
            // 缓存兜底轻提示（不遮挡内容、不新增玻璃卡——纪律四）。
            if (isStale) const SliverToBoxAdapter(child: _StaleNotice()),
            const SliverToBoxAdapter(child: SectionHeader(title: '为你推荐')),
            SliverToBoxAdapter(
              child: recommendationsAsync.when(
                data: (recommendations) => SizedBox(
                  height: stripHeight,
                  child: recommendations.isEmpty
                      ? const EmptyView(message: '暂无推荐')
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.gutter,
                          ),
                          itemCount: recommendations.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: AppSpacing.md),
                          itemBuilder: (context, index) {
                            final drama = recommendations[index];
                            return SizedBox(
                              width: 132,
                              child: DramaPosterCard(
                                drama: drama,
                                onTap: () => context.push(
                                  AppRoutes.detail(drama.id),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                loading: () => SizedBox(
                  height: stripHeight,
                  child: const LoadingView(),
                ),
                error: (error, _) => ErrorView(
                  message: _errorMessage(error),
                  onRetry: () => ref.invalidate(homeRecommendationsProvider),
                ),
              ),
            ),

            // 分类横滑切类（PRD F-01）。
            SliverToBoxAdapter(
              child: _ChipStrip(
                children: <Widget>[
                  for (final category in categories)
                    GlassChip(
                      label: category.name,
                      selected: category.id == filter.categoryId,
                      useOwnLayer: true,
                      onTap: () => notifier.selectCategory(category.id),
                    ),
                ],
              ),
            ),

            // 排序 / 连载筛选（PRD F-01）。
            SliverToBoxAdapter(
              child: _ChipStrip(
                children: <Widget>[
                  for (final sort in HomeSort.values)
                    GlassChip(
                      label: sort.label,
                      selected: sort == filter.sort,
                      useOwnLayer: true,
                      onTap: () => notifier.selectSort(sort),
                    ),
                  for (final status in HomeStatusFilter.values)
                    GlassChip(
                      label: status.label,
                      selected: status == filter.status,
                      useOwnLayer: true,
                      onTap: () => notifier.selectStatus(status),
                    ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SectionHeader(title: '$categoryLabel · 全部剧目'),
            ),

            ...feed.when<List<Widget>>(
              data: (value) => <Widget>[
                if (value.items.isEmpty)
                  const SliverToBoxAdapter(
                    child: EmptyView(
                      message: '当前筛选下没有剧集',
                      icon: Icons.filter_alt_off_outlined,
                    ),
                  )
                else
                  SliverPadding(
                    padding: AppSpacing.pageH,
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisSpacing: AppSpacing.md,
                            crossAxisSpacing: AppSpacing.md,
                            childAspectRatio: 0.56,
                          ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final drama = value.items[index];
                        return DramaPosterCard(
                          drama: drama,
                          onTap: () =>
                              context.push(AppRoutes.detail(drama.id)),
                        );
                      }, childCount: value.items.length),
                    ),
                  ),
                if (value.hasMore)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.lg,
                      ),
                      child: Center(
                        child: value.loadingMore
                            ? const LoadingView(padding: EdgeInsets.zero)
                            : _LoadMoreButton(
                                onTap: () => ref
                                    .read(homeFeedProvider.notifier)
                                    .loadMore(),
                                label: '加载更多',
                              ),
                      ),
                    ),
                  ),
              ],
              loading: () => const <Widget>[
                SliverToBoxAdapter(child: LoadingView()),
              ],
              error: (error, _) => <Widget>[
                SliverToBoxAdapter(
                  child: ErrorView(
                    message: _errorMessage(error),
                    onRetry: () => ref.invalidate(homeFeedProvider),
                  ),
                ),
              ],
            ),

            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
          ],
        );
      },
    );
  }
}

/// 统一错误文案（[RustCoreException] 带错误码，其余直接 `toString`）。
String _errorMessage(Object error) =>
    error is RustCoreException ? '${error.msg}（${error.code}）' : '$error';

/// 缓存兜底轻提示：一条 caption 行（不遮挡内容、不新增玻璃卡——纪律四）。
class _StaleNotice extends StatelessWidget {
  const _StaleNotice();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.cloud_off_outlined, size: 14, color: colors.textTertiary),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              '当前为缓存数据，网络恢复后自动更新',
              style: AppText.caption.copyWith(color: colors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 横向 chip 条（玻璃控件直接放在 body 上，不进玻璃卡——纪律四）。
class _ChipStrip extends StatelessWidget {
  const _ChipStrip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      itemCount: children.length,
      separatorBuilder: (context, index) => const SizedBox(width: AppSpacing.sm),
      itemBuilder: (context, index) => Center(child: children[index]),
    ),
  );
}

/// 「加载更多」兜底入口。
class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: colors.contentSurface,
          borderRadius: BorderRadius.circular(AppRadii.capsule),
          border: Border.all(color: colors.divider),
        ),
        child: Text(
          label,
          style: AppText.body.copyWith(
            color: colors.accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
