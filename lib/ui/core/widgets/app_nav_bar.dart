import 'package:flutter/material.dart';

import '../layout/breakpoints.dart';
import '../tokens/app_tokens.dart';
import 'app_glass_surface.dart';

/// 浮起玻璃 Tab 条占掉的高度（不含系统安全区）。
///
/// 原型：距底 16 + 条高 60 = 76；内容尾部留白取 **96**（多出的 20 是呼吸）。
/// 各滚动页在 `extendBody` 语义下必须自己留出它，否则最后一行会被浮起的
/// 条永久遮住——那是个只在滚到底才暴露的缺陷，很容易漏测。
const double kNavBarBottomInset = 96;

/// 侧栏档的内容底部留白（侧栏在左侧，不遮底，只需呼吸）。
const double kRailPageBottomInset = 30;

/// Tab 页内容区的底部留白，按当前档位取：
/// 手机档留浮起 Tab 条（96 + 安全区），侧栏档只需 30 + 安全区。
double tabPageBottomInset(BuildContext context) {
  final size = Breakpoints.classify(MediaQuery.sizeOf(context).width);
  final base = size == WindowSizeClass.compact
      ? kNavBarBottomInset
      : kRailPageBottomInset;
  return base + MediaQuery.paddingOf(context).bottom;
}

/// 滚动内容尾部净空（`ListView` / `Column` 用）。
///
/// 按档位给：手机档留出浮起 Tab 条，侧栏档只留呼吸——侧栏档不留 96，
/// 否则底部会出现一块无意义的空白。
class NavBarBottomInset extends StatelessWidget {
  const NavBarBottomInset({super.key, this.extra = 0});

  /// 额外留白（视觉呼吸，与净空分开计）。
  final double extra;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: tabPageBottomInset(context) + extra);
}

/// 滚动内容尾部净空（`CustomScrollView` 的 sliver 版）。
class SliverNavBarBottomInset extends StatelessWidget {
  const SliverNavBarBottomInset({super.key, this.extra = 0});

  final double extra;

  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: NavBarBottomInset(extra: extra));
}

/// 导航目的地（底部栏与侧栏共用同一份数据）。
///
/// **选中态 = 图标由线稿切换为实心**（SF Symbols 的 outline → fill）+
/// 文字加粗着色。不做选中胶囊、不做指示器圆点、不做图标下方小横条——
/// 那些都是 Material 的语言（设计宪法第八节）。
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

/// 主导航目的地：发现 · 榜单 · 追剧 · 我的。
///
/// **四个**目的地，搜索不当第五个 tab：短剧的检索频次撑不起一个 tab，
/// 它做成顶栏的常驻圆钮（各页右上角）。
const List<AppNavDestination> kMainDestinations = <AppNavDestination>[
  AppNavDestination(
    icon: Icons.home_outlined,
    activeIcon: Icons.home,
    label: '发现',
  ),
  AppNavDestination(
    icon: Icons.leaderboard_outlined,
    activeIcon: Icons.leaderboard,
    label: '榜单',
  ),
  AppNavDestination(
    icon: Icons.favorite_border,
    activeIcon: Icons.favorite,
    label: '追剧',
  ),
  AppNavDestination(
    icon: Icons.person_outline,
    activeIcon: Icons.person,
    label: '我的',
  ),
];

/// 底部**浮起玻璃胶囊** Tab 条（compact 档）。
///
/// iOS 26 的形态：不贴屏幕底边（距底 16）、左右内缩 14、高 60、圆角 30。
/// 选中态只靠「图标线稿 → 实心 + 文字加粗着色」表达（UITabBar 的语言）。
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

  /// 条高（原型 60）。
  static const double height = 60;

  /// 距屏幕底边（原型 16）。
  static const double bottomInset = 16;

  /// 左右内缩（原型 14）。
  static const double sideInset = 14;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return AppGlassSurface(
      radius: height / 2,
      height: height,
      blur: 22,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: <Widget>[
            for (var index = 0; index < destinations.length; index++)
              Expanded(
                child: _TabItem(
                  destination: destinations[index],
                  selected: index == selectedIndex,
                  onTap: () => onSelected(index),
                  colors: colors,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final AppNavDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final color = selected ? colors.textPrimary : colors.textSecondary;
    return Semantics(
      selected: selected,
      button: true,
      label: destination.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              selected ? destination.activeIcon : destination.icon,
              size: 23,
              color: color,
            ),
            const SizedBox(height: 4),
            Text(
              destination.label,
              style: AppText.caption.copyWith(
                fontSize: 10.5,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 浮起玻璃侧栏（medium / expanded 档）。
///
/// 它是**一片浮起的玻璃**（左 12 / 上 12 / 下 12 内缩、四角 26 圆角、带投影），
/// 不是「一条竖切到顶到底的颜色块」。内容从它右侧让开。
///
/// 内部是**普通行**（非玻璃控件），刻意规避玻璃套玻璃。
class AppSideRail extends StatelessWidget {
  const AppSideRail({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.width,
    this.destinations = kMainDestinations,
    this.onSearch,
    this.onSettings,
    this.showBrand = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 侧栏本体宽度（平板 200 / 桌面 240）。
  final double width;

  final List<AppNavDestination> destinations;

  /// 品牌行下方的搜索入口。
  final VoidCallback? onSearch;

  /// 底部常驻项（设置）。
  final VoidCallback? onSettings;

  /// 桌面档显示品牌行；平板档不显示（原型如此）。
  final bool showBrand;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return AppGlassSurface(
      radius: AppRadii.rail,
      width: width,
      blur: 26,
      thickness: 14,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (showBrand)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
                child: Text(
                  '短剧',
                  style: AppText.title.copyWith(
                    color: colors.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            if (onSearch != null) ...<Widget>[
              _RailSearchRow(onTap: onSearch!, colors: colors),
              const SizedBox(height: AppSpacing.lg),
            ],
            for (var index = 0; index < destinations.length; index++)
              _RailItem(
                destination: destinations[index],
                selected: index == selectedIndex,
                onTap: () => onSelected(index),
                colors: colors,
              ),
            const Spacer(),
            if (onSettings != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: _RailItem(
                  destination: const AppNavDestination(
                    icon: Icons.settings_outlined,
                    activeIcon: Icons.settings,
                    label: '设置',
                  ),
                  selected: false,
                  onTap: onSettings!,
                  colors: colors,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RailSearchRow extends StatelessWidget {
  const _RailSearchRow({required this.onTap, required this.colors});

  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '搜索',
    child: Material(
      color: colors.sunken,
      borderRadius: BorderRadius.circular(AppRadii.thumbnail),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                Icon(Icons.search, size: 16, color: colors.textSecondary),
                const SizedBox(width: 10),
                Text(
                  '搜索',
                  style: AppText.body.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final AppNavDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: destination.label,
    child: Material(
      // 选中 = 中性浅底 + 字重 600（无彩色色板里没有「选中色」可言）。
      color: selected ? colors.selectionFill : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadii.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 46,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? destination.activeIcon : destination.icon,
                  size: 20,
                  color: colors.textPrimary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    destination.label,
                    style: AppText.body.copyWith(
                      fontSize: 15.5,
                      color: colors.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
