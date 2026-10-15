import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../data/repositories/catalog_repository.dart';
import '../../../../data/services/rust_core.dart';
import '../../../../domain/models/drama.dart';
import '../../../../router/routes.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/drama_cover.dart';
import '../view_models/ranking_view_model.dart';

/// 榜单：横滑切板 + 带名次的列表。
///
/// 主导航分支页，只返回 body 内容——外壳（AppGlassScaffold / 导航栏）由
/// AppNavigationShell 统一提供。
class RankingView extends ConsumerWidget {
  const RankingView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final selectedBoard = ref.watch(rankingBoardProvider);
    final dramasAsync = ref.watch(rankingListProvider);
    final boardName = RankingBoards.all
        .firstWhere((board) => board.id == selectedBoard)
        .name;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 板切换：玻璃 chip 独立 own-layer，置于 body 顶层而非玻璃卡内。
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            itemCount: RankingBoards.all.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final board = RankingBoards.all[index];
              return Center(
                child: GlassChip(
                  label: board.name,
                  selected: board.id == selectedBoard,
                  useOwnLayer: true,
                  onTap: () =>
                      ref.read(rankingBoardProvider.notifier).select(board.id),
                  labelStyle: AppText.callout.copyWith(
                    color: board.id == selectedBoard
                        ? colors.accent
                        : colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            },
          ),
        ),
        SectionHeader(title: boardName),
        Expanded(
          child: dramasAsync.when(
            data: (dramas) => dramas.isEmpty
                ? const EmptyView(message: '该榜单暂无剧集')
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    itemCount: dramas.length,
                    itemBuilder: (context, index) => _RankingRow(
                      rank: index + 1,
                      drama: dramas[index],
                      onTap: () =>
                          context.push(AppRoutes.detail(dramas[index].id)),
                    ),
                  ),
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              message: _errorMessage(error),
              onRetry: () => ref.invalidate(rankingListProvider),
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

/// 单条名次行：序号 + 海报 + 标题/元信息（整行普通 Row，可点进详情）。
class _RankingRow extends StatelessWidget {
  const _RankingRow({
    required this.rank,
    required this.drama,
    required this.onTap,
  });

  final int rank;
  final Drama drama;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final isTop = rank == 1;

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
              width: 28,
              child: Text(
                '$rank',
                textAlign: TextAlign.center,
                style: (isTop ? AppText.headline : AppText.body).copyWith(
                  color: isTop ? colors.accent : colors.textSecondary,
                  fontWeight: isTop ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              width: 56,
              child: DramaCover(
                seed: drama.coverSeed,
                cover: drama.cover,
                title: drama.title,
                aspectRatio: 0.75,
                radius: AppRadii.md,
                showTitleOverlay: false,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${drama.categoryName} · 共 ${drama.episodeCount} 集 · '
                    '${drama.status.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: colors.textTertiary),
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
