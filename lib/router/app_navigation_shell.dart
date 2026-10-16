import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/core/layout/breakpoints.dart';
import '../ui/core/tokens/app_tokens.dart';
import '../ui/core/widgets/app_glass_scaffold.dart';
import '../ui/core/widgets/app_nav_bar.dart';
import '../ui/core/widgets/glass_kit.dart';
import 'routes.dart';

/// 自适应导航外壳。
///
/// - compact（手机）：底部 `GlassTabBar.bottom`（iOS 26 浮起玻璃镜片选中态）；
/// - medium / expanded（平板横屏 / 桌面）：左侧**浮动玻璃侧栏** + 内容区。
///
/// 由 `StatefulShellRoute.indexedStack` 驱动，分支切换保留各自滚动位置。
///
/// **`extendBody: true`**：内容出血到玻璃栏之下（设计规范要求「下一行海报在
/// 玻璃 Tab 栏下穿透」）。代价是各滚动页必须自己在尾部留出
/// [kNavBarBottomInset]，否则最后一行会被栏永久遮住——这个常量就在
/// `app_nav_bar.dart` 里，与栏的实际高度同源。
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

  /// 手机档：只有一层玻璃 Scaffold，页面只交出一条滚动视图。
  ///
  /// 顶栏**不设标题**：各页把大标题放进滚动内容里（`PageHead`），
  /// 滚上去才收窄——这是 iOS 26 的两段式读法。顶栏只留各页自己的动作，
  /// 因此这里不传 `title`（各页在自己的 `PageHead` 里给）。
  Widget _compact(BuildContext context, int index) => AppGlassScaffold(
    extendBody: true,
    contentAwareBrightness: true,
    bottomBar: AppBottomNavBar(selectedIndex: index, onSelected: _goBranch),
    body: navigationShell,
  );

  /// 宽屏档：浮动玻璃侧栏 + 内容区。
  ///
  /// 侧栏自身是玻璃；内容区**不加额外的玻璃卡**（玻璃不嵌套），
  /// 只做最大宽度约束防拉伸。
  Widget _wide(BuildContext context, int index) => AppGlassScaffold(
    extendBody: true,
    contentAwareBrightness: true,
    body: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 侧栏上下都留出安全区，避免贴住刘海与 Dock。
          Padding(
            padding: EdgeInsetsDirectional.only(
              top: MediaQuery.paddingOf(context).top + AppSpacing.sm,
              bottom: AppSpacing.lg,
            ),
            child: AppSideRail(
              selectedIndex: index,
              onSelected: _goBranch,
              onSearch: () => _openSearch(context),
              footer: Builder(
                builder: (context) => _RailFooter(
                  onSettings: () => context.push(AppRoutes.settings),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: ContentWidthConstraint(
              maxWidth: AppSpacing.maxWideContentWidth,
              child: navigationShell,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 侧栏底部的常驻项（设置）。
class _RailFooter extends StatelessWidget {
  const _RailFooter({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: GlassActionButton(
          label: '设置',
          icon: Icons.settings_outlined,
          width: double.infinity,
          onTap: onSettings,
        ),
      ),
    ],
  );
}
