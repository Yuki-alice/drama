import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/player/playback_progress_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
