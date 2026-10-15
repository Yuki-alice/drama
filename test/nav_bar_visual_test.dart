import 'package:drama_app/ui/core/theme/app_theme.dart';
import 'package:drama_app/ui/core/widgets/app_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 底栏在 compact 下的渲染 + 布局冒烟（无需 libmpv，可在 CI 跑）。
void main() {
  testWidgets('compact 底栏四个目的地都渲染且不带错误样式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: AppBottomNavBar(
            selectedIndex: 0,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 每个目的地的图标都在（选中项用 activeIcon，故按目的地逐个查）。
    for (final d in kMainDestinations) {
      final icons = find.byWidgetPredicate(
        (w) => w is Icon && (w.icon == d.icon || w.icon == d.activeIcon),
      );
      expect(icons, findsWidgets, reason: '目的地「${d.label}」的图标没渲染');
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('底栏在大字号下不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.3),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: AppBottomNavBar(
            selectedIndex: 2,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    // Flutter 的溢出会通过 exception 报出（RenderFlex overflowed）。
    expect(tester.takeException(), isNull, reason: '大字模式下底栏溢出');
    await tester.binding.setSurfaceSize(null);
  });
}
