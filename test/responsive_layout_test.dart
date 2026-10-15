import 'package:drama_app/app/app.dart';
import 'package:drama_app/ui/core/layout/breakpoints.dart';
import 'package:drama_app/ui/core/theme/appearance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// W1 验收验证：
/// 1. 断点分级正确（手机单列 / 平板分栏 / 宽屏）；
/// 2. 大字矩阵（360×640 手机 / 1100×720 桌面）× 字号（1.0 / 1.3）下无断行错位与溢出。
void main() {
  group('断点分级', () {
    test('按可用宽度分级', () {
      expect(Breakpoints.classify(360), WindowSizeClass.compact);
      expect(Breakpoints.classify(599), WindowSizeClass.compact);
      expect(Breakpoints.classify(600), WindowSizeClass.medium);
      expect(Breakpoints.classify(1023), WindowSizeClass.medium);
      expect(Breakpoints.classify(1024), WindowSizeClass.expanded);
      expect(Breakpoints.classify(1100), WindowSizeClass.expanded);
    });
  });

  group('大字矩阵', () {
    for (final size in const <Size>[Size(360, 640), Size(1100, 720)]) {
      for (final scale in const <double>[1.0, 1.3]) {
        testWidgets(
          '首页在 ${size.width.toInt()}×${size.height.toInt()}／字号 $scale 无溢出异常',
          (tester) async {
            SharedPreferences.setMockInitialValues(<String, Object>{
              // 跳过首启免责声明，直接进首页。
              'legal.disclaimerAcknowledged': true,
              'appearance.textScale': scale,
            });
            final preferences = await SharedPreferences.getInstance();

            await tester.binding.setSurfaceSize(size);
            addTearDown(() => tester.binding.setSurfaceSize(null));

            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  sharedPreferencesProvider.overrideWithValue(preferences),
                ],
                child: const DramaApp(),
              ),
            );
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            expect(find.text('首页'), findsWidgets);
          },
        );
      }
    }
  });
}
