import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 固定液态玻璃顶栏的高度（**不含**系统安全区，也不含 [GlassTopBar.bottom]）。
const double kGlassTopBarHeight = 52;

/// 滚动内容顶部应留出的净空（安全区 + 顶栏 + 附加槽）。
///
/// 内容出血到顶栏之下（堆叠布局）时，列表必须在开头留出它，
/// 否则首行内容会永久压在顶栏底下。[bottomHeight] 传栏内附加槽的
/// 高度（如搜索框），与 `GlassTopBar.bottom` 的实测高度保持一致。
double glassTopBarClearance(BuildContext context, {double bottomHeight = 0}) =>
    MediaQuery.paddingOf(context).top + kGlassTopBarHeight + bottomHeight;

/// 滚动内容顶部的净空（`CustomScrollView` 的 sliver 版）。
class SliverGlassTopBarInset extends StatelessWidget {
  const SliverGlassTopBarInset({
    super.key,
    this.extra = AppSpacing.md,
    this.bottomHeight = 0,
  });

  /// 额外留白（视觉呼吸，与净空分开计）。
  final double extra;

  /// 顶栏内附加槽的高度（与 `GlassTopBar.bottom` 对应）。
  final double bottomHeight;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
        child: SizedBox(
          height:
              glassTopBarClearance(context, bottomHeight: bottomHeight) + extra,
        ),
      );
}

/// 固定在页面顶部的**液态玻璃条**。
///
/// 与底部 Tab 栏对称：整条是一块半透明毛玻璃（背景模糊 + 浅色罩 + 底部
/// 发丝线），内容从它下面滚过。**固定在页面的 Stack 顶层**，不随滚动移动；
/// 页面形如：
///
/// ```dart
/// Stack(
///   children: [
///     CustomScrollView(slivers: [SliverGlassTopBarInset(), ...]),
///     Positioned(top: 0, left: 0, right: 0, child: GlassTopBar(...)),
///   ],
/// )
/// ```
///
/// 版式：
/// - [leading]（可选，通常是返回圆钮）贴在左端；
/// - [title]（可选）跟在 leading 之后；两者都不给的页面标题由内容区承担；
/// - [actions] 按从左到右的顺序摆在右端（**最后一个贴着最右缘**）；
/// - [bottom]（可选）是栏内的附加槽（搜索框等），随栏一起被同一块
///   毛玻璃罩住——搜索页用它把「标题行 + 搜索框」收进同一次模糊。
///
/// 高对比 / 降低透明度时退化为**不透明底**（不再模糊）——与系统
/// 「降低透明度」的设置语义一致。
class GlassTopBar extends StatelessWidget {
  const GlassTopBar({
    super.key,
    this.title,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
  });

  /// 页级标题（跟在 [leading] 之后）；null 时不画标题。
  final String? title;

  /// 左端动作（返回圆钮等）。
  final Widget? leading;

  /// 右端动作（从左到右给出）。
  final List<Widget> actions;

  /// 栏内附加槽（搜索框等），高度计入 [glassTopBarClearance]。
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final opaques = colors.highContrast || MediaQuery.highContrastOf(context);

    final tint =
        opaques ? colors.background : colors.background.withValues(alpha: .72);

    final bar = Container(
      decoration: BoxDecoration(
        color: tint,
        border: Border(bottom: BorderSide(color: colors.divider)),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: kGlassTopBarHeight,
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  // leading 自带内衬（玻璃圆钮），贴边时用更小的外距，
                  // 否则图标会离左缘过远。
                  leading == null ? AppSpacing.gutter : AppSpacing.xs,
                  0,
                  AppSpacing.sm,
                  0,
                ),
                child: Row(
                  children: <Widget>[
                    ?leading,
                    if (leading != null && title != null)
                      const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: title == null
                          ? const SizedBox.shrink()
                          : Semantics(
                              header: true,
                              child: Text(
                                title!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.title.copyWith(
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                    ),
                    ...actions,
                  ],
                ),
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );
    if (opaques) return bar;

    // 毛玻璃：只裁在栏体上，内容照样从下层滚过。
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: bar,
      ),
    );
  }
}
