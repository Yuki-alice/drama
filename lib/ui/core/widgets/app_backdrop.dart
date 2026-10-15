import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 玻璃背后的页面背景（可折射的柔和渐变）。
///
/// 内容层（海报墙 / 视频画面）一律不透明，因此这层背景只在功能层
/// （栏 / 条 / 卡）下方可见并供玻璃折射。
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            colors.backdropWarm,
            colors.background,
            colors.backdropCool,
          ],
          stops: const <double>[0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}
