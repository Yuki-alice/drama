import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';
import '../tokens/glass_tier.dart';
import 'appearance_controller.dart';

/// Material 主题（F-09）。
///
/// 只负责 Material 侧的配色与字体——玻璃侧由 `GlassTheme` 另外提供
/// （见 [buildGlassThemeData]）。`scaffoldBackgroundColor` 让
/// `CupertinoPageScaffold` 在无显式背景时有正确底色。
///
/// **为什么不 `ColorScheme.fromSeed`**：从种子推导会生成一整套
/// 带有 Material 色相的容器色（primaryContainer / tertiary / surfaceTint…），
/// 与我们精心算过对比度的暖中性面**冲突**，且会给海报墙引入第二、第三支
/// 抢眼的颜色。这里显式构造 [ColorScheme]，只保留真正会用到的角色。
ThemeData buildMaterialTheme(
  Brightness brightness, {
  bool highContrast = false,
}) {
  final colors = AppColors(brightness, highContrast: highContrast);
  final dark = brightness == Brightness.dark;

  final scheme = ColorScheme(
    brightness: brightness,
    // 强调色：浅色下用白字、深色下用深墨字（见 AppColors.onAccent）。
    primary: colors.accent,
    onPrimary: colors.onAccent,
    primaryContainer: colors.accentSubtle,
    onPrimaryContainer: colors.textPrimary,
    secondary: colors.textSecondary,
    onSecondary: colors.contentSurface,
    // 第三色位不用（避免多一支抢眼颜色），指向中性面。
    tertiary: colors.textSecondary,
    onTertiary: colors.contentSurface,
    // 破坏性操作在 UI 层用措辞 + 确认承载，色板不再单列一支红。
    error: colors.accent,
    onError: colors.onAccent,
    errorContainer: colors.accentSubtle,
    onErrorContainer: colors.textPrimary,
    surface: colors.background,
    onSurface: colors.textPrimary,
    onSurfaceVariant: colors.textSecondary,
    surfaceContainerLowest: colors.sunken,
    surfaceContainerLow: colors.sunken,
    surfaceContainer: colors.contentSurface,
    surfaceContainerHigh: colors.surfaceElevated,
    surfaceContainerHighest: colors.surfaceElevated,
    // 关闭 Material 3 的色调叠加：我们的面色已是最终值，
    // 再叠一层 primary 色调会让暖灰发紫。
    surfaceTint: Colors.transparent,
    outline: colors.divider,
    outlineVariant: colors.divider,
    shadow: dark ? const Color(0x66000000) : const Color(0x14000000),
    scrim: const Color(0x80000000),
    inverseSurface: colors.textPrimary,
    onInverseSurface: colors.background,
    inversePrimary: colors.accent,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    // 语义色板随主题下发：`AppColors.of(context)` 与 Material 组件同源。
    extensions: <ThemeExtension<dynamic>>[colors],
    scaffoldBackgroundColor: colors.background,
    canvasColor: colors.background,
    dividerColor: colors.divider,
    dividerTheme: DividerThemeData(
      color: colors.divider,
      thickness: 1,
      space: 1,
    ),
    // 玻璃面自己承担动效，Material 的水波纹在玻璃上是噪点。
    splashFactory: NoSplash.splashFactory,
    // Notion 风：选中/悬停靠**底色**而非描边或水波纹。
    highlightColor: colors.accentSubtle,
    hoverColor: colors.accentSubtle,
    textTheme: TextTheme(
      displaySmall: AppText.display.copyWith(color: colors.textPrimary),
      titleLarge: AppText.title.copyWith(color: colors.textPrimary),
      titleMedium: AppText.headline.copyWith(color: colors.textPrimary),
      bodyLarge: AppText.body.copyWith(color: colors.textPrimary),
      bodyMedium: AppText.body.copyWith(color: colors.textSecondary),
      bodySmall: AppText.callout.copyWith(color: colors.textSecondary),
      labelSmall: AppText.caption.copyWith(color: colors.textTertiary),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppText.headline.copyWith(color: colors.textPrimary),
      iconTheme: IconThemeData(color: colors.textPrimary, size: 20),
    ),
    iconTheme: IconThemeData(color: colors.textSecondary, size: 20),
    // 列表/卡片默认无「纸片阴影」：Notion 用边界线分层，Apple 用材质分层，
    // 两者都不靠投影——投影只留给真正浮起的功能层（玻璃）。
    cardTheme: CardThemeData(
      color: colors.contentSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: colors.divider),
      ),
    ),
    // 弹层用第三级亮度，与页面和卡片都拉开（HIG dark-mode.md base/elevated）。
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppText.headline.copyWith(color: colors.textPrimary),
      contentTextStyle: AppText.body.copyWith(color: colors.textSecondary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark
          ? colors.surfaceElevated
          : const Color(0xFF2C2A27),
      contentTextStyle: AppText.body.copyWith(
        color: const Color(0xFFF5F3EF),
      ),
      actionTextColor: dark ? colors.accent : const Color(0xFFFF9A90),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      elevation: 0,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.accent,
      linearTrackColor: colors.sunken,
      circularTrackColor: Colors.transparent,
    ),
  );
}

/// 由外观设置解析**期望**玻璃档位。
///
/// 降级路径：大字 / 高对比 / 减弱动效任一开启 → 全站降 `minimal`
/// （功能不降级，只降质感）。实际档位仍由 `GlassAdaptiveScope` 天花板钳制，
/// UI 不得假设它稳定。
GlassTier resolveGlassTier(AppearanceSettings appearance) {
  if (appearance.highContrast ||
      appearance.reduceMotion ||
      appearance.largeText) {
    return GlassTier.minimal;
  }
  return platformGlassCeiling();
}
