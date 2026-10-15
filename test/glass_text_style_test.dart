import 'package:drama_app/ui/core/theme/app_theme.dart';
import 'package:drama_app/ui/core/widgets/app_glass_scaffold.dart';
import 'package:drama_app/ui/core/widgets/app_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归：玻璃外壳下的文字**不得**继承 `MaterialApp` 的兜底「错误文本样式」。
///
/// 背景：`MaterialApp` 在根部把 `_errorTextStyle`（红色等宽 + 黄色双下划线，
/// 见 material/app.dart）装成兜底 `DefaultTextStyle`，本意是提示「没有 Material
/// 祖先」。而 `GlassScaffold` 自身**不创建 Material**（只在 body 上由我们包了一层），
/// 于是它直接摆放的 appBar 标题与 bottomBar 导航标签会继承该样式——实机表现
/// 就是导航标签下方出现黄色双下划线（用户截图复现）。
///
/// 修法：在 `AppGlassScaffold` 外层再包一层 `MaterialType.transparency`。
void main() {
  /// 取 `Text` **实际绘制**用的段落样式（不是 DefaultTextStyle 的继承值——
  /// 后者会被 GlassScaffold 内部的 scope 掩盖，测不出问题）。
  List<TextStyle?> paintedStyles(WidgetTester tester, Finder scope) {
    final texts = find.descendant(of: scope, matching: find.byType(Text));
    return <TextStyle?>[
      for (final element in texts.evaluate())
        (element.renderObject! as RenderParagraph).text.style,
    ];
  }

  bool isErrorStyle(TextStyle? s) =>
      s?.decoration == TextDecoration.underline &&
      s?.decorationStyle == TextDecorationStyle.double;

  testWidgets('底部导航标签不带错误下划线（compact）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: AppGlassScaffold(
          title: '标题X',
          bottomBar: AppBottomNavBar(selectedIndex: 0, onSelected: (_) {}),
          body: const SizedBox(),
        ),
      ),
    );
    await tester.pump();

    final styles = paintedStyles(tester, find.byType(AppBottomNavBar));
    expect(styles, isNotEmpty, reason: '没找到导航标签，测试本身失效');
    for (final style in styles) {
      expect(
        isErrorStyle(style),
        isFalse,
        reason: '导航标签继承了 MaterialApp 的兜底错误样式（黄色双下划线）',
      );
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('appBar 标题不带错误下划线', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.dark),
        home: const AppGlassScaffold(
          title: '榜单',
          body: SizedBox(),
        ),
      ),
    );
    await tester.pump();
    for (final style in paintedStyles(tester, find.byType(Scaffold))) {
      expect(isErrorStyle(style), isFalse);
    }
  });
}
