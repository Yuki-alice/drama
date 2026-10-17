import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 加载态。
///
/// 只有转圈是「不知要等多久」的弱信号；海报墙类的首屏用**骨架屏**
/// 感知更快（见 `feed_skeleton.dart`），这个组件只留给「无法预估形状」
/// 的场景。
class LoadingView extends StatelessWidget {
  const LoadingView({
    super.key,
    this.padding = const EdgeInsets.all(AppSpacing.xxl),
    this.label,
  });

  final EdgeInsetsGeometry padding;

  /// 可选的说明文字（读屏器也需要知道正在加载什么）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      label: label ?? '正在加载',
      liveRegion: true,
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: colors.textTertiary,
              ),
            ),
            if (label != null) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              Text(
                label!,
                style: AppText.callout.copyWith(color: colors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空态：说明**为什么空**并且给出下一步，而不是只说「暂无数据」。
///
/// 主导航页（追剧等）请用 `lockups.dart` 的 `EmptyState`——那是原型的
/// 完整空态（圆底图标 + 说明 + 出口）；这里给次级页用轻量版。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.hint,
    this.action,
  });

  final String message;
  final IconData icon;

  /// 补充说明（「在剧详情页点书签图标就能收进来」）。
  final String? hint;

  /// 下一步动作（通常是墨色胶囊）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 36, color: colors.textTertiary),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.headline.copyWith(color: colors.textPrimary),
          ),
          if (hint != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: AppText.callout.copyWith(color: colors.textSecondary),
            ),
          ],
          if (action != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            action!,
          ],
        ],
      ),
    );
  }
}

/// 错误态（含重试）。失败必须显式呈现，不静默吞掉。
///
/// **只用于整页失败**（首载失败）。列表追加失败请用 `InlineRetry`——
/// 一次翻页抖动不该让已加载的整屏内容消失。
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
          // 色板里没有红色：错误用**图标形状 + 措辞**区分，不靠颜色。
          Icon(Icons.error_outline, size: 36, color: colors.textPrimary),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: colors.textSecondary),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              height: AppSpacing.minTapTarget,
              child: OutlinedButton(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.textPrimary,
                  side: BorderSide(color: colors.borderStrong),
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                  ),
                ),
                child: const Text('重试'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 缓存兜底轻提示（弱网下展示的是缓存数据）。一条 caption 行，不遮挡内容。
class StaleNotice extends StatelessWidget {
  const StaleNotice({super.key, this.message = '当前为缓存数据，网络恢复后自动更新'});

  final String message;

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
              message,
              style: AppText.caption.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
