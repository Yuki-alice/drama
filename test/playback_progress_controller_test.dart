import 'package:duanju_app/core/local_snapshot.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/player/playback_progress_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const drama = Drama(
    id: 'hongguo:progress',
    source: 'hongguo',
    title: '进度测试剧',
    episodes: 2,
  );
  final detail = DramaDetail(drama, [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
    Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
  ]);

  Future<(PlaybackProgressController, LocalStore, int Function())> build({
    String? mediaId,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    var flushes = 0;
    final controller = PlaybackProgressController(
      store: store,
      repository: FixtureRepository(),
      detail: detail,
      mediaId: mediaId,
      flushLan: () => flushes++,
    );
    addTearDown(controller.dispose);
    return (controller, store, () => flushes);
  }

  test('saving writes a watch entry for the opened episode', () async {
    final (controller, store, _) = await build();

    controller.markOpened(1);
    await controller.save(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
    );

    expect(store.history, hasLength(1));
    expect(store.history.first.drama.id, drama.id);
    expect(store.history.first.episode, 2);
    expect(store.history.first.position, 42);
  });

  test('duplicate saves are skipped but flush still reaches LAN', () async {
    final (controller, _, flushes) = await build();

    controller.markOpened(0);
    await controller.save(
      position: const Duration(seconds: 10),
      duration: const Duration(minutes: 1),
    );
    await controller.save(
      position: const Duration(seconds: 10),
      duration: const Duration(minutes: 1),
      flush: true,
    );

    expect(flushes(), 1);
  });

  test('media progress is stored separately from drama history', () async {
    final (controller, store, _) = await build(mediaId: 'media-1');

    controller.markOpened(0);
    await controller.save(
      position: const Duration(seconds: 20),
      duration: const Duration(minutes: 2),
    );

    expect(store.mediaWatched('media-1')?.position, 20);
    expect(store.history, isEmpty);
  });

  test('saving before an episode is opened is a no-op', () async {
    final (controller, store, _) = await build();

    await controller.save(
      position: const Duration(seconds: 20),
      duration: const Duration(minutes: 2),
    );

    expect(store.history, isEmpty);
    expect(controller.openedIndex, -1);
  });

  group('throttling', _throttleTests);
}

/// 进度写入的频率与正确性：
/// saveWatch 曾经在每次提交后全量 load()，播放时每 5 秒把 history /
/// favorites / followStates 重新 JSON 解码一遍。这里用可计数的
/// SharedPreferences 替身验证「节流后仍能落盘、flush 不被节流」。
class _CountingPreferences extends InMemorySharedPreferencesStore {
  _CountingPreferences(super.data) : super.withData();
  int snapshotWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith(LocalSnapshot.storageKey)) snapshotWrites++;
    return super.setValue(valueType, key, value);
  }
}

void _throttleTests() {
  const drama = Drama(
    id: 'hongguo:throttle',
    source: 'hongguo',
    title: '节流测试剧',
    episodes: 2,
  );
  final detail = DramaDetail(drama, [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
    Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
  ]);

  Future<(PlaybackProgressController, LocalStore, _CountingPreferences)>
  build() async {
    SharedPreferences.resetStatic();
    final platform = _CountingPreferences({});
    SharedPreferencesStorePlatform.instance = platform;
    installAllTestSources();
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final controller = PlaybackProgressController(
      store: store,
      repository: FixtureRepository(),
      detail: detail,
    );
    addTearDown(controller.dispose);
    return (controller, store, platform);
  }

  test('连续心跳被节流，flush 立即落盘', () async {
    final (controller, store, platform) = await build();
    controller.markOpened(0);

    // 第一次写入不受节流。
    await controller.save(
      position: const Duration(seconds: 10),
      duration: const Duration(minutes: 5),
    );
    final afterFirst = platform.snapshotWrites;
    expect(afterFirst, greaterThan(0));
    expect(store.history.single.position, 10);

    // 紧接着前进 1 秒：应被节流，不再写盘，内存也不更新。
    await controller.save(
      position: const Duration(seconds: 11),
      duration: const Duration(minutes: 5),
    );
    expect(platform.snapshotWrites, afterFirst);
    expect(store.history.single.position, 10);

    // flush 不受节流限制（暂停/退出时必须落盘）。
    await controller.save(
      position: const Duration(seconds: 12),
      duration: const Duration(minutes: 5),
      flush: true,
    );
    expect(platform.snapshotWrites, greaterThan(afterFirst));
    expect(store.history.single.position, 12);
  });

  test('前进量足够时即使间隔很短也会落盘', () async {
    SharedPreferences.resetStatic();
    final platform = _CountingPreferences({});
    SharedPreferencesStorePlatform.instance = platform;
    installAllTestSources();
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    // 门槛设成 0，验证"位置显著前进优先于时间节流"。
    final controller = PlaybackProgressController(
      store: store,
      repository: FixtureRepository(),
      detail: detail,
      minInterval: const Duration(minutes: 5),
      minAdvanceMs: 0,
    );
    addTearDown(controller.dispose);
    controller.markOpened(0);

    await controller.save(
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 5),
    );
    final first = platform.snapshotWrites;
    await controller.save(
      position: const Duration(seconds: 40),
      duration: const Duration(minutes: 5),
    );
    expect(platform.snapshotWrites, greaterThan(first));
  });

  test('切集后重新计算节流基准', () async {
    final (controller, store, platform) = await build();
    controller.markOpened(0);
    await controller.save(
      position: const Duration(seconds: 120),
      duration: const Duration(minutes: 5),
    );
    final afterFirst = platform.snapshotWrites;

    controller.markOpened(1);
    await controller.save(
      position: const Duration(seconds: 3),
      duration: const Duration(minutes: 5),
    );
    expect(platform.snapshotWrites, greaterThan(afterFirst));
    expect(store.history.single.episode, 2);
  });
}
