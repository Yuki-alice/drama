import 'package:drama_app/app/app.dart';
import 'package:drama_app/ui/core/theme/app_theme.dart';
import 'package:drama_app/ui/core/theme/appearance_controller.dart';
import 'package:drama_app/ui/features/detail/views/detail_view.dart';
import 'package:drama_app/ui/features/profile/view_models/profile_view_model.dart';
import 'package:drama_app/ui/features/search/view_models/search_view_model.dart';
import 'package:drama_app/ui/features/search/views/search_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 版式 **golden 锁**（设计宪法第九节：版式改动一律配 golden test）。
///
/// 动机很具体：git 历史上已经做过三轮「视觉重做」，而每一轮都没把
/// 「现在这样是对的」固化成断言，于是下一轮又推翻它。这里把四个 Tab 页在
/// 参考尺寸下的版式钉住——首页覆盖**窄 / 中 / 宽三档**（三档导航：
/// 浮起玻璃 Tab 条 → 浮起玻璃侧栏 200 → 240），其余三页覆盖手机档 +
/// 深浅两色。
///
/// 运行口径：
/// - `flutter test` 比对基线；`flutter test --update-goldens` 重写基线。
/// - 基线在**固定 Flutter 版本**（与 CI 同为 3.41.5）下生成：测试字体是
///   `flutter_test` 的确定性测试字体，封面走确定性渐变（mock 数据无真实
///   封面），因此同一 Flutter 版本内可跨机比对。换 SDK 版本后请重新生成。
void main() {
  /// 起一个真实应用（含导航外壳），视口 = 逻辑像素。
  Future<void> pumpApp(
    WidgetTester tester, {
    required Size size,
    required bool dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{
      // 跳过首启免责声明，直接进首页。
      'legal.disclaimerAcknowledged': true,
      if (dark) 'appearance.themeMode': 'dark',
    });
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          // 问候语随本机时刻变——必须钉死，否则基线随「早上好/下午好」漂移，
          // 同一份代码在不同时刻跑出不同像素（第一次比对就踩到了这条）。
          greetingProvider.overrideWithValue('晚上好'),
        ],
        child: const DramaApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shoot(WidgetTester tester, String name, {Finder? of}) async {
    await expectLater(
      of ?? find.byType(DramaApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  group('发现页（窄 / 中 / 宽三档）', () {
    testWidgets('手机 390×844 · 浅色（浮起玻璃 Tab 条 · 3 列）', (tester) async {
      await pumpApp(tester, size: const Size(390, 844), dark: false);
      await shoot(tester, 'home_phone_light');
    });

    testWidgets('手机 390×844 · 深色', (tester) async {
      await pumpApp(tester, size: const Size(390, 844), dark: true);
      await shoot(tester, 'home_phone_dark');
    });

    testWidgets('平板 834×1112 · 浅色（浮起玻璃侧栏 200 · 4 列）', (tester) async {
      await pumpApp(tester, size: const Size(834, 1112), dark: false);
      await shoot(tester, 'home_tablet_light');
    });

    testWidgets('桌面 1280×800 · 浅色（浮起玻璃侧栏 240 · 6 列）', (tester) async {
      await pumpApp(tester, size: const Size(1280, 800), dark: false);
      await shoot(tester, 'home_desktop_light');
    });
  });

  group('其余三个 Tab 页（手机档 · 深浅两色）', () {
    Future<void> pumpAndSwitch(
      WidgetTester tester,
      IconData navIcon,
      bool dark,
    ) async {
      await pumpApp(tester, size: const Size(390, 844), dark: dark);
      await tester.tap(find.byIcon(navIcon));
      await tester.pumpAndSettle();
    }

    testWidgets('榜单 · 浅色', (tester) async {
      await pumpAndSwitch(tester, Icons.leaderboard_outlined, false);
      await shoot(tester, 'ranking_phone_light');
    });

    testWidgets('榜单 · 深色', (tester) async {
      await pumpAndSwitch(tester, Icons.leaderboard_outlined, true);
      await shoot(tester, 'ranking_phone_dark');
    });

    testWidgets('追剧（空态） · 浅色', (tester) async {
      await pumpAndSwitch(tester, Icons.favorite_border, false);
      await shoot(tester, 'library_phone_light');
    });

    testWidgets('追剧（空态） · 深色', (tester) async {
      await pumpAndSwitch(tester, Icons.favorite_border, true);
      await shoot(tester, 'library_phone_dark');
    });

    testWidgets('我的 · 浅色', (tester) async {
      await pumpAndSwitch(tester, Icons.person_outline, false);
      await shoot(tester, 'profile_phone_light');
    });

    testWidgets('我的 · 深色', (tester) async {
      await pumpAndSwitch(tester, Icons.person_outline, true);
      await shoot(tester, 'profile_phone_dark');
    });
  });

  group('搜索页 / 详情页（push 出来的子页，无导航）', () {
    /// 子页直接泵（它们本来就 push 在导航外壳之外）。
    Future<void> pumpPage(WidgetTester tester, Widget page, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            // 与真实应用一致：不带 debug 角标（否则会把「DEBUG」横幅烤进基线）。
            debugShowCheckedModeBanner: false,
            theme: buildMaterialTheme(Brightness.light),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('搜索 · 引导态 · 手机 390×844', (tester) async {
      await pumpPage(tester, const SearchView(), const Size(390, 844));
      await shoot(tester, 'search_guide_phone', of: find.byType(MaterialApp));
    });

    testWidgets('搜索 · 结果态 · 手机 390×844', (tester) async {
      await pumpPage(tester, const SearchView(), const Size(390, 844));
      ProviderScope.containerOf(
        tester.element(find.byType(SearchView)),
      ).read(searchProvider.notifier).submit('千金');
      await tester.pumpAndSettle();
      await shoot(tester, 'search_results_phone', of: find.byType(MaterialApp));
    });

    testWidgets('详情 · 窄屏 390×844', (tester) async {
      await pumpPage(
        tester,
        const DetailView(id: 'd001'),
        const Size(390, 844),
      );
      await shoot(tester, 'detail_phone', of: find.byType(MaterialApp));
    });

    testWidgets('详情 · 宽屏 1100×800（双栏）', (tester) async {
      await pumpPage(
        tester,
        const DetailView(id: 'd001'),
        const Size(1100, 800),
      );
      await shoot(tester, 'detail_wide', of: find.byType(MaterialApp));
    });
  });
}
