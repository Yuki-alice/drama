import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../tokens/app_tokens.dart';

// 玻璃功能层基元。
//
// **玻璃不嵌套**：卡内不得再放 `GlassButton/Slider/Switch/Chip`——
// 玻璃套玻璃是静默降质（`avoidsRefraction` → 振动填充，无 blur 无折射），
// **不是报错**，所以很容易在改动中不知不觉踩进去。需要动作时把动作摆在
// 玻璃面**之外**，或者整条都用玻璃控件。
//
// **玻璃只出现在功能层**：Tab 栏 / 顶栏控件 / 搜索 / 侧栏 / 播放器控件。
// 内容层（海报 / 画面 / 列表行）保持不透明——见 HIG `materials.md`
// 「Don't use Liquid Glass in the content layer」。
//
// 档位一律不硬编码：这里只传 [GlassQuality]，实际渲染由
// `GlassAdaptiveScope` 按设备能力与实时帧率钳制。

/// 玻璃卡（功能层容器）。
///
/// 用独立 own-layer，因此不依赖祖先 `LiquidGlassLayer`，可放在任意位置。
class GlassSurfaceCard extends StatelessWidget {
  const GlassSurfaceCard({
    super.key,
    this.child,
    this.padding,
    this.width,
    this.height,
    this.radius = AppRadii.xl,
    this.quality = GlassQuality.standard,
  });

  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final double radius;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) => GlassCard(
    width: width,
    height: height,
    padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
    shape: LiquidRoundedSuperellipse(borderRadius: radius),
    useOwnLayer: true,
    quality: quality,
    child: child,
  );
}

/// 图标 + 文字的玻璃动作按钮。
///
/// 用图标玻璃钮 + **内容层**文字标签的组合表达「主操作」，
/// 而不是在玻璃上再刷一层填充色：主操作靠**面积与位置**
/// （左起第一个、最大）而不是颜色表达；默认取墨色字。
class GlassActionButton extends StatelessWidget {
  const GlassActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.width = 148,
    this.height = 44,
    this.tint,
    this.filled = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final double width;
  final double height;

  /// 图标与文字颜色；默认取墨色（深底场景传 `colors.onMedia`）。
  final Color? tint;

  /// 实心墨色胶囊（重型填充：全页最高优先级的那一个操作）。
  ///
  /// 实心时**不用玻璃**——墨底本身就是最强的前景，再叠玻璃只会让
  /// 白字边缘出现折射毛刺。绿色是状态色，不做主操作填充。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final color = tint ?? colors.textPrimary;
    final labelStyle = AppText.body.copyWith(
      color: filled ? colors.onInk : color,
      fontWeight: FontWeight.w600,
    );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 18, color: filled ? colors.onInk : color),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelStyle,
          ),
        ),
      ],
    );

    if (filled) {
      return Semantics(
        button: true,
        label: label,
        child: SizedBox(
          width: width,
          height: height,
          child: Material(
            color: colors.textPrimary,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              // 墨底之上的水波纹要用反色，否则完全看不见。
              splashColor: colors.onInk.withValues(alpha: .12),
              highlightColor: colors.onInk.withValues(alpha: .08),
              child: Center(child: row),
            ),
          ),
        ),
      );
    }

    return GlassButton.custom(
      onTap: onTap,
      width: width,
      height: height,
      useOwnLayer: true,
      quality: GlassQuality.standard,
      shape: const LiquidOval(),
      child: row,
    );
  }
}

/// 玻璃图标按钮（顶栏动作 / 播放控制条）。
///
/// 默认 44×44：HIG `accessibility.md` 的可点区下限（移动端默认 44×44 pt）。
/// **不得**为了视觉紧凑把它缩到 36——那是缺陷不是风格。
class GlassIconAction extends StatelessWidget {
  const GlassIconAction({
    super.key,
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.size = AppSpacing.minTapTarget,
    this.iconSize = 20,
    this.tint,
    this.glowColor,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? semanticLabel;
  final double size;
  final double iconSize;
  final Color? tint;
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    final color = tint ?? AppColors.of(context).textPrimary;
    return GlassIconButton(
      icon: Icon(icon, size: iconSize, color: color),
      onPressed: onPressed,
      size: size,
      useOwnLayer: true,
      quality: GlassQuality.standard,
      semanticLabel: semanticLabel,
      glowColor: glowColor,
    );
  }
}

/// 一条玻璃胶囊：把一组控件装进同一个容器（播放器角上的控制组）。
///
/// 苹果味的关键之一——**同一功能的东西共用一个玻璃容器**，
/// 而不是每个按钮各自一块玻璃。这样既少一层折射叠算，
/// 也在视觉上把「一组」说清楚。
class GlassCapsuleGroup extends StatelessWidget {
  const GlassCapsuleGroup({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.xs,
      vertical: AppSpacing.xs,
    ),
    this.axis = Axis.horizontal,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final Axis axis;

  @override
  Widget build(BuildContext context) => GlassContainer(
    padding: padding,
    shape: const LiquidOval(),
    useOwnLayer: true,
    quality: GlassQuality.standard,
    child: axis == Axis.horizontal
        ? Row(mainAxisSize: MainAxisSize.min, children: children)
        : Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// 墨色胶囊（墨底反白字）——**唯一的重型填充**：色板里的主操作形态。
///
/// 用在不需要玻璃质感、只要求「这是主操作」的地方（详情页的「开始观看」、
/// 追剧行的「继续看」）。播放器场景请用 [GlassActionButton] 的玻璃形态，
/// 因为那里底下是画面，实心墨块会盖掉内容。
///
/// 主操作是墨色、不是彩色——无彩色界面里「最重」的表达就是墨底反白字。
class InkPill extends StatelessWidget {
  const InkPill({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.height = AppSpacing.minTapTarget,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
    this.dense = false,
    this.semanticHint,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final double height;
  final EdgeInsetsGeometry padding;

  /// 紧凑档：内边距减小、字号降到 callout（列表行内的次级操作）。
  final bool dense;

  final String? semanticHint;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final style = (dense ? AppText.callout : AppText.body).copyWith(
      color: colors.onInk,
      fontWeight: FontWeight.w600,
    );
    return Semantics(
      button: true,
      label: label,
      hint: semanticHint,
      child: SizedBox(
        height: height,
        child: Material(
          color: colors.textPrimary,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            splashColor: colors.onInk.withValues(alpha: .12),
            highlightColor: colors.onInk.withValues(alpha: .08),
            child: Padding(
              padding: padding,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: dense ? 15 : 17, color: colors.onInk),
                    const SizedBox(width: AppSpacing.xs + 2),
                  ],
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
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

/// 描边胶囊（次级操作 / 筛选选中态）。
///
/// 未选中：内容面 + 发丝描边——在内容层里表达「可点」但不抢注意力。
/// 选中：**墨色填充 + 反白字**（[AppColors.textPrimary] + [AppColors.onInk]）——
/// 无彩色色板下唯一的「重型填充」表达选中。
///
/// [onTap] 为 null 时进入**禁用态**（文字与描边一起弱化，且语义上
/// 标记为 disabled）——离线文件的清晰度切换就是这一档。
class OutlinePill extends StatelessWidget {
  const OutlinePill({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.icon,
    this.height = AppSpacing.minTapTarget,
    this.semanticLabel,
  });

  final String label;

  /// 为 null = 禁用（不可点，且读屏器会读出「不可用」）。
  final VoidCallback? onTap;

  final bool selected;
  final IconData? icon;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final disabled = onTap == null;
    final textColor = disabled
        ? colors.textDisabled
        : (selected ? colors.onInk : colors.textPrimary);
    final iconColor = disabled
        ? colors.textDisabled
        : (selected ? colors.onInk : colors.textSecondary);

    return Semantics(
      button: true,
      enabled: !disabled,
      selected: selected,
      label: semanticLabel ?? label,
      child: SizedBox(
        height: height,
        child: Material(
          // 选中 = 墨色填充；未选中 = 内容面 + 发丝描边。
          color: selected ? colors.textPrimary : colors.surfaceElevated,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? colors.textPrimary : colors.divider,
              width: 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 16, color: iconColor),
                    const SizedBox(width: AppSpacing.xs + 2),
                  ],
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.callout.copyWith(
                      color: textColor,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
