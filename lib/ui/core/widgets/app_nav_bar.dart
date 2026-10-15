import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../tokens/app_tokens.dart';

/// 导航目的地（底部栏与侧边栏共用同一份数据）。
@immutable
class AppNavDestination {
  const AppNavDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// 主导航目的地：首页 · 榜单 · 追剧 · 我的（导航骨架）。
const List<AppNavDestination> kMainDestinations = <AppNavDestination>[
  AppNavDestination(
    icon: Icons.local_fire_department_outlined,
    activeIcon: Icons.local_fire_department,
    label: '首页',
  ),
  AppNavDestination(
    icon: Icons.leaderboard_outlined,
    activeIcon: Icons.leaderboard,
    label: '榜单',
  ),
  AppNavDestination(
    icon: Icons.bookmark_border,
    activeIcon: Icons.bookmark,
    label: '追剧',
  ),
  AppNavDestination(
    icon: Icons.person_outline,
    activeIcon: Icons.person,
    label: '我的',
  ),
];

/// 底部玻璃导航栏（compact 档），基于 `GlassTabBar.bottom`。
class AppBottomNavBar extends StatelessWidget {
  const AppBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.destinations = kMainDestinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<AppNavDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GlassTabBar.bottom(
      selectedIndex: selectedIndex,
      onTabSelected: onSelected,
      tabs: <GlassTab>[
        for (final destination in destinations)
          GlassTab(
            icon: Icon(destination.icon),
            activeIcon: Icon(destination.activeIcon),
            label: destination.label,
          ),
      ],
      selectedIconColor: colors.accent,
      unselectedIconColor: colors.textSecondary,
      selectedLabelColor: colors.accent,
      unselectedLabelColor: colors.textSecondary,
    );
  }
}

/// 侧边玻璃导航栏（medium / expanded 档）。
///
/// 内部是**普通行**（非玻璃控件），刻意规避玻璃套玻璃。
class AppSideRail extends StatelessWidget {
  const AppSideRail({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.destinations = kMainDestinations,
    this.width = 232,
    this.footer,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<AppNavDestination> destinations;
  final double width;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GlassContainer(
      width: width,
      padding: const EdgeInsets.all(AppSpacing.sm),
      shape: const LiquidRoundedSuperellipse(borderRadius: AppRadii.xl),
      useOwnLayer: true,
      quality: GlassQuality.standard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.local_fire_department,
                  color: colors.accent,
                  size: 22,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '红果短剧',
                  style: AppText.headline.copyWith(color: colors.textPrimary),
                ),
              ],
            ),
          ),
          for (var index = 0; index < destinations.length; index++)
            _RailItem(
              destination: destinations[index],
              selected: index == selectedIndex,
              onTap: () => onSelected(index),
            ),
          const Spacer(),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: footer!,
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final AppNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        // 选中用低饱和强调底（Notion 风：靠底色而非描边表达选中）。
        color: selected ? colors.accentSubtle : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? destination.activeIcon : destination.icon,
                  size: 20,
                  color: selected ? colors.accent : colors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    destination.label,
                    style: AppText.body.copyWith(
                      color: selected
                          ? colors.textPrimary
                          : colors.textSecondary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
