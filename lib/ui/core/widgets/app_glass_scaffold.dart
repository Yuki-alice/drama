import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../tokens/app_tokens.dart';

/// 设计系统对 `GlassScaffold` 的封装（页面骨架）。
///
/// 统一四件事，避免每个页面重复：
/// 1. 背景：**纯色底**（浅色纸白 / 深色炭灰，见 [AppColors.background]）；
/// 2. 状态栏：`GlassStatusBarStyle.auto` 跟随玻璃亮度级联；
/// 3. Material 透明度修正：`Material(type: MaterialType.transparency)`
///    消除 `MaterialApp` 下 `Text` 的兜底错误样式（红字 + 黄色双下划线）；
/// 4. 沉浸档：`immersive: true` 时背景为纯黑、不参与内容染色（播放器用）。
///
/// **四个 Tab 页不走这里**：它们各有一条常驻玻璃顶栏（`FixedTopBar`）+
/// 底部浮起 Tab 条 / 侧栏，由 `AppNavigationShell` 直接摆放。
/// 这里给**二级页**（设置 / 关于 / 免责 / 下载 / 错误页）用。
class AppGlassScaffold extends StatelessWidget {
  const AppGlassScaffold({
    super.key,
    required this.body,
    this.title,
    this.leading,
    this.actions,
    this.bottomBar,
    this.extendBody = false,
    this.appBarHeight = 44,
    this.immersive = false,
    this.contentAwareBrightness = true,
    this.appBarBottom,
  });

  final Widget body;

  /// 顶栏标题；为 null 时不显示标题（各页的大标题/固定顶栏在滚动内容之上）。
  final String? title;

  final Widget? leading;

  /// 顶栏右侧动作（通常是 [GlassIconAction]）。
  final List<Widget>? actions;

  /// 底部玻璃栏（通常 [AppBottomNavBar]）；为 null 时不显示。
  final Widget? bottomBar;

  /// 是否让 body 延伸到栏下方。
  ///
  /// 默认 `false`：由 `GlassScaffold` 精确摆放 body 于栏之间，**绝不遮挡内容**。
  /// 需要「内容滚到栏下」的滚动页显式设 `true`，并自行在列表顶部/尾部留出
  /// 净空（`GlassContentTopInset` / `SliverNavBarBottomInset`）。
  final bool extendBody;

  final double appBarHeight;

  /// 沉浸档：纯黑背景、不做内容染色（播放器 / 全屏画面）。
  final bool immersive;

  /// 让玻璃采样背后内容的明暗来自适应前景色。
  final bool contentAwareBrightness;

  /// 顶栏下方的附加内容（搜索框等），随 `PreferredSize` 一起参与高度计算。
  final PreferredSizeWidget? appBarBottom;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final hasBar =
        title != null ||
        leading != null ||
        actions != null ||
        appBarBottom != null;

    // 统一包一层 Material：`GlassScaffold` 自身**不创建 Material**，
    // 而 `MaterialApp` 会在根部装一个「错误文本样式」（红色等宽 + 黄色双下划线，
    // 见 material/app.dart 的 _errorTextStyle）作为兜底 `DefaultTextStyle`。
    // 因此任何不在 Material 下的 `Text` 都会继承它——实测外观是标题/导航标签
    // 下方出现黄色下划线。`Material` 会装上主题的 bodyMedium 覆盖该兜底样式。
    //
    // 用 `MaterialType.transparency`：只借它的文本样式与墨水层语义，不引入背景色。
    final background = ColoredBox(
      color: immersive ? colors.mediaBackground : colors.background,
    );

    final scaffold = GlassScaffold(
      backgroundColor: immersive ? colors.mediaBackground : colors.background,
      background: background,
      statusBarStyle: GlassStatusBarStyle.auto,
      extendBody: extendBody,
      appBarHeight: appBarHeight,
      contentAwareBrightness: contentAwareBrightness,
      appBar: hasBar
          ? GlassAppBar(
              toolbarHeight: appBarHeight,
              leading: leading,
              actions: actions,
              bottom: appBarBottom,
              title: title == null
                  ? null
                  : Text(
                      title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.headline.copyWith(
                        color: immersive ? colors.onMedia : colors.textPrimary,
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
