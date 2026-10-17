import 'package:drama_app/ui/core/theme/app_theme.dart';
import 'package:drama_app/ui/core/tokens/app_tokens.dart';
import 'package:drama_app/ui/core/widgets/app_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 「玻璃关」= **回落为浅雾平面，而不是消失**。
///
/// 原型里的对照开关是 `?glass=off`；应用内的等价物是系统的
/// 「降低透明度 / Increase Contrast」与「减弱动态效果」——两者任一开启时，
/// 玻璃退化为不透明的 `mist` 平面：**保留圆角、位置与发丝描边**，只去掉模糊
/// 与折射。玻璃凭空不见会让栏/条「消失」，那是缺陷不是降级。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool highContrast = false,
    bool reduceMotion = false,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(
            highContrast: highContrast,
            disableAnimations: reduceMotion,
          ),
          child: const Scaffold(
            body: Center(
              child: AppGlassSurface(
                width: 120,
                height: 60,
                child: SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('常规档走液态玻璃（GlassContainer）', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(GlassContainer), findsOneWidget);
  });

  testWidgets('高对比 → 退化浅雾平面：玻璃消失且仍有实体', (tester) async {
    await pump(tester, highContrast: true);
    expect(tester.takeException(), isNull);
    expect(find.byType(GlassContainer), findsNothing, reason: '高对比下仍在用玻璃');

    // 平面仍在（不是「消失」）：尺寸不变、底色是浅雾、带发丝描边。
    final surface = tester.getRect(find.byType(AppGlassSurface));
    expect(surface.width, 120);
    expect(surface.height, 60);

    final plane = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(AppGlassSurface),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = plane.decoration as BoxDecoration;
    expect(decoration.color, AppColors(Brightness.light).sunken);
    expect(decoration.border, isNotNull, reason: '回落平面丢掉了发丝描边');
  });

  testWidgets('减弱动态效果 → 同样退化浅雾平面', (tester) async {
    await pump(tester, reduceMotion: true);
    expect(tester.takeException(), isNull);
    expect(find.byType(GlassContainer), findsNothing);
    expect(tester.getRect(find.byType(AppGlassSurface)).width, 120);
  });

  testWidgets('深色档的回落平面取深色浅雾', (tester) async {
    await pump(tester, highContrast: true, brightness: Brightness.dark);
    final plane = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(AppGlassSurface),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(
      (plane.decoration as BoxDecoration).color,
      AppColors(Brightness.dark).sunken,
    );
  });

  // 回归锁：**定尺玻璃面必须铺满它的盒子**。
  //
  // 曾经的实际缺陷（真实截图 3 倍放大才看得出）：`Stack` 默认按 `topStart`
  // 摆放未定位子项，圆钮的 child 只是一个 `Icon`，玻璃片于是缩到图标大小并贴在
  // 左上角，而发丝描边按 34 画——渲染成「圆圈里一个错位的小片，图标偏到角落」。
  // 1 倍 golden 完全看不出来，所以这里直接量尺寸，不靠肉眼。
  group('定尺玻璃面：玻璃铺满盒子（回归锁）', () {
    testWidgets('圆钮：玻璃片与 34 圆盘等大，图标居中', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: Scaffold(
            body: Center(
              child: AppGlassRoundButton(
                icon: Icons.close_rounded,
                semanticLabel: '关闭',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final disc = tester.getRect(find.byType(GlassContainer));
      expect(disc.width, kGlassRoundVisual, reason: '玻璃片没有铺满 34 的圆盘');
      expect(disc.height, kGlassRoundVisual);

      final icon = tester.getRect(find.byIcon(Icons.close_rounded));
      expect(icon.center.dx, closeTo(disc.center.dx, 0.5), reason: '图标没横向居中');
      expect(icon.center.dy, closeTo(disc.center.dy, 0.5), reason: '图标没纵向居中');
    });

    testWidgets('锚点只挪视觉：topRight 时圆盘右缘落在命中区右缘', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: Scaffold(
            body: Center(
              child: AppGlassRoundButton(
                icon: Icons.close_rounded,
                semanticLabel: '关闭',
                anchor: VisualAnchor.topRight,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final hit = tester.getRect(find.byType(AppGlassRoundButton));
      final disc = tester.getRect(find.byType(GlassContainer));
      expect(hit.width, AppSpacing.minTapTarget, reason: '命中区被锚点改小了');
      expect(disc.right, closeTo(hit.right, 0.5));
      expect(disc.left, closeTo(hit.right - kGlassRoundVisual, 0.5));
    });
  });
}
