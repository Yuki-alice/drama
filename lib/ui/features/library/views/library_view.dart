import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../data/services/rust_core.dart';
import '../../../../router/routes.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/poster_artwork.dart';
import '../view_models/library_view_model.dart';

/// 追剧 / 历史：四档横滑切换 + 观看进度列表。
///
/// 主导航分支页，只返回 body 内容。
class LibraryView extends ConsumerWidget {
  const LibraryView({super.key});

  static const List<String> _tabs = <String>['想看', '在看', '已看', '有更新'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final selectedTab = ref.watch(libraryTabProvider);
    final itemsAsync = ref.watch(libraryItemsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 分档切换：玻璃 chip 独立 own-layer，置于 body 顶层而非玻璃卡内。
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            itemCount: _tabs.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) => Center(
              child: GlassChip(
                label: _tabs[index],
                selected: index == selectedTab,
                useOwnLayer: true,
                onTap: () =>
                    ref.read(libraryTabProvider.notifier).select(index),
                labelStyle: AppText.callout.copyWith(
                  color: index == selectedTab
                      ? colors.accent
                      : colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: itemsAsync.when(
            data: (items) => items.isEmpty
                ? const EmptyView(message: '这里还没有内容')
                : ListView.builder(
                    padding: const EdgeInsets.only(
                      top: AppSpacing.sm,
                      bottom: AppSpacing.xl,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) => _LibraryRow(
                      item: items[index],
                      onTap: () =>
                          context.push(AppRoutes.detail(items[index].drama.id)),
                    ),
                  ),
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              message: _errorMessage(error),
              onRetry: () => ref.invalidate(libraryItemsProvider),
            ),
          ),
        ),
      ],
    );
  }
}

/// 统一错误文案（[RustCoreException] 带错误码，其余直接 `toString`）。
String _errorMessage(Object error) =>
    error is RustCoreException ? '${error.msg}（${error.code}）' : '$error';

/// 单条追剧记录：海报 + 标题 + 观看集数 + 进度条（普通行）。
class _LibraryRow extends StatelessWidget {
  const _LibraryRow({required this.item, required this.onTap});

  final LibraryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 56,
              child: PosterArtwork(
                seed: item.drama.coverSeed,
                title: item.drama.title,
                aspectRatio: 0.75,
                radius: 10,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    item.drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '看到第 ${item.watchedEpisode} 集 / 共 ${item.totalEpisode} 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: colors.textTertiary),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.capsule),
                    child: LinearProgressIndicator(
                      value: item.progress,
                      minHeight: 4,
                      backgroundColor: colors.divider,
                      color: colors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
