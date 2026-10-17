import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/core/layout/breakpoints.dart';
import '../ui/core/tokens/app_tokens.dart';
import '../ui/core/widgets/app_nav_bar.dart';
import 'routes.dart';

/// 自适应导航外壳。
///
/// - compact（手机）：底部**浮起玻璃胶囊** Tab 条（距底 16 / 左右内缩 14 / 高 60）；
/// - medium / expanded（平板 / 桌面）：左侧**浮起玻璃侧栏**（一片浮起的圆角
///   玻璃，不是竖切到底的颜色块），内容从它右侧让开。
///
/// 由 `StatefulShellRoute.indexedStack` 驱动，分支切换保留各自滚动位置。
///
/// **导航只出现在四个 Tab 页**：搜索 / 详情 / 播放器是 push 在 shell 之外的
/// 子页，天然不显示导航（返回靠各自左上角的圆钮）。这里只负责四个 Tab 页。
///
/// **内容出血到玻璃之下**：两种档位都用 `Stack`，页面铺满整屏、栏浮在其上，
/// 因此滚动时海报从玻璃下方经过（折射对象成立）。代价是各滚动页必须自己在
/// 尾部留出 [tabPageBottomInset]，否则最后一行会被栏遮住。
class AppNavigationShell extends StatelessWidget {
  const AppNavigationShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _goBranch(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  void _openSearch(BuildContext context) => context.push(AppRoutes.search);

  @override
  Widget build(BuildContext context) {
    final index = navigationShell.currentIndex;
    return AdaptiveLayout(
      compact: (context) => _compact(context, index),
      medium: (context) => _wide(context, index),
      expanded: (context) => _wide(context, index),
    );
  }

  /// 手机档：内容铺满整屏，浮起 Tab 条浮在底部。
  Widget _compact(BuildContext context, int index) {
    final colors = AppColors.of(context);
    final padding = MediaQuery.paddingOf(context);
    return _ShellSurface(
      background: colors.background,
      children: <Widget>[
        Positioned.fill(child: navigationShell),
        Positioned(
          left: AppBottomNavBar.sideInset,
          right: AppBottomNavBar.sideInset,
          bottom: padding.bottom + AppBottomNavBar.bottomInset,
          child: AppBottomNavBar(
            selectedIndex: index,
            onSelected: _goBranch,
            destinations: kMainDestinations,
          ),
        ),
      ],
    );
  }

  /// 宽屏档：浮起玻璃侧栏 + 内容区（内容从侧栏右侧让开）。
  Widget _wide(BuildContext context, int index) {
    final size = Breakpoints.classify(MediaQuery.sizeOf(context).width);
    final colors = AppColors.of(context);
    final padding = MediaQuery.paddingOf(context);
    final railWidth = Breakpoints.railWidth(size);
    final placeholder = Breakpoints.railPlaceholder(size);
    final expanded = size == WindowSizeClass.expanded;

    return _ShellSurface(
      background: colors.background,
      children: <Widget>[
        // 内容区从侧栏右侧让开（侧栏本身浮在画布上、不参与内容布局）。
        Positioned(
          left: placeholder,
          top: 0,
          right: 0,
          bottom: 0,
          child: navigationShell,
        ),
        Positioned(
          left: AppSpacing.railInset,
          top: padding.top + AppSpacing.railInset,
          bottom: padding.bottom + AppSpacing.railInset,
          child: AppSideRail(
            selectedIndex: index,
            onSelected: _goBranch,
            width: railWidth,
            showBrand: expanded,
            onSearch: () => _openSearch(context),
            onSettings: () => context.push(AppRoutes.settings),
          ),
        ),
      ],
    );
  }
}

/// 外壳的公共底：一层纯色画布 + `Material` 兜底文本样式 + 若干浮起层。
///
/// `Material(type: MaterialType.transparency)` 不可删：`MaterialApp` 在根部把
/// `_errorTextStyle`（红色等宽 + 黄色双下划线）装成兜底 `DefaultTextStyle`，
/// 直接摆放在此之外的 `Text`（栏里的标题 / 标签）会继承它，
/// 实机表现是标签下方出现黄色双下划线（回归用例见
/// `test/glass_text_style_test.dart`）。
class _ShellSurface extends StatelessWidget {
  const _ShellSurface({required this.children, required this.background});

  final List<Widget> children;
  final Color background;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: ColoredBox(
      color: background,
      child: Stack(children: children),
    ),
  );
}
