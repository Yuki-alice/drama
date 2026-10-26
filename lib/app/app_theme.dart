import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// MD3 形状令牌阶梯（含 Expressive 扩展档）。
/// 参考 m3.material.io 形状系统：extra-small 4 → full(胶囊)。
abstract final class AppShapes {
  static const double extraSmall = 4; // snackbar、小徽章
  static const double small = 8; // 菜单、文本域
  static const double medium = 12; // 列表卡片
  static const double large = 16; // 媒体卡片、FAB
  static const double largeIncreased = 20; // Expressive 卡片
  static const double extraLarge = 28; // 对话框、底部弹层
  static const double panel = 28; // 信息展示面板左侧圆角
  static const double full = 9999; // 胶囊：按钮、chip（Expressive 标志）

  static RoundedRectangleBorder rounded(double radius) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  /// 胶囊形状（Expressive 按钮语言）。
  static const StadiumBorder stadium = StadiumBorder();
}

/// 外壳用的表面色角色：导航层与内容层分层，内容层始终接近纯色。
@immutable
class AppSurfaces extends ThemeExtension<AppSurfaces> {
  const AppSurfaces({
    required this.navContainer,
    required this.canvas,
    required this.onNavContainer,
  });

  /// NavigationRail / NavigationBar / 滚动后的顶栏底色。
  final Color navContainer;

  /// 信息展示面板底色（surfaceContainerLowest）。
  final Color canvas;
  final Color onNavContainer;

  @override
  AppSurfaces copyWith({
    Color? navContainer,
    Color? canvas,
    Color? onNavContainer,
  }) => AppSurfaces(
    navContainer: navContainer ?? this.navContainer,
    canvas: canvas ?? this.canvas,
    onNavContainer: onNavContainer ?? this.onNavContainer,
  );

  @override
  AppSurfaces lerp(covariant AppSurfaces? other, double t) => other == null
      ? this
      : AppSurfaces(
          navContainer: Color.lerp(navContainer, other.navContainer, t)!,
          canvas: Color.lerp(canvas, other.canvas, t)!,
          onNavContainer: Color.lerp(onNavContainer, other.onNavContainer, t)!,
        );

  static AppSurfaces of(BuildContext context) =>
      Theme.of(context).extension<AppSurfaces>()!;
}

/// 8dp 间距系统：布局与组件随设备密度自适应的基础。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// MD3 Expressive 动效令牌：转场用强调曲线 + 规格时长。
/// 参考 m3.material.io/foundations/motion：emphasized 500ms /
/// decelerate(进场) 400ms / accelerate(离场) 200ms。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 350);
  static const Duration emphasized = Duration(milliseconds: 500);
  static const Duration enter = Duration(milliseconds: 400);
  static const Duration exit = Duration(milliseconds: 200);

  static const Curve standard = Curves.easeInOutCubicEmphasized;
  static const Curve decelerate = Curves.easeOutCubic;
  static const Curve accelerate = Curves.easeInCubic;

  /// 组件内弹簧观感（Expressive）：过冲回弹。
  static const Curve spring = Curves.easeOutBack;
}

abstract final class AppTheme {
  static final light = _theme(Brightness.light);
  static final dark = _theme(Brightness.dark);

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String label(String preference) => switch (preference) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    // 导航层与顶栏滚动后的着色；内容层始终使用接近纯色的 canvas。
    final navContainer = dark ? const Color(0xFF251D1B) : const Color(0xFFF4E8E3);
    final canvas = dark ? const Color(0xFF15100F) : const Color(0xFFFFFBF9);
    // Expressive 变体：secondary/tertiary 从种子派生，带来更鲜明的高彩度点缀色；
    // 品牌主色与表面阶梯保持手调，确保视觉延续。
    final expressive = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF664F),
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.expressive,
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF664F),
      brightness: brightness,
      primary: dark ? const Color(0xFFFF765F) : const Color(0xFFAD3826),
      onPrimary: dark ? const Color(0xFF3B0E07) : Colors.white,
      primaryContainer: dark
          ? const Color(0xFF5C3027)
          : const Color(0xFFFFDBD2),
      onPrimaryContainer: dark
          ? const Color(0xFFFFE0D8)
          : const Color(0xFF410001),
      secondary: expressive.secondary,
      onSecondary: expressive.onSecondary,
      secondaryContainer: dark
          ? const Color(0xFF5D3E38)
          : const Color(0xFFFFD6CA),
      onSecondaryContainer: dark
          ? const Color(0xFFFFD6CA)
          : const Color(0xFF2C150F),
      tertiary: dark ? const Color(0xFFF6C86B) : const Color(0xFF805500),
      onTertiary: dark ? const Color(0xFF412D00) : Colors.white,
      tertiaryContainer: dark
          ? const Color(0xFF614000)
          : const Color(0xFFFFDCA8),
      onTertiaryContainer: dark
          ? const Color(0xFFFFDCA8)
          : const Color(0xFF281800),
      error: expressive.error,
      onError: expressive.onError,
      errorContainer: expressive.errorContainer,
      onErrorContainer: expressive.onErrorContainer,
      surface: canvas,
      onSurface: dark ? const Color(0xFFF1DFDA) : const Color(0xFF251A17),
      onSurfaceVariant: dark
          ? const Color(0xFFD3BEB7)
          : const Color(0xFF5D4C47),
      outline: dark ? const Color(0xFF9D8A84) : const Color(0xFF8A766F),
      outlineVariant: dark ? const Color(0xFF4C3F3B) : const Color(0xFFE3D3CD),
      surfaceContainerLowest: canvas,
      surfaceContainerLow: dark
          ? const Color(0xFF1D1715)
          : const Color(0xFFFAF3F0),
      surfaceContainer: navContainer,
      surfaceContainerHigh: dark
          ? const Color(0xFF302724)
          : const Color(0xFFECE1DC),
      surfaceContainerHighest: dark
          ? const Color(0xFF3B322F)
          : const Color(0xFFE4D9D4),
      surfaceDim: dark ? const Color(0xFF100D0C) : const Color(0xFFDED5D0),
      surfaceBright: dark ? const Color(0xFF3B3330) : const Color(0xFFFFFBF9),
      inverseSurface: dark ? const Color(0xFFE9E7EA) : const Color(0xFF30313A),
      onInverseSurface: dark
          ? const Color(0xFF2F3033)
          : const Color(0xFFF2F0F4),
      inversePrimary: dark ? const Color(0xFFAD3826) : const Color(0xFFFFB4A2),
      surfaceTint: Colors.transparent,
    );
    final background = canvas;
    // Expressive 排版：标题与标签档加粗强调（emphasized typescale 观感）。
    final emphasizedTextTheme = ThemeData(brightness: brightness).textTheme
        .copyWith(
          titleLarge: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
          titleMedium: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: .1,
          ),
          titleSmall: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: .1,
          ),
          labelLarge: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: .1,
          ),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      extensions: [
        AppSurfaces(
          navContainer: navContainer,
          canvas: canvas,
          onNavContainer: scheme.onSurface,
        ),
      ],
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      textTheme: emphasizedTextTheme,
      // Expressive motion：统一页面转场（强调曲线 fade-through）。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      // —— 组件主题：Expressive 胶囊按钮 + 令牌化形状 ——
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: AppShapes.stadium,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: AppShapes.stadium,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: AppShapes.stadium,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: AppShapes.stadium),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: AppShapes.stadium),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
        selectedColor: scheme.secondaryContainer,
        checkmarkColor: scheme.onSecondaryContainer,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        shape: AppShapes.rounded(AppShapes.largeIncreased),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: AppShapes.rounded(AppShapes.extraLarge),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppShapes.extraLarge),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        shape: AppShapes.rounded(AppShapes.extraSmall),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        shape: AppShapes.rounded(AppShapes.small),
        elevation: 2,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 80,
        backgroundColor: navContainer,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: navContainer,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelType: NavigationRailLabelType.all,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
          color: scheme.onSurface,
        ),
        systemOverlayStyle: systemBars(brightness),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
        indicatorSize: TabBarIndicatorSize.label,
      ),
      listTileTheme: ListTileThemeData(
        shape: AppShapes.rounded(AppShapes.large),
        iconColor: scheme.onSurfaceVariant,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.extraLarge),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.extraLarge),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: .08),
      ),
    );
  }
}
