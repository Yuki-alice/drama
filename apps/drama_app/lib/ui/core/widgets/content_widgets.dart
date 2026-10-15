import 'package:flutter/material.dart';

import '../../../domain/models/drama.dart';
import '../tokens/app_tokens.dart';
import 'app_glass_scaffold.dart';
import 'poster_artwork.dart';

/// 区块标题 + 可选右侧动作。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.lg,
        AppSpacing.gutter,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: AppText.headline.copyWith(color: colors.textPrimary),
            ),
          ),
          if (actionLabel != null && onAction != null)
            GestureDetector(
              onTap: onAction,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: <Widget>[
                  Text(
                    actionLabel!,
                    style: AppText.callout.copyWith(color: colors.accent),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: colors.accent),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 剧目海报卡（内容层，不透明；标题在玻璃层之外）。
class DramaPosterCard extends StatelessWidget {
  const DramaPosterCard({super.key, required this.drama, required this.onTap});

  final Drama drama;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          PosterArtwork(seed: drama.coverSeed, title: drama.title),
          const SizedBox(height: AppSpacing.sm),
          Text(
            drama.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.callout.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            // 真实源个别条目缺 episode_cnt（值为 0）→ 不显示"共 0 集"这种坏数据观感。
            drama.episodeCount > 0
                ? '${drama.status.label} · 共 ${drama.episodeCount} 集'
                : drama.status.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// 响应式海报网格（ARCH §4.1：列表/网格一律不做 premium）。
///
/// 用 `SliverGridDelegateWithMaxCrossAxisExtent`，列数随可用宽度自动变化——
/// 手机 2 列、平板 4 列、桌面 6 列，无需手写断点分支。
class DramaPosterGrid extends StatelessWidget {
  const DramaPosterGrid({
    super.key,
    required this.dramas,
    required this.onTap,
    this.shrinkWrap = false,
    this.physics,
    this.maxCrossAxisExtent = 180,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
    this.controller,
  });

  final List<Drama> dramas;
  final ValueChanged<Drama> onTap;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final double maxCrossAxisExtent;
  final EdgeInsetsGeometry padding;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => GridView.builder(
    controller: controller,
    shrinkWrap: shrinkWrap,
    physics: physics,
    padding: padding,
    itemCount: dramas.length,
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxCrossAxisExtent,
      mainAxisSpacing: AppSpacing.md,
      crossAxisSpacing: AppSpacing.md,
      childAspectRatio: 0.56,
    ),
    itemBuilder: (context, index) => DramaPosterCard(
      drama: dramas[index],
      onTap: () => onTap(dramas[index]),
    ),
  );
}

/// 加载态。
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.padding = const EdgeInsets.all(AppSpacing.xxl)});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

/// 空态。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 40, color: colors.textTertiary),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: colors.textSecondary),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            action!,
          ],
        ],
      ),
    );
  }
}

/// 错误态（含重试）。失败必须显式呈现，不静默吞掉（plan §8 纪律）。
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.error_outline, size: 40, color: colors.accent),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: colors.textSecondary),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            GestureDetector(
              onTap: onRetry,
              behavior: HitTestBehavior.opaque,
              child: Text(
                '重试',
                style: AppText.body.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 让滚动内容在 `extendBody: true` 时不钻到 AppBar 底下。
class ScrollTopInset extends StatelessWidget {
  const ScrollTopInset({super.key, this.extra = AppSpacing.sm});

  final double extra;

  @override
  Widget build(BuildContext context) =>
      GlassContentTopInset(extra: extra);
}
