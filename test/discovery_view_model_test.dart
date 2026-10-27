import 'package:duanju_app/core/catalog_updates.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/home/discovery_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<DiscoveryViewModel> build(
    FixtureRepository repository, {
    DiscoveryViewModel Function(DiscoveryViewModel model)? configure,
    void Function(String action)? onPersist,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final model = DiscoveryViewModel(
      repository: repository,
      store: store,
      updates: CatalogUpdates(),
      persist: (action) async {
        onPersist?.call('persist');
        await action();
      },
    );
    addTearDown(model.dispose);
    return configure?.call(model) ?? model;
  }

  test('load fills items and paging state', () async {
    final model = await build(FixtureRepository());

    await model.load(useCache: true);

    expect(model.items, isNotEmpty);
    expect(model.loading, isFalse);
    expect(model.loadingMore, isFalse);
    expect(model.hasMore, isTrue);
    expect(model.error, isNull);
    expect(model.canLoadMore, isTrue);
  });

  test('loading more merges the next page', () async {
    final model = await build(FixtureRepository());
    await model.load(useCache: true);
    final before = model.items.length;

    await model.load(more: true);

    expect(model.items.length, greaterThan(before));
    expect(model.loadingMore, isFalse);
  });

  test('catalog failure surfaces as error and stops loading', () async {
    final model = await build(FixtureRepository()..fail = true);

    await model.load(useCache: true);

    expect(model.loading, isFalse);
    expect(model.items, isEmpty);
    expect(model.error, contains('合成网络错误'));
  });

  test('catalog updates merge into loaded items without context', () async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final updates = CatalogUpdates();
    final model = DiscoveryViewModel(
      repository: FixtureRepository(),
      store: store,
      updates: updates,
      persist: (action) => action(),
    );
    addTearDown(model.dispose);
    await model.load(useCache: true);
    final target = model.items.first;

    updates.publish(
      Drama(
        id: target.id,
        source: target.source,
        title: '更新后的标题',
        episodes: target.episodes,
      ),
    );

    expect(
      model.items.firstWhere((drama) => drama.id == target.id).title,
      '更新后的标题',
    );
  });

  test('applySource resets content, persists and reloads', () async {
    final persisted = <String>[];
    final repository = FixtureRepository();
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final model = DiscoveryViewModel(
      repository: repository,
      store: store,
      updates: CatalogUpdates(),
      persist: (action) async {
        persisted.add('persist');
        await action();
      },
    );
    addTearDown(model.dispose);
    await model.load(useCache: true);
    final alternative = store.sources.firstWhere(
      (site) => site.id != model.source.id,
    );

    model.applySource(alternative);
    await Future<void>.delayed(Duration.zero);

    expect(model.source.id, alternative.id);
    expect(persisted, isNotEmpty);
    expect(store.source, alternative.id);
  });

  test('clearContent empties feed when every source is disabled', () async {
    final model = await build(FixtureRepository());
    await model.load(useCache: true);
    expect(model.items, isNotEmpty);

    model.clearContent();

    expect(model.items, isEmpty);
    expect(model.banner, isEmpty);
    expect(model.hasMore, isFalse);
    expect(model.loading, isFalse);
  });
}
