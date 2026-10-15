import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 内容层海报（必须不透明）。
///
/// W1 用**确定性渐变 + 标题排版**代替真封面：避免网络/资源依赖，利于
/// widget 测试与离线运行；W2 接真数据后替换为网络封面 + 磁盘缓存（Q30）。
class PosterArtwork extends StatelessWidget {
  const PosterArtwork({
    super.key,
    required this.seed,
    this.title,
    this.aspectRatio = 3 / 4,
    this.radius = AppRadii.lg,
  });

  /// 决定颜色的种子（通常传 `Drama.coverSeed`）。
  final String seed;

  /// 海报上的标题（为 null 时只画渐变）。
  final String? title;

  final double aspectRatio;
  final double radius;

  @override
  Widget build(BuildContext context) {
    // 用 hashCode 取色相，保证同一剧目每次渲染颜色一致。
    final hue = seed.hashCode.abs() % 360;
    final top = HSLColor.fromAHSL(1, hue.toDouble(), 0.58, 0.46).toColor();
    final bottom = HSLColor.fromAHSL(
      1,
      ((hue + 42) % 360).toDouble(),
      0.62,
      0.20,
    ).toColor();
    final borderRadius = BorderRadius.circular(radius);

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[top, bottom],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 底部 scrim：保证标题在任何渐变底色上都可读。
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0x00000000), Color(0xA6000000)],
                  ),
                ),
              ),
              if (title != null)
                Positioned(
                  left: AppSpacing.sm,
                  right: AppSpacing.sm,
                  bottom: AppSpacing.sm,
                  child: Text(
                    title!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.callout.copyWith(
                      color: const Color(0xFFFFFFFF),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
