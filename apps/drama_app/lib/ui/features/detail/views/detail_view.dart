import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../data/repositories/catalog_repository.dart';
import '../../../../data/services/rust_core.dart';
import '../../../../domain/models/episode.dart';
import '../../../../router/routes.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/poster_artwork.dart';
import '../view_models/detail_view_model.dart';

/// 详情 + 选集（PRD F-04）。
///
/// 封面为不透明内容层；底部操作条与选集为功能层玻璃（ARCH §4.1 纪律一）。
class DetailView extends ConsumerStatefulWidget {
  const DetailView({super.key, required this.id});

  final String id;

  @override
  ConsumerState<DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends ConsumerState<DetailView> {
  /// 每组 50 集（PRD F-04）。
  static const int _groupSize = 50;

  int _groupIndex = 0;

  /// 当前集（W1 mock：固定第 1 集；W3 由播放进度接管）。
  final int _currentEpisode = 1;

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(detailProvider(widget.id));

    return detailAsync.when(
      data: (detail) => _content(context, detail),
      loading: () => AppGlassScaffold(
        title: '剧集详情',
        leading: _backAction(context),
        body: const LoadingView(),
      ),
      error: (error, _) => AppGlassScaffold(
        title: '剧集详情',
        leading: _backAction(context),
        // 未找到（StateError）走空态；其余真错误显式呈现并可重试（plan §8）。
        body: error is StateError
            ? const EmptyView(message: '未找到该剧集', icon: Icons.search_off)
            : ErrorView(
                message: _errorMessage(error),
                onRetry: () => ref.invalidate(detailProvider(widget.id)),
              ),
      ),
    );
  }

  Widget _content(BuildContext context, DramaDetail detail) {
    final drama = detail.drama;
    final episodes = detail.episodes;
    final groupCount = episodes.isEmpty
        ? 1
        : (episodes.length / _groupSize).ceil();
    final visibleEpisodes = episodes
        .skip(_groupIndex * _groupSize)
        .take(_groupSize)
        .toList(growable: false);
    final colors = AppColors.of(context);

    return AppGlassScaffold(
      title: drama.title,
      leading: _backAction(context),
      body: CustomScrollView(
        slivers: <Widget>[
          // ── 基本信息（封面不透明） ─────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.md,
                AppSpacing.gutter,
                AppSpacing.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 124,
                    child: PosterArtwork(seed: drama.coverSeed),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          drama.title,
                          style: AppText.title.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '${drama.categoryName} · ${drama.status.label} · 共 ${drama.episodeCount} 集',
                          style: AppText.callout.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: <Widget>[
                            for (final tag in drama.tags) _Tag(tag),
                            if (drama.vip) const _Tag('VIP 预留'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 操作条（玻璃：播放 / 追剧 / 下载） ─────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: AppSpacing.pageH,
              child: Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: <Widget>[
                  GlassActionButton(
                    label: '播放',
                    icon: Icons.play_arrow,
                    onTap: () => context.push(
                      AppRoutes.player(widget.id, episode: _currentEpisode),
                    ),
                  ),
                  GlassActionButton(
                    label: '追剧',
                    icon: Icons.bookmark_add_outlined,
                    tint: colors.textPrimary,
                    onTap: () => _notify(context, '追剧能力将在 W4 落地（F-06）'),
                  ),
                  GlassActionButton(
                    label: '下载',
                    icon: Icons.download_outlined,
                    tint: colors.textPrimary,
                    onTap: () => _notify(context, '下载能力将在 W4 落地（F-07）'),
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SectionHeader(title: '选集')),

          // ── 分组切换（每组 50 集） ────────────────────────────
          if (groupCount > 1)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 52,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: AppSpacing.pageH,
                  itemCount: groupCount,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final start = index * _groupSize + 1;
                    final end = ((index + 1) * _groupSize).clamp(
                      1,
                      episodes.length,
                    );
                    return Center(
                      child: GlassChip(
                        label: '$start-$end',
                        selected: index == _groupIndex,
                        useOwnLayer: true,
                        onTap: () => setState(() => _groupIndex = index),
                      ),
                    );
                  },
                ),
              ),
            ),

          // ── 集号网格 ──────────────────────────────────────────
          SliverPadding(
            padding: AppSpacing.pageH,
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 84,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 1.5,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final episode = visibleEpisodes[index];
                return _EpisodeTile(
                  episode: episode,
                  current: episode.index == _currentEpisode,
                  onTap: () => episode.locked
                      ? _notify(context, '该集需 App 授权（轨①仅覆盖可试看集）')
                      : context.push(
                          AppRoutes.player(widget.id, episode: episode.index),
                        ),
                );
              }, childCount: visibleEpisodes.length),
            ),
          ),

          const SliverToBoxAdapter(child: SectionHeader(title: '简介')),
          SliverToBoxAdapter(
            child: Padding(
              padding: AppSpacing.pageH,
              child: Text(
                drama.summary,
                style: AppText.body.copyWith(color: colors.textSecondary),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
        ],
      ),
    );
  }

  Widget _backAction(BuildContext context) => GlassIconAction(
    icon: Icons.arrow_back_ios_new,
    semanticLabel: '返回',
    onPressed: () => context.pop(),
  );

  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 统一错误文案（[RustCoreException] 带错误码，其余直接 `toString`）。
String _errorMessage(Object error) =>
    error is RustCoreException ? '${error.msg}（${error.code}）' : '$error';

/// 集号磁贴。
class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.current,
    required this.onTap,
  });

  final Episode episode;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.contentSurface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: current ? colors.accent : colors.divider,
            width: current ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (episode.locked)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.lock_outline,
                    size: 12,
                    color: colors.textTertiary,
                  ),
                ),
              Text(
                '${episode.index}',
                style: AppText.body.copyWith(
                  color: episode.locked
                      ? colors.textTertiary
                      : (current ? colors.accent : colors.textPrimary),
                  fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 题材标签（内容层，非玻璃）。
class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: colors.contentSurface,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: colors.divider),
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(color: colors.textSecondary),
      ),
    );
  }
}
