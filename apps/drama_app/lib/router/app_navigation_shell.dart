import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/core/layout/breakpoints.dart';
import '../ui/core/tokens/app_tokens.dart';
import '../ui/core/widgets/app_glass_scaffold.dart';
import '../ui/core/widgets/app_nav_bar.dart';
import '../ui/core/widgets/glass_kit.dart';
import 'routes.dart';

/// 自适应导航外壳（ARCH §4.1 导航骨架）。
///
/// - compact（手机竖屏）：底部 `GlassTabBar.bottom`；
/// - medium / expanded（平板横屏 / 桌面）：左侧 [AppSideRail] + 内容区。
///
/// 由 `StatefulShellRoute.indexedStack` 驱动，分支切换保留各自滚动位置——
/// 满足「切类/切主题不丢状态」的 W1 出口条件。
class AppNavigationShell extends StatelessWidget {
  const AppNavigationShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const List<String> _titles = <String>['首页', '榜单', '追剧', '我的'];

  void _goBranch(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final index = navigationShell.currentIndex;
    return AdaptiveLayout(
      compact: (context) => _compact(context, index),
      medium: (context) => _wide(context, index),
      expanded: (context) => _wide(context, index),
    );
  }

  Widget _compact(BuildContext context, int index) => AppGlassScaffold(
    title: _titles[index],
    actions: _actions(index),
    bottomBar: AppBottomNavBar(selectedIndex: index, onSelected: _goBranch),
    body: navigationShell,
  );

  Widget _wide(BuildContext context, int index) => AppGlassScaffold(
    title: _titles[index],
    actions: _actions(index),
    body: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.gutter,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppSideRail(selectedIndex: index, onSelected: _goBranch),
          const SizedBox(width: AppSpacing.lg),
          Expanded(child: ContentWidthConstraint(child: navigationShell)),
        ],
      ),
    ),
  );

  List<Widget>? _actions(int index) {
    if (index != 0) return null;
    return <Widget>[
      Builder(
        builder: (context) => GlassIconAction(
          icon: Icons.search,
          semanticLabel: '搜索',
          onPressed: () => context.push(AppRoutes.search),
        ),
      ),
    ];
  }
}
