import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../tokens/app_tokens.dart';
import 'app_backdrop.dart';

/// 设计系统对 `GlassScaffold` 的封装（导航骨架）。
///
/// 统一三件事，避免每个页面重复：
/// 1. 背景：不透明内容层 + 可折射的 [AppBackdrop]；
/// 2. 状态栏：`GlassStatusBarStyle.auto` 跟随玻璃亮度级联；
/// 3. Material 透明度修正：`Material(type: MaterialType.transparency)`
/// 消除 MaterialApp 下 `Text` 的调试黄色下划线（「MaterialApp 三件套」）。
class AppGlassScaffold extends StatelessWidget {
  const AppGlassScaffold({
    super.key,
    required this.body,
    this.title,
    this.leading,
    this.actions,
    this.bottomBar,
    this.extendBody = false,
  });

  final Widget body;

  /// AppBar 标题；为 null 时不显示标题。
  final String? title;

  final Widget? leading;

  /// AppBar 右侧动作（通常是 [GlassIconAction]）。
  final List<Widget>? actions;

  /// 底部玻璃栏（通常 [AppBottomNavBar]）；为 null 时不显示。
  final Widget? bottomBar;

  /// 是否让 body 延伸到栏下方。
  ///
  /// 默认 `false`：由 `GlassScaffold` 精确摆放 body 于栏之间，**绝不遮挡内容**。
  /// 需要"内容滚到栏下"的滚动页显式设 `true`，并自行在列表顶部留出
  /// `GlassContentTopInset`（因为 `GlassScaffold` 不会替你插占位）。
  final bool extendBody;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final hasBar = title != null || leading != null || actions != null;

    // 统一包一层 Material：`GlassScaffold` 自身**不创建 Material**，
    // 而 `MaterialApp` 会在根部装一个「错误文本样式」（红色等宽 + 黄色双下划线，
    // 见 material/app.dart 的 _errorTextStyle）作为兜底 `DefaultTextStyle`。
    // 因此任何不在 Material 下的 `Text` 都会继承它——实测外观是标题/导航标签
    // 下方出现黄色下划线。`Material` 会装上主题的 bodyMedium 覆盖该兜底样式。
    //
    // 用 `MaterialType.transparency`：只借它的文本样式与墨水层语义，不引入背景色
    // （背景由 GlassScaffold 的 `background`/`backgroundColor` 负责）。
    final scaffold = GlassScaffold(
      backgroundColor: colors.background,
      background: const AppBackdrop(),
      statusBarStyle: GlassStatusBarStyle.auto,
      extendBody: extendBody,
      appBar: hasBar
          ? GlassAppBar(
              leading: leading,
              actions: actions,
              title: title == null
                  ? null
                  : Text(
                      title!,
                      style: AppText.headline.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
            )
          : null,
      bottomBar: bottomBar,
      body: Material(type: MaterialType.transparency, child: body),
    );

    // body 已在上面包了 Material；这里再包一层覆盖 appBar / bottomBar
    // （它们由 GlassScaffold 直接摆放，不在 body 的 Material 之下）。
    return Material(type: MaterialType.transparency, child: scaffold);
  }
}

/// 滚动页在 `extendBody: true` 时所需的顶部留白（安全区 + AppBar 高度）。
class GlassContentTopInset extends StatelessWidget {
  const GlassContentTopInset({
    super.key,
    this.appBarHeight = 44,
    this.extra = 0,
  });

  final double appBarHeight;
  final double extra;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.paddingOf(context).top + appBarHeight + extra,
  );
}
