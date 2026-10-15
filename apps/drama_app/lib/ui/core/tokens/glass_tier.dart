import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 玻璃渲染档位（ARCH §4.1「三档」）。
///
/// 档位是**天花板**而非地板：UI 只声明期望档位，最终由 `GlassAdaptiveScope`
/// 按设备能力与实时帧率钳制。**UI 不得硬编码档位**——App resume 会重跑
/// Phase 2 benchmark，档位可能再次变化（ARCH §4）。
enum GlassTier {
  /// 质感档：完整 shader 管线。仅给栏 / 条 / 弹层这类无正文的面，禁用于滚动列表。
  premium('质感', GlassQuality.premium),

  /// 标准档：轻量 shader。列表、网格与大多数功能面默认落此档。
  standard('标准', GlassQuality.standard),

  /// 基础档：无 shader 的 BackdropFilter 磨砂。旧机 / 降级路径 / 长列表用此档。
  minimal('基础', GlassQuality.minimal);

  const GlassTier(this.label, this.quality);

  /// 面向用户可读的档位名（设置页「外观」里展示）。
  final String label;

  /// 对应 `liquid_glass_widgets` 的渲染质量枚举。
  final GlassQuality quality;
}

/// 平台静态上限（ARCH §4「P0 验收档位」）。
///
/// Windows / Linux 被包的平台策略钉在 standard（即便 3.47 起已是 Impeller）；
/// 其余平台交 `GlassAdaptiveScope` 自适应，这里给 premium 作为期望值。
GlassTier platformGlassCeiling() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return GlassTier.standard;
    default:
      return GlassTier.premium;
  }
}

/// 由档位与亮度构造 `GlassTheme` 变体（ARCH §4）。
///
/// 以包内建 light/dark 预设为基线：premium 加厚加亮以体现质感；
/// minimal 直接用包内建的无 shader 预设，保证跨平台一致。
GlassThemeVariant glassVariantFor(GlassTier tier, Brightness brightness) {
  final base = brightness == Brightness.dark
      ? GlassThemeVariant.dark
      : GlassThemeVariant.light;

  switch (tier) {
    case GlassTier.premium:
      return base.copyWith(
        quality: GlassQuality.premium,
        settings: base.settings?.copyWith(
          thickness: 18,
          blur: 6,
          lightIntensity: 0.95,
          chromaticAberration: 0.05,
          saturation: 1.25,
        ),
      );
    case GlassTier.standard:
      return base.copyWith(quality: GlassQuality.standard);
    case GlassTier.minimal:
      return GlassThemeVariant.minimal;
  }
}

/// 组装整套 `GlassThemeData`（浅 + 深两变体同档）。
GlassThemeData buildGlassThemeData(GlassTier tier) => GlassThemeData(
  light: glassVariantFor(tier, Brightness.light),
  dark: glassVariantFor(tier, Brightness.dark),
  interaction: const GlassInteractionSettings(),
);
