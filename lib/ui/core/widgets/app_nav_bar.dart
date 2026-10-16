import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../motion/app_motion.dart';
import '../tokens/app_tokens.dart';

/// 底部玻璃栏占掉的高度（**不含**系统安全区）。
///
/// 与 `AppBottomNavBar` 的实际高度同源：`GlassTabBar.bottom` 的
/// `preferredSize` = `barHeight + verticalPadding * 2`，其中
/// `verticalPadding` 包内默认为 20。各滚动页用
/// `kNavBarBottomInset + MediaQuery.paddingOf(context).bottom`
/// 做内容尾部的净空。
///
/// **为什么必须集中一处**：内容出血到栏下（`extendBody: true`）时，
/// 每一页都要自己留净空；任何一页少留，最后一行就被栏永久遮住——
/// 那是个只在滚到底部才出现的缺陷，很容易漏测。
const double kNavBarBottomInset = 64 + 20 * 2;

/// 内容尾部的净空高度（栏 + 系统安全区）。
///
/// 出血到栏下的滚动页**必须**在内容末尾留出它，否则最后一行会被栏
/// 永久遮住——滚到底才暴露的缺陷。
double navBarBottomClearance(BuildContext context) =>
    kNavBarBottomInset + MediaQuery.paddingOf(context).bottom;

/// 滚动内容尾部的净空（`ListView` / `Column` 用）。
class NavBarBottomInset extends StatelessWidget {
  const NavBarBottomInset({super.key, this.extra = AppSpacing.lg});

  /// 额外留白（视觉呼吸，与净空分开计）。
  final double extra;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: navBarBottomClearance(context) + extra);
}

/// 滚动内容尾部的净空（`CustomScrollView` 的 sliver 版）。
class SliverNavBarBottomInset extends StatelessWidget {
  const SliverNavBarBottomInset({super.key, this.extra = AppSpacing.lg});

  final double extra;

  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: NavBarBottomInset(extra: extra));
}

/// 导航目的地（底部栏与侧栏共用同一份数据）。
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

/// 主导航目的地：首页 · 榜单 · 追剧 · 我的。
///
/// **四个**目的地，搜索不当第五个 tab：短剧的检索频次撑不起一个 tab，
/// 它做成顶栏的常驻玻璃圆钮（各页右上角）。
/// 见 HIG `tab-bars.md`：tab 用于导航而非动作，且应少而稳定。
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

/// 底部玻璃导航栏（compact 档）。
///
/// **选中态是「浮起玻璃镜片」而不是实心胶囊**：
/// 白色 92% 底 + 1px 墨色 8% 描边 + 柔和投影，图标与文字转为墨黑并加粗；
/// 未选中保持石墨色。这是 iOS 26 的读法——选中项是**浮在栏上的一片玻璃**，
/// 而不是被涂黑的按钮。
///
/// 之所以此前用实心黑：色板里只有一个「强调色」，而强调色如今就是墨色，
/// 于是「选中＝涂黑」会让选中项和栏本体一样黑、反而看不出来。镜片方案
/// 靠**明度差 + 描边 + 投影**表达选中，在纯中性色板下才成立。
class AppBottomNavBar extends StatelessWidget {
  const AppBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.destinations = kMainDestinations,
    this.barHeight = 64,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<AppNavDestination> destinations;
  final double barHeight;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final dark = colors.brightness == Brightness.dark;

    // 镜片底色：浅色下白 92%，深色下用低透明白（深色场景的「浮起」同样是亮面，
    // 只是幅度小得多，否则会在暗底上炸出一个白块）。
    final lens = dark
        ? Colors.white.withValues(alpha: .18)
        : Colors.white.withValues(alpha: .92);

    // 柔和投影（0,2,10,10%）：镜片「浮在栏上」的全部依据。
    // 深色下投影几乎不可见，改由 1px 亮描边承担分层——
    // 这是深色界面里唯一能表达「浮起」的手段。
    final shadow = dark
        ? const <BoxShadow>[
            BoxShadow(
              color: Color(0x1FFFFFFF),
              blurRadius: 1,
              spreadRadius: 0,
              offset: Offset(0, 0),
            ),
          ]
        : const <BoxShadow>[
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 10,
              spreadRadius: 0,
              offset: Offset(0, 2),
            ),
          ];

    return GlassTabBar.bottom(
      selectedIndex: selectedIndex,
      onTabSelected: onSelected,
      tabs: <GlassTab>[
        for (final destination in destinations)
          GlassTab(
            icon: Icon(destination.icon),
            activeIcon: Icon(destination.activeIcon),
            label: destination.label,
            semanticLabel: destination.label,
          ),
      ],
      barHeight: barHeight,
      showIndicator: true,
      indicatorColor: lens,
      indicatorSettings: LiquidGlassSettings(
        glassColor: lens,
        // 镜片是**折射透镜**：blur 由包内强制为 0（BackdropFilter 会毁掉
        // SDF 边缘），这里只调厚度与高光度，让边缘有一圈可见的玻璃口沿。
        thickness: 7,
        lightIntensity: dark ? .55 : 1.0,
        shadow: shadow,
        shadowElevation: 0,
      ),
      indicatorBorderRadius: AppSpacing.minTapTarget / 2,
      indicatorExpansion: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 6,
      ),
      // 选中：墨黑加粗；未选中：石墨。纯中性色板下这是唯一的对比手段
      // （没有彩色可以借来标记选中）。
      selectedIconColor: colors.textPrimary,
      selectedLabelColor: colors.textPrimary,
      unselectedIconColor: colors.textSecondary,
      unselectedLabelColor: colors.textSecondary,
      selectedLabelStyle: AppText.caption.copyWith(
        color: colors.textPrimary,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelStyle: AppText.caption.copyWith(
        color: colors.textSecondary,
        fontWeight: FontWeight.w500,
      ),
      // 栏体采样背后内容的明暗（需 `GlassScaffold.contentAwareBrightness: true`
      // 才真的采到东西），否则海报墙滚过时栏上的字会忽明忽暗地糊掉。
      adaptiveBrightness: true,
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
    this.width = AppSpacing.sideRailWidth,
    this.footer,
    this.onSearch,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<AppNavDestination> destinations;
  final double width;

  /// 侧栏底部的常驻项（设置）。
  final Widget? footer;

  /// 品牌行下方的搜索入口。
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GlassContainer(
      width: width,
      padding: const EdgeInsets.all(AppSpacing.sm),
      shape: LiquidRoundedSuperellipse(borderRadius: AppRadii.xl),
      useOwnLayer: true,
      quality: GlassQuality.standard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 品牌行：棋子 + 字标。全站唯一的「logo」出现处
          // （HIG `branding.md`：标志不重复）。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 18,
                    color: colors.onAccent,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '红果短剧',
                    style: AppText.headline.copyWith(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          if (onSearch != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: _RailSearchTile(onTap: onSearch!),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
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

/// 侧栏里的搜索入口（内容层行，不是玻璃控件）。
class _RailSearchTile extends StatelessWidget {
  const _RailSearchTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: '搜索',
      child: Material(
        color: colors.sunken,
        borderRadius: BorderRadius.circular(AppRadii.capsule),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.search, size: 18, color: colors.textSecondary),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '搜索',
                  style: AppText.callout.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ),
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
      child: Semantics(
        // 侧栏不是 tab bar，但语义上仍是「一组互斥的导航项」。
        selected: selected,
        button: true,
        label: destination.label,
        child: Material(
          // 选中用墨色浅底（靠底色而非描边表达选中，与玻璃镜片同一逻辑）。
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
                    color: selected ? colors.textPrimary : colors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      destination.label,
                      style: AppText.body.copyWith(
                        color: selected
                            ? colors.textPrimary
                            : colors.textSecondary,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
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
}

/// 常驻播放胶囊（坐在玻璃 Tab 栏**上方**）。
///
/// 它是**内容层**，所以刻意不做成玻璃：TabBar 已经是玻璃，
/// 玻璃套玻璃会静默降质（无 blur 无折射）。iOS 26 的 play pill 之所以
/// 看着和栏是一体的，是因为它**共用同一层的采样背景**，不是因为它自己
/// 又是一块玻璃。这里用与主题同源的半透明面 + 顶部一条发丝高光来贴住观感。
///
/// 进度线常驻：不点开播放器也知道追到哪了。
class PlayAccessory extends StatelessWidget {
  const PlayAccessory({
    super.key,
    required this.title,
    required this.subtitle,
    required this.fraction,
    required this.playing,
    required this.onTap,
    required this.onTogglePlay,
    this.onNext,
    this.cover,
    this.seed = '',
  });

  final String title;
  final String subtitle;

  /// 0–1 进度。
  final double fraction;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback onTogglePlay;
  final VoidCallback? onNext;
  final String? cover;
  final String seed;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: PressableScale(
        scale: .98,
        borderRadius: AppRadii.lg,
        onTap: onTap,
        semanticLabel: '$title，$subtitle',
        semanticHint: '双击回到播放器',
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: colors.surfaceElevated.withValues(alpha: .9),
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(color: colors.divider),
          ),
          child: Stack(
            children: <Widget>[
              Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    child: SizedBox(
                      height: 40,
                      width: 30,
                      child: DramaCoverThumb(seed: seed, cover: cover, title: title),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.headline.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono.copyWith(
                            color: colors.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _PillButton(
                    icon: playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    label: playing ? '暂停' : '播放',
                    onTap: onTogglePlay,
                  ),
                  if (onNext != null)
                    _PillButton(
                      icon: Icons.skip_next_rounded,
                      label: '下一集',
                      onTap: onNext!,
                    ),
                ],
              ),
              // 发丝进度线：贴着胶囊底边。
              PositionedDirectional(
                start: AppSpacing.sm,
                end: AppSpacing.sm,
                bottom: 0,
                child: HairlineProgress(
                  fraction: fraction,
                  track: colors.divider,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 播放胶囊里的小封面（内容层，不透明）。
///
/// 单独抽出来是因为这里只需「有色块」——真实封面由调用方给 URL，
/// 没有就回落确定性渐变，且**不叠加标题**（30×40 pt 里塞标题只会糊）。
class DramaCoverThumb extends StatelessWidget {
  const DramaCoverThumb({
    super.key,
    required this.seed,
    this.cover,
    this.title,
  });

  final String seed;
  final String? cover;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final hue = seed.hashCode.abs() % 360;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            HSLColor.fromAHSL(
              1,
              hue.toDouble(),
              colors.highContrast ? 0.0 : 0.28,
              colors.brightness == Brightness.dark ? 0.3 : 0.72,
            ).toColor(),
            HSLColor.fromAHSL(
              1,
              ((hue + 30) % 360).toDouble(),
              colors.highContrast ? 0.0 : 0.3,
              colors.brightness == Brightness.dark ? 0.2 : 0.6,
            ).toColor(),
          ],
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 44×44：可点区下限，不是装饰尺寸。
    return Semantics(
      button: true,
      label: label,
      child: PressableScale(
        scale: .88,
        onTap: onTap,
        child: SizedBox(
          height: AppSpacing.minTapTarget,
          width: AppSpacing.minTapTarget,
          child: Icon(icon, color: colors.textPrimary, size: 24),
        ),
      ),
    );
  }
}
