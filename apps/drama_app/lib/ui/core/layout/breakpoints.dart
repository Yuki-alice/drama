import 'package:flutter/material.dart';

/// 窗口尺寸分级（不锁方向、不判硬件类型——只按可用宽度，ARCH §4.1）。
enum WindowSizeClass {
  /// 手机竖屏：单列。
  compact,

  /// 平板竖屏 / 小窗：分栏。
  medium,

  /// 平板横屏 / 桌面：资料 + 内容双栏。
  expanded,
}

/// 响应式断点（Material 3 窗口尺寸类对齐紧凑值）。
abstract final class Breakpoints {
  /// compact → medium 的分界。
  static const double medium = 600;

  /// medium → expanded 的分界。
  static const double expanded = 1024;

  static WindowSizeClass classify(double width) {
    if (width >= expanded) return WindowSizeClass.expanded;
    if (width >= medium) return WindowSizeClass.medium;
    return WindowSizeClass.compact;
  }
}

/// 按可用宽度切换布局树（用 `LayoutBuilder`，不用 `MediaQuery.orientationOf`）。
///
/// 未提供的档位逐级回退（expanded → medium → compact）。
class AdaptiveLayout extends StatelessWidget {
  const AdaptiveLayout({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
  });

  final WidgetBuilder compact;
  final WidgetBuilder? medium;
  final WidgetBuilder? expanded;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final builder = switch (Breakpoints.classify(constraints.maxWidth)) {
        WindowSizeClass.compact => compact,
        WindowSizeClass.medium => medium ?? compact,
        WindowSizeClass.expanded => expanded ?? medium ?? compact,
      };
      return builder(context);
    },
  );
}

/// 大屏防拉伸：限制最大宽度并居中。
class ContentWidthConstraint extends StatelessWidget {
  const ContentWidthConstraint({
    super.key,
    required this.child,
    this.maxWidth = 960,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
