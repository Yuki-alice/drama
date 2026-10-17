import 'package:flutter/material.dart';

import '../layout/breakpoints.dart';
import '../tokens/app_tokens.dart';
import 'app_glass_surface.dart';

// 四个 Tab 页的**固定顶栏**与**常驻副行**。
//
// 规则（设计宪法第六节 + 交接清单）：顶栏**全程不随滚动改变任何一项**——
// 高度、字号、内边距、背景都不变。不做任何折叠动效（大标题折叠在列表页上
// 只是噪音）。栏体常驻玻璃：内容确实从它下方滚过，折射对象成立。
//
// 顶栏结构：左标题（19px/700；桌面档 22px）+ 右侧若干圆钮（32×32，浅雾底，
// **不是玻璃**——见位置表「停在纯色上的东西不用玻璃」）。
// 副行紧跟顶栏下方，同样常驻玻璃 + 底部发丝线 + 向下 10px 的极淡渐变投影。

/// 固定顶栏高度（不含系统安全区）。桌面档 60，其余 56。
const double kFixedTopBarHeight = 56;

/// 桌面档固定顶栏高度。
const double kFixedTopBarHeightExpanded = 60;

/// 副行高度（含上下内边距）。原型实测 51–52：9pt 上距 + 32pt 控件 + 10pt 下距。
const double kSubBarHeight = 52;

/// 无副行时，顶栏下、内容上的呼吸留白（原型的 `--bodypad = 顶栏高 + 10`）。
const double kTopBarContentGap = 10;

/// 滚动内容顶部应留出的净空（安全区 + 顶栏高 + 副行高/呼吸）。
///
/// 口径照抄原型 `--bodypad`：**无副行 = 顶栏高 + 10**，
/// **有副行 = 顶栏高 + 52**（副行 42 高 + 10 呼吸，即 52 一并计入）。
/// 有副行时**不再另加** [kTopBarContentGap]——那会让内容起点比原型多 10pt。
///
/// 内容出血到顶栏之下（堆叠布局）时，列表必须在开头留出它，
/// 否则首行内容会永久压在顶栏/副行底下。
double fixedTopBarClearance(
  BuildContext context, {
  required bool hasSubBar,
  required double barHeight,
}) =>
    MediaQuery.paddingOf(context).top +
    barHeight +
    (hasSubBar ? kSubBarHeight : kTopBarContentGap);

/// 滚动内容顶部净空（`CustomScrollView` 的 sliver 版，**只能放进 sliver 列表**）。
class SliverFixedTopBarInset extends StatelessWidget {
  const SliverFixedTopBarInset({
    super.key,
    required this.hasSubBar,
    this.barHeight = kFixedTopBarHeight,
  });

  final bool hasSubBar;
  final double barHeight;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: SizedBox(
      height: fixedTopBarClearance(
        context,
        hasSubBar: hasSubBar,
        barHeight: barHeight,
      ),
    ),
  );
}

/// 滚动内容顶部净空（**盒子版**：`ListView` / `Column` 用）。
///
/// 混用是硬错误：sliver 版的 `SliverToBoxAdapter` 放进 `ListView` 的 children
/// 会直接抛 `RenderRepaintBoundary expected a RenderBox ... received RenderSliver`，
/// 而这类错误只在真的渲染那个页面时才暴露（golden 用例是它的回归防线）。
class FixedTopBarInset extends StatelessWidget {
  const FixedTopBarInset({
    super.key,
    required this.hasSubBar,
    this.barHeight = kFixedTopBarHeight,
  });

  final bool hasSubBar;
  final double barHeight;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: fixedTopBarClearance(
      context,
      hasSubBar: hasSubBar,
      barHeight: barHeight,
    ),
  );
}

/// 固定液态玻璃顶栏（+ 可选常驻副行）。
///
/// 页面形如：
///
/// ```dart
/// Stack(
///   children: [
///     CustomScrollView(slivers: [SliverFixedTopBarInset(hasSubBar: true), ...]),
///     Positioned(top: 0, left: 0, right: 0, child: FixedTopBar(
///       title: '榜单',
///       actions: [...],
///       subBar: TextTabsBar(...),
///     )),
///   ],
/// )
/// ```
class FixedTopBar extends StatelessWidget {
  const FixedTopBar({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
    this.subBar,
    this.barHeight = kFixedTopBarHeight,
  });

  /// 页级标题；**全程固定**，不随滚动收缩。
  final String title;

  /// 右端动作（从左到右给出，通常是 [AppPlainRoundButton]）。
  final List<Widget> actions;

  /// 常驻副行（榜单的日/周/月、追剧的分段控件）；null 时无副行。
  final Widget? subBar;

  final double barHeight;

  bool get hasSubBar => subBar != null;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final expanded = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;

    return AppGlassSurface(
      // 全宽栏：直角。
      radius: 0,
      blur: 24,
      thickness: 14,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: SizedBox(
              height: barHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: _gutter(context)),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.barTitle.copyWith(
                            fontSize: expanded ? 22 : 19,
                            letterSpacing: expanded ? -0.6 : -0.4,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    for (final action in actions) ...<Widget>[
                      const SizedBox(width: 2),
                      action,
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (subBar != null) ...<Widget>[
            Container(height: .5, color: colors.divider),
            SizedBox(height: kSubBarHeight, child: subBar),
          ],
        ],
      ),
    );
  }

  double _gutter(BuildContext context) => Breakpoints.gutter(
    Breakpoints.classify(MediaQuery.sizeOf(context).width),
  );
}

/// 榜单副行：日榜 / 周榜 / 月榜。
///
/// **不是分段控件，是文字标签的选中态**（下划线 + 字重）：榜单页的主角是
/// 名次，维度切换不该比它更重。
class TextTabsBar extends StatelessWidget {
  const TextTabsBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          for (var index = 0; index < labels.length; index++) ...<Widget>[
            if (index > 0) const SizedBox(width: 20),
            _TextTab(
              label: labels[index],
              selected: index == selectedIndex,
              onTap: () => onSelected(index),
              colors: colors,
            ),
          ],
        ],
      ),
    );
  }
}

class _TextTab extends StatelessWidget {
  const _TextTab({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              label,
              style: AppText.body.copyWith(
                fontSize: 14,
                color: selected ? colors.textPrimary : colors.textTertiary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          // 选中下划线：贴近文字下缘（原型 ::after bottom:-4）。
          if (selected)
            Positioned(
              left: 0,
              right: 0,
              bottom: 2,
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  color: colors.textPrimary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// 一段分段控件（iOS 原生形态：浅雾底 + 白色滑块）。
///
/// **不用玻璃**——它在纯色底上，玻璃只会发灰（位置表）。
/// 选项可带计数（追剧页的「在看 / 已看完 / 全部」各多少部）。
class SegmentedBar extends StatelessWidget {
  const SegmentedBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.counts,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 与 [labels] 等长的计数；null 时不显示。
  final List<int>? counts;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final dark = colors.brightness == Brightness.dark;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.sunken,
        borderRadius: BorderRadius.circular(AppRadii.thumbnail),
      ),
      child: Row(
        children: <Widget>[
          for (var index = 0; index < labels.length; index++) ...<Widget>[
            if (index > 0) const SizedBox(width: 2),
            Expanded(
              child: _Segment(
                label: labels[index],
                count: counts == null ? null : counts![index],
                selected: index == selectedIndex,
                onTap: () => onSelected(index),
                colors: colors,
                dark: dark,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.colors,
    required this.dark,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final AppColors colors;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // 选中滑块：浅色下取画布白，深色下取一档亮面（原型 #3a3a3c）。
            color: selected
                ? (dark ? colors.surfaceElevated : colors.background)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            boxShadow: selected && !dark
                ? const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x1A000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                label,
                style: AppText.callout.copyWith(
                  color: selected ? colors.textPrimary : colors.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: AppText.mono.copyWith(
                    fontSize: 11,
                    color: colors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
