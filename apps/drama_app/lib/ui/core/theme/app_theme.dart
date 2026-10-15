import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';
import '../tokens/glass_tier.dart';
import 'appearance_controller.dart';

/// Material 主题（F-09）。
///
/// 只负责 Material 侧的配色与字体——玻璃侧由 `GlassTheme` 另外提供
/// （见 [buildGlassThemeData]）。`scaffoldBackgroundColor` 让
/// `CupertinoPageScaffold` 在无显式背景时有正确底色。
ThemeData buildMaterialTheme(Brightness brightness, {bool highContrast = false}) {
  final colors = AppColors(brightness);
  final scheme = ColorScheme.fromSeed(
    seedColor: colors.accent,
    brightness: brightness,
    contrastLevel: highContrast ? 1.0 : 0.0,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.background,
    canvasColor: colors.background,
    dividerColor: colors.divider,
    // 玻璃面自己承担动效，Material 的水波纹在玻璃上是噪点。
    splashFactory: NoSplash.splashFactory,
    textTheme: TextTheme(
      displaySmall: AppText.display.copyWith(color: colors.textPrimary),
      titleLarge: AppText.title.copyWith(color: colors.textPrimary),
      titleMedium: AppText.headline.copyWith(color: colors.textPrimary),
      bodyLarge: AppText.body.copyWith(color: colors.textPrimary),
      bodyMedium: AppText.body.copyWith(color: colors.textSecondary),
      bodySmall: AppText.callout.copyWith(color: colors.textSecondary),
      labelSmall: AppText.caption.copyWith(color: colors.textTertiary),
    ),
  );
}

/// 由外观设置解析**期望**玻璃档位。
///
/// 降级路径（ARCH §4.1）：大字 / 高对比 / 减弱动效任一开启 → 全站降 `minimal`
/// （功能不降级，只降质感）。实际档位仍由 `GlassAdaptiveScope` 天花板钳制，
/// UI 不得假设它稳定。
GlassTier resolveGlassTier(AppearanceSettings appearance) {
  if (appearance.highContrast || appearance.reduceMotion || appearance.largeText) {
    return GlassTier.minimal;
  }
  return platformGlassCeiling();
}
