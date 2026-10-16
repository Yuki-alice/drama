import 'package:flutter/material.dart';

import '../../../domain/models/drama.dart';
import '../motion/app_motion.dart';
import '../tokens/app_tokens.dart';
import 'lockups.dart';

/// 剧目海报网格（内容层，不透明）。
///
/// 网格参数只有一个来源（[PosterGrid]），避免首页内联一份、
/// 这里又一份，日后调比例时漂移。
class DramaPosterGrid extends StatelessWidget {
  const DramaPosterGrid({
    super.key,
    required this.dramas,
    required this.onTap,
    this.shrinkWrap = false,
    this.physics,
    this.maxCrossAxisExtent = PosterGrid.maxCrossAxisExtent,
    this.padding = AppSpacing.pageH,
    this.controller,
    this.header,
  });

  final List<Drama> dramas;
  final ValueChanged<Drama> onTap;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final double maxCrossAxisExtent;
  final EdgeInsetsGeometry padding;
  final ScrollController? controller;

  /// 可选的列表头（放在同一滚动视图内，避免嵌套滚动）。
  final Widget? header;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    controller: controller,
    shrinkWrap: shrinkWrap,
    physics: physics,
    slivers: <Widget>[
      if (header != null) SliverToBoxAdapter(child: header),
      SliverPadding(
        padding: padding,
        sliver: SliverGrid(
          gridDelegate: PosterGrid.delegate(maxExtent: maxCrossAxisExtent),
          delegate: SliverChildBuilderDelegate((context, index) {
            final drama = dramas[index];
            return Reveal(
              index: index,
              child: PosterLockup(
                drama: drama,
                onTap: () => onTap(drama),
                fill: true,
              ),
            );
          }, childCount: dramas.length),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
    ],
  );
}

/// 加载态。
///
/// 只有转圈是「不知要等多久」的弱信号；海报墙类的首屏用**骨架屏**
/// 感知更快，所以 [PosterGridSkeleton] 才是列表页的默认加载态，
/// 这个组件只留给「无法预估形状」的场景。
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

/// 海报墙骨架屏：用**真海报的形状**占位，而不是转圈。
///
/// 复用网格参数（[PosterGrid]），所以骨架与真内容的列数、间距、
/// 封面比例完全一致——加载完成时不会发生布局跳动。
class PosterGridSkeleton extends StatefulWidget {
  const PosterGridSkeleton({
    super.key,
    this.count = 6,
    this.padding = AppSpacing.pageH,
    this.label = '正在加载剧目',
  });

  final int count;
  final EdgeInsetsGeometry padding;
  final String label;

  @override
  State<PosterGridSkeleton> createState() => _PosterGridSkeletonState();
}

class _PosterGridSkeletonState extends State<PosterGridSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 减弱动效：不呼吸，静态骨架仍然完成「占位」这个主要功能。
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    Widget tile() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.posterFallback,
              borderRadius: BorderRadius.circular(AppRadii.lg),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _bar(colors, width: 96),
        const SizedBox(height: 6),
        _bar(colors, width: 60),
      ],
    );

    final grid = GridView.builder(
      padding: widget.padding,
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: widget.count,
      gridDelegate: PosterGrid.delegate(),
      itemBuilder: (context, index) => tile(),
    );

    return Semantics(
      label: widget.label,
      liveRegion: true,
      child: reduce
          ? grid
          : FadeTransition(
              opacity: Tween<double>(begin: .55, end: 1).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              child: grid,
            ),
    );
  }

  Widget _bar(AppColors colors, {required double width}) => Container(
    height: 11,
    width: width,
    decoration: BoxDecoration(
      color: colors.posterFallback,
      borderRadius: BorderRadius.circular(AppRadii.xs),
    ),
  );
}

/// 空态：说明**为什么空**并且给出下一步，而不是只说「暂无数据」。
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
/// 那是 P0-1：一次翻页抖动不该让已加载的整屏内容消失。
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

/// 横向 chip 条（玻璃控件直接放在 body 上，**不**进玻璃卡）。
///
/// 固定高度会在大字模式下裁字，所以高度按 `textScaler` 缩放。
class ChipStrip extends StatelessWidget {
  const ChipStrip({
    super.key,
    required this.children,
    this.padding = AppSpacing.pageH,
    this.height = 52,
    this.separator = AppSpacing.sm,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final double height;
  final double separator;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return SizedBox(
      // 44pt 触控目标 + 上下各 4pt 呼吸；大字下等比放大而不是裁切。
      height: (height * scale).clamp(height, height * 1.4),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: children.length,
        separatorBuilder: (context, index) => SizedBox(width: separator),
        itemBuilder: (context, index) => Center(child: children[index]),
      ),
    );
  }
}
