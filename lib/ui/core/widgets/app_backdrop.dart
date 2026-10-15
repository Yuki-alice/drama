import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 玻璃背后的页面背景。
///
/// **克制**：Notion 风的页面是**一层纸**，不是彩色渐变。这里只做两处极轻的
/// 暖/冷晕染（左上暖、右下冷），亮度差 <2%，作用是给玻璃一点可折射的层次，
/// 而不是自己成为视觉主角——彩色底会把玻璃染脏，也会与海报墙抢注意力。
///
/// 内容层（海报墙 / 视频画面）一律不透明，因此这层只在功能层
/// （栏 / 条 / 卡）下方可见。高对比 / 减弱透明度下退化为纯色。
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final media = MediaQuery.maybeOf(context);
    // 减弱透明度：不画晕染，直接纯色（避免色带在低色深屏上被放大）。
    final reduceTransparency = media?.disableAnimations ?? false;
    if (reduceTransparency || colors.highContrast) {
      return ColoredBox(color: colors.background);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        gradient: RadialGradient(
          center: const Alignment(-0.9, -1.0),
          radius: 1.4,
          colors: <Color>[
            colors.backdropWarm,
            colors.background,
            colors.backdropCool,
          ],
          stops: const <double>[0.0, 0.62, 1.0],
        ),
      ),
    );
  }
}
