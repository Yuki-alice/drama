import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';
import '../tokens/glass_tier.dart';
import 'appearance_controller.dart';

/// Material 主题。
///
/// 只负责 Material 侧的配色与字体——玻璃侧由 `GlassTheme` 另外提供
/// （见 [buildGlassThemeData]）。
///
/// **为什么不用 `ColorScheme.fromSeed`，也不用任何强调色**：色板是无彩色的，
/// 所有交互态（开关 / 勾选 / 焦点 / 加载 / 选中）都指向**墨色**——层级靠
/// 字重、填充与面积表达，不靠颜色。颜色只由内容（封面）提供
/// （见 `cover_palette.dart`）。因此 [ColorScheme] 显式构造、只保留真正
/// 会用到的角色，所有容器色指向中性面。
ThemeData buildMaterialTheme(
  Brightness brightness, {
  bool highContrast = false,
}) {
  final colors = AppColors(brightness, highContrast: highContrast);
  final dark = brightness == Brightness.dark;

  final scheme = ColorScheme(
    brightness: brightness,
    // Material 的「主色」= 墨：开关 / 勾选 / 焦点 / 加载这类交互态会取它。
    // 「选中」在无彩色色板里就是「涂成墨 + 反白」——没有第二支颜色可用。
    primary: colors.textPrimary,
    onPrimary: colors.onInk,
    primaryContainer: colors.selectionFill,
    onPrimaryContainer: colors.textPrimary,
    secondary: colors.textSecondary,
    onSecondary: colors.background,
    // 第三色位不用，指向中性面。
    tertiary: colors.textSecondary,
    onTertiary: colors.background,
    // 破坏性操作在 UI 层用措辞 + 确认承载，色板不再单列一支红。
    // 错误也指向墨：ErrorView 用图标形状 + 措辞表达，不靠颜色。
    error: colors.textPrimary,
    onError: colors.onInk,
    errorContainer: colors.selectionFill,
    onErrorContainer: colors.textPrimary,
    surface: colors.background,
    onSurface: colors.textPrimary,
    onSurfaceVariant: colors.textSecondary,
    surfaceContainerLowest: colors.sunken,
    surfaceContainerLow: colors.sunken,
    surfaceContainer: colors.contentSurface,
    surfaceContainerHigh: colors.surfaceElevated,
    surfaceContainerHighest: colors.surfaceElevated,
    // 关闭 Material 3 的色调叠加：面色已是最终值，
    // 再叠一层 primary 色调会让纯中性面发紫。
    surfaceTint: Colors.transparent,
    outline: colors.divider,
    outlineVariant: colors.divider,
    shadow: dark ? const Color(0x66000000) : const Color(0x14000000),
    scrim: const Color(0x80000000),
    inverseSurface: colors.textPrimary,
    onInverseSurface: colors.background,
    inversePrimary: colors.textPrimary,
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
    // 发丝线：HIG 的分隔线语义（1px，不参与布局间距）。
    dividerTheme: DividerThemeData(
      color: colors.divider,
      thickness: 1,
      space: 1,
    ),
    // 玻璃面自己承担动效，Material 的水波纹在玻璃上是噪点。
    splashFactory: NoSplash.splashFactory,
    // 选中 / 悬停靠**中性浅雾底**而非描边或水波纹。
    highlightColor: colors.selectionFill,
    hoverColor: colors.selectionFill,
    focusColor: colors.selectionFill,
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
      titleTextStyle: AppText.barTitle.copyWith(color: colors.textPrimary),
      iconTheme: IconThemeData(color: colors.textPrimary, size: 20),
    ),
    iconTheme: IconThemeData(color: colors.textSecondary, size: 20),
    // 列表 / 卡片默认**无描边、无阴影、无容器色差**：分层靠排版与负空间
    // （见设计宪法第四节「分层靠排版与负空间」）。
    cardTheme: const CardThemeData(
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    // 弹层用更高一级的面 + 大圆角（弹层 28，见 AppRadii.sheet）。
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppText.headline.copyWith(color: colors.textPrimary),
      contentTextStyle: AppText.body.copyWith(color: colors.textSecondary),
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(AppRadii.sheet),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: colors.surfaceElevated,
      elevation: 0,
      shape: const RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      // snack 在两种外观下都是「屏幕上方的临时层」：
      // 浅色下用墨面（`#0F0F0F`），深色下用抬高面，都保证其上文字可读。
      backgroundColor: dark ? colors.surfaceElevated : const Color(0xFF0F0F0F),
      contentTextStyle: AppText.body.copyWith(
        color: dark ? colors.textPrimary : const Color(0xFFECECEC),
      ),
      // 无彩色色板下动作文字不再取绿，取与正文同源的亮色。
      actionTextColor: dark ? colors.textPrimary : const Color(0xFFECECEC),
      behavior: SnackBarBehavior.floating,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      elevation: 0,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.textPrimary,
      linearTrackColor: colors.sunken,
      circularTrackColor: Colors.transparent,
    ),
    // 内容页统一用 iOS 侧滑（可手势返回）；播放器这类「整窗接管」的路由
    // 自己标 `fullscreenDialog: true`。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
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
