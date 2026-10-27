import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/player/playback_launch_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 播放启动页：在进入 `PlayerScreen` 之前拉详情、决定续播集数。
///
/// 真正的 `PlayerScreen` 依赖 media_kit 无法在测试环境构造，但这一屏
/// 不接触播放器，且是"点了播放却什么都不发生"这类用户投诉的常见位置
/// （详情失败、无分集、VIP 确认取消），值得覆盖。
class _DetailRepository extends FixtureRepository {
  _DetailRepository({this.episodes = 2, this.failure});

  final int episodes;
  final AppFailure? failure;
  int calls = 0;

  @override
  Future<DramaDetail> detail(Drama drama) async {
    calls++;
    if (failure != null) throw failure!;
    return DramaDetail(drama, [
      for (var index = 1; index <= episodes; index++)
        Episode({
          'id': '$index',
          'title': '第$index集',
          'currentEpisode': index,
        }, index),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_DetailRepository> pumpLaunch(
    WidgetTester tester, {
    int episodes = 2,
    AppFailure? failure,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final repository = _DetailRepository(episodes: episodes, failure: failure);

    // 成功路径会 pushReplacement 到 /player，必须挂在真实路由下；
    // 否则会以 "No GoRouter found" 走错误分支，掩盖真正的行为。
    final router = GoRouter(
      initialLocation: '/launch',
      routes: [
        GoRoute(
          path: '/launch',
          builder: (context, state) => PlaybackLaunchScreen(
            drama: FixtureRepository.free,
            repository: repository,
            store: store,
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) =>
              const Scaffold(body: Text('PLAYER_ROUTE')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
    return repository;
  }

  testWidgets('加载中展示进度提示', (tester) async {
    await pumpLaunch(tester);

    // 首帧处于加载态（详情尚未返回）。
    expect(find.text('正在进入播放'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('详情失败展示错误与重试入口', (tester) async {
    final repository = await pumpLaunch(tester, failure: AppFailure('合成详情失败'));
    // 让异步错误落地。
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('暂时无法播放'), findsOneWidget);
    expect(find.textContaining('合成详情失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 点重试会重新请求详情。
    final before = repository.calls;
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(repository.calls, greaterThan(before));
  });

  testWidgets('没有分集时给出明确提示而不是一直转圈', (tester) async {
    await pumpLaunch(tester, episodes: 0);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('暂时无法播放'), findsOneWidget);
    expect(find.textContaining('暂时没有可播放的集数'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('只有一集时正常进入播放路由（不越界）', (tester) async {
    await pumpLaunch(tester, episodes: 1);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('PLAYER_ROUTE'), findsOneWidget);
    expect(find.text('暂时无法播放'), findsNothing);
  });

  testWidgets('有分集时进入播放路由', (tester) async {
    await pumpLaunch(tester, episodes: 3);
    await tester.pumpAndSettle();

    expect(find.text('PLAYER_ROUTE'), findsOneWidget);
  });
}
