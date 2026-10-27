import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/core/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 分领域 revision 的目的：单领域写入不应迫使其它领域的订阅者重建。
/// 这些断言直接对着 provider，不依赖 UI。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const drama = Drama(
    id: 'hongguo:rev',
    source: 'hongguo',
    title: '修订号测试剧',
    episodes: 2,
  );

  Future<(ProviderContainer, LocalStore)> build() async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    // 容器持有 store 的 override，销毁顺序由容器负责；
    // 这里不能再 addTearDown(store.dispose)，否则会二次释放。
    final container = ProviderContainer(
      overrides: [storeProvider.overrideWith((ref) => store)],
    );
    addTearDown(container.dispose);
    return (container, store);
  }

  test('进度写入只影响库领域，不波及设置与站源', () async {
    final (container, store) = await build();

    final libraryBefore = container.read(libraryRevisionProvider);
    final settingsBefore = container.read(settingsRevisionProvider);
    final accessBefore = container.read(accessRevisionProvider);

    await store.saveWatch(
      WatchEntry(
        drama: drama,
        episode: 1,
        position: 12,
        duration: 100,
        updatedAt: DateTime.now(),
      ),
    );

    expect(
      container.read(libraryRevisionProvider),
      greaterThan(libraryBefore),
      reason: '历史属于库领域',
    );
    expect(
      container.read(settingsRevisionProvider),
      settingsBefore,
      reason: '写进度不应触发设置订阅者',
    );
    expect(
      container.read(accessRevisionProvider),
      accessBefore,
      reason: '写进度不应触发站源订阅者',
    );
  });

  test('改设置只影响设置领域', () async {
    final (container, store) = await build();

    final libraryBefore = container.read(libraryRevisionProvider);
    final accessBefore = container.read(accessRevisionProvider);
    final settingsBefore = container.read(settingsRevisionProvider);

    await store.setPlaybackPreferences(const PlaybackPreferences(speed: 1.5));

    expect(
      container.read(settingsRevisionProvider),
      greaterThan(settingsBefore),
    );
    expect(container.read(libraryRevisionProvider), libraryBefore);
    expect(container.read(accessRevisionProvider), accessBefore);
  });

  test('切换站源开关只影响准入领域', () async {
    final (container, store) = await build();

    final libraryBefore = container.read(libraryRevisionProvider);
    final settingsBefore = container.read(settingsRevisionProvider);
    final accessBefore = container.read(accessRevisionProvider);

    await store.setSourceEnabled('yeguo', true);

    expect(container.read(accessRevisionProvider), greaterThan(accessBefore));
    expect(container.read(libraryRevisionProvider), libraryBefore);
    expect(container.read(settingsRevisionProvider), settingsBefore);
    expect(
      container.read(availableSourcesProvider).any((s) => s.id == 'yeguo'),
      isTrue,
    );
  });

  test('availableSources 随准入变化，且不被进度写入波及', () async {
    final (container, store) = await build();

    expect(
      container.read(availableSourcesProvider).any((s) => s.id == 'yeguo'),
      isFalse,
      reason: '受限源默认关闭',
    );

    // 写进度：站源列表不应变化。
    await store.saveWatch(
      WatchEntry(
        drama: drama,
        episode: 1,
        position: 5,
        duration: 100,
        updatedAt: DateTime.now(),
      ),
    );
    expect(
      container.read(availableSourcesProvider).any((s) => s.id == 'yeguo'),
      isFalse,
    );

    await store.setSourceEnabled('yeguo', true);
    expect(
      container.read(availableSourcesProvider).any((s) => s.id == 'yeguo'),
      isTrue,
    );
  });

  test('收藏列表随库领域更新', () async {
    final (container, store) = await build();

    expect(container.read(favoritesProvider), isEmpty);
    await store.toggleFavorite(drama);
    expect(
      container.read(favoritesProvider).map((item) => item.id),
      contains(drama.id),
    );
  });
}
