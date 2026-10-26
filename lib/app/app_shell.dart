import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/core/responsive/window_type.dart';

/// 应用外壳：导航层位于最底，信息展示面板浮在其上（仅左侧圆角）。
/// 紧凑宽度改用底部 NavigationBar，与 Animeko 的 NavigationSuite 行为一致。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  static const _destinations = [
    (icon: Icons.explore_outlined, selected: Icons.explore, label: '发现'),
    (icon: Icons.bookmark_border_rounded, selected: Icons.bookmark_rounded, label: '追剧'),
    (icon: Icons.person_outline_rounded, selected: Icons.person_rounded, label: '我的'),
  ];

  void _select(BuildContext context, int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final rail = windowTypeOfContext(context).useNavigationRail;
    return ColoredBox(
      color: surfaces.navContainer,
      child: Row(
        children: [
          if (rail)
            SizedBox(
              width: 96,
              child: NavigationRail(
                selectedIndex: navigationShell.currentIndex,
                onDestinationSelected: (index) => _select(context, index),
                groupAlignment: -0.75,
                leading: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: FloatingActionButton(
                    key: const ValueKey('rail-search'),
                    onPressed: () => context.push('/search'),
                    tooltip: '搜索',
                    child: const Icon(Icons.search_rounded),
                  ),
                ),
                destinations: [
                  for (final item in _destinations)
                    NavigationRailDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selected),
                      label: Text(item.label),
                    ),
                ],
              ),
            ),
          Expanded(
            child: ClipRRect(
              borderRadius: rail
                  ? const BorderRadius.horizontal(
                      left: Radius.circular(AppShapes.panel),
                    )
                  : BorderRadius.zero,
              child: ColoredBox(
                color: surfaces.canvas,
                child: Column(
                  children: [
                    Expanded(child: navigationShell),
                    if (!rail)
                      NavigationBar(
                        key: const ValueKey('bottom-navigation'),
                        selectedIndex: navigationShell.currentIndex,
                        onDestinationSelected: (index) =>
                            _select(context, index),
                        destinations: [
                          for (final item in _destinations)
                            NavigationDestination(
                              icon: Icon(item.icon),
                              selectedIcon: Icon(item.selected),
                              label: item.label,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
