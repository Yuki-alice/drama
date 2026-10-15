import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../tokens/app_tokens.dart';

/// 玻璃卡（功能层容器）。
///
/// 用独立 own-layer，因此不依赖祖先 `LiquidGlassLayer`，可放在任意位置。
/// **玻璃不嵌套**：卡内不得再放 `GlassButton/Slider/Switch`——玻璃套玻璃是静默降质
/// （`avoidsRefraction` → `_VibrancyFill`，无 blur 无折射），不是报错。
class GlassSurfaceCard extends StatelessWidget {
  const GlassSurfaceCard({
    super.key,
    this.child,
    this.padding,
    this.width,
    this.quality = GlassQuality.standard,
  });

  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) => GlassCard(
    width: width,
    padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
    shape: const LiquidRoundedSuperellipse(borderRadius: AppRadii.lg),
    useOwnLayer: true,
    quality: quality,
    child: child,
  );
}

/// 图标 + 文字的玻璃动作按钮（详情页主操作 / 空态操作）。
class GlassActionButton extends StatelessWidget {
  const GlassActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.width = 136,
    this.height = 44,
    this.tint,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final double width;
  final double height;

  /// 图标与文字颜色；默认取品牌强调色。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final color = tint ?? AppColors.of(context).accent;
    return GlassButton.custom(
      onTap: onTap,
      width: width,
      height: height,
      useOwnLayer: true,
      quality: GlassQuality.standard,
      shape: const LiquidOval(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: AppText.body.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 玻璃图标按钮（AppBar 动作 / 播放控制条）。
class GlassIconAction extends StatelessWidget {
  const GlassIconAction({
    super.key,
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.size = 40,
    this.iconSize = 18,
    this.tint,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? semanticLabel;
  final double size;
  final double iconSize;
  final Color? tint;

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
    );
  }
}
