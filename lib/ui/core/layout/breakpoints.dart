import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 窗口尺寸分级（不锁方向、不判硬件类型——只按可用宽度）。
enum WindowSizeClass {
  /// 手机档：浮起玻璃 Tab 条。
  compact,

  /// 平板档：浮起玻璃侧栏（200）。
  medium,

  /// 桌面档：浮起玻璃侧栏（240）。
  expanded,
}

/// 响应式断点与**连续密度公式**。
///
/// 密度不按硬编码的列数断点跳变（那会在大屏上突然跳列），而按
/// 「目标卡宽」连续计算——与 Kazumi `search_page.dart` 同思路：
///
/// ```text
/// 可用宽 = 窗口宽 − 侧栏占位 − 左右 gutter（再被 kGridMaxWidth 封顶）
/// 列数   = clamp(floor(可用宽 / kTargetCardWidth), 3, 8)
/// ```
///
/// 原型实测值（可直接当 golden 断言）：
///
/// | 档位 | 窗口宽 | 侧栏占位 | gutter×2 | 可用宽 | 列数 | 单格 |
/// |---|---|---|---|---|---|---|
/// | 手机 | 390 | 0 | 32 | 358 | 3 | 111pt |
/// | 平板 | 834 | 224 | 48 | 562 | 4 | 132pt |
/// | 桌面 | 1280 | 264 | 68 | 948 | 6 | 149pt |
abstract final class Breakpoints {
  /// compact → medium 的分界。
  static const double medium = 600;

  /// medium → expanded 的分界。
  static const double expanded = 1024;

  /// 目标单卡宽度（列数由此连续推出）。
  static const double kTargetCardWidth = 140;

  /// 网格最大宽度。列数必须按**实际渲染宽**算，不是按窗口宽——
  /// 否则桌面档会算出 8 列但只有 1120px 可放。
  static const double kGridMaxWidth = 1120;

  /// 网格间距（原型 `.grid{gap:12px}`）。单格宽的算式依赖它，故与列数同处。
  static const double kGridGap = 12;

  static WindowSizeClass classify(double width) {
    if (width >= expanded) return WindowSizeClass.expanded;
    if (width >= medium) return WindowSizeClass.medium;
    return WindowSizeClass.compact;
  }

  /// 该档位下浮起玻璃侧栏的**本体宽度**（手机档为 0，无侧栏）。
  static double railWidth(WindowSizeClass size) => switch (size) {
    WindowSizeClass.compact => 0,
    WindowSizeClass.medium => 200,
    WindowSizeClass.expanded => 240,
  };

  /// 侧栏占位 = 侧栏宽 + 24（浮起玻璃片左留 12、与内容之间再留 12）。
  ///
  /// 手机档无侧栏，占位 0。
  static double railPlaceholder(WindowSizeClass size) {
    final width = railWidth(size);
    return width > 0 ? width + 24 : 0;
  }

  /// 页面左右边距：手机 16 / 平板 24 / 桌面 34。
  static double gutter(WindowSizeClass size) => switch (size) {
    WindowSizeClass.compact => 16,
    WindowSizeClass.medium => 24,
    WindowSizeClass.expanded => 34,
  };

  /// 网格的实际可用宽：窗口宽 − 侧栏占位 − 左右 gutter，再被
  /// [kGridMaxWidth] 封顶。
  static double gridAvailableWidth(WindowSizeClass size, double windowWidth) {
    final raw = windowWidth - railPlaceholder(size) - gutter(size) * 2;
    return math.min(math.max(raw, 0), kGridMaxWidth);
  }

  /// 连续公式：目标卡宽 140pt，下限 3 列（手机），上限 8 列（超宽屏）。
  static int feedColumns(double availableWidth) =>
      (availableWidth / kTargetCardWidth).floor().clamp(3, 8);

  /// 由窗口宽直接算出列数（含侧栏占位与 gutter 的完整链路）。
  static int feedColumnsForSize(WindowSizeClass size, double windowWidth) =>
      feedColumns(gridAvailableWidth(size, windowWidth));

  /// 单格实际宽度（供断言与自定义布局用）。
  static double cellWidth(WindowSizeClass size, double windowWidth) {
    final available = gridAvailableWidth(size, windowWidth);
    final columns = feedColumns(available);
    return (available - kGridGap * (columns - 1)) / columns;
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
    this.maxWidth = AppSpacing.listMaxWidth,
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
