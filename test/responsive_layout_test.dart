import 'package:drama_app/app/app.dart';
import 'package:drama_app/ui/core/layout/breakpoints.dart';
import 'package:drama_app/ui/core/theme/appearance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// W1 验收验证：
/// 1. 断点分级正确（手机 / 平板 / 桌面）；
/// 2. **连续密度公式**的实测值（原型跑出来的数字，直接当断言）；
/// 3. 大字矩阵（360×640 手机 / 1100×720 桌面）× 字号（1.0 / 1.3）下无断行错位与溢出。
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

  group('密度公式（原型实测值）', () {
    test('手机 390：3 列，单格约 111pt', () {
      expect(Breakpoints.feedColumnsForSize(WindowSizeClass.compact, 390), 3);
      expect(
        Breakpoints.cellWidth(WindowSizeClass.compact, 390),
        closeTo(111.3, 0.5),
      );
    });

    test('平板 834：4 列，单格约 132pt', () {
      const size = WindowSizeClass.medium;
      expect(Breakpoints.railWidth(size), 200);
      expect(Breakpoints.railPlaceholder(size), 224);
      expect(Breakpoints.gutter(size), 24);
      expect(Breakpoints.feedColumnsForSize(size, 834), 4);
      expect(Breakpoints.cellWidth(size, 834), closeTo(131.5, 0.5));
    });

    test('桌面 1280：6 列，单格约 148pt', () {
      const size = WindowSizeClass.expanded;
      expect(Breakpoints.railWidth(size), 240);
      expect(Breakpoints.railPlaceholder(size), 264);
      expect(Breakpoints.gutter(size), 34);
      expect(Breakpoints.feedColumnsForSize(size, 1280), 6);
      expect(Breakpoints.cellWidth(size, 1280), closeTo(148.0, 0.5));
    });

    test('列数下限 3 / 上限 8（网格上限 1120 封顶）', () {
      expect(Breakpoints.feedColumns(0), 3);
      expect(Breakpoints.feedColumns(358), 3);
      // 越宽越多，但 1120 之外不再增列（否则桌面会算出 8 列却放不下）。
      expect(Breakpoints.feedColumns(1120), 8);
      expect(Breakpoints.feedColumns(4000), 8);
      expect(
        Breakpoints.gridAvailableWidth(WindowSizeClass.expanded, 4000),
        Breakpoints.kGridMaxWidth,
      );
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

            // 视口 = 逻辑像素；`setSurfaceSize` 只改渲染面、不改 MediaQuery
            // （页面按 MediaQuery 判档位），所以直接设 `tester.view`。
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);

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
            expect(find.text('发现'), findsWidgets);
          },
        );
      }
    }
  });
}
