import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../router/app_router.dart';
import '../ui/core/theme/app_theme.dart';
import '../ui/core/theme/appearance_controller.dart';
import '../ui/core/tokens/glass_tier.dart';

/// 应用根（ARCH §4「MaterialApp 三件套」）。
///
/// - `brightnessResolver: Theme.maybeBrightnessOf`——MaterialApp 下必需，
///   否则 `ThemeMode` 与系统亮度不一致时玻璃的阴影/边框会丢失；
/// - `adaptiveQuality: true`——插入 `GlassAdaptiveScope`，档位随设备能力钳制；
/// - `GlassTheme`——按 [resolveGlassTier] 给出三档玻璃 token。
class DramaApp extends ConsumerWidget {
  const DramaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final router = ref.watch(appRouterProvider);
    final glassTier = resolveGlassTier(appearance);

    return MaterialApp.router(
      title: '红果短剧',
      debugShowCheckedModeBanner: false,
      theme: buildMaterialTheme(Brightness.light),
      darkTheme: buildMaterialTheme(Brightness.dark),
      highContrastTheme: buildMaterialTheme(
        Brightness.light,
        highContrast: true,
      ),
      highContrastDarkTheme: buildMaterialTheme(
        Brightness.dark,
        highContrast: true,
      ),
      themeMode: appearance.themeMode,
      routerConfig: router,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            // 大字模式（F-09）：不改动系统缩放时保持原样。
            textScaler: appearance.textScale == 1.0
                ? media.textScaler
                : TextScaler.linear(appearance.textScale),
            disableAnimations: appearance.reduceMotion,
          ),
          child: LiquidGlassWidgets.wrap(
            child: child ?? const SizedBox.shrink(),
            adaptiveQuality: true,
            brightnessResolver: Theme.maybeBrightnessOf,
            theme: buildGlassThemeData(glassTier),
          ),
        );
      },
    );
  }
}
