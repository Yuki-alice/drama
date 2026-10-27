import 'dart:convert';

import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/core/library_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements LibraryBackend {
  final values = <String, String>{};
  final commits = <Map<String, Object>>[];
  @override
  bool locked = false;
  bool allowed = true;
  int notifications = 0;
  int invalidations = 0;

  @override
  bool get canDownload => !locked;

  @override
  bool allowsSource(String source) => allowed && !locked;

  @override
  String? read(String key) => values[key];

  @override
  String? rawPreference(String key) => values[key];

  @override
  Future<void> setRawPreference(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> run(Future<void> Function() action) => action();

  @override
  Future<void> commit(
    Map<String, Object> changes, {
    Iterable<String> remove = const [],
    Set<String> clearSyncProgress = const {},
    bool syncUrgent = true,
  }) async {
    commits.add(changes);
    for (final entry in changes.entries) {
      values[entry.key] = '${entry.value}';
    }
  }

  @override
  WatchEntry? lanWatch(String id) => null;

  @override
  Set<String> get lanRecordIds => const {};

  @override
  void invalidateLanDocument() => invalidations++;

  @override
  void notify() => notifications++;
}

void main() {
  const drama = Drama(
    id: 'hongguo:library',
    source: 'hongguo',
    title: '库测试剧',
    episodes: 6,
  );
  final entry = WatchEntry(
    drama: drama,
    episode: 2,
    position: 30,
    duration: 90,
    updatedAt: DateTime(2026, 1, 1),
  );

  _Backend seeded() {
    return _Backend()
      ..values['history'] = jsonEncode([entry.toJson()])
      ..values['favorites'] = jsonEncode([drama.toJson()])
      ..values['followStates'] = jsonEncode({
        drama.id: FollowState.initial(drama, entry).toJson(),
      });
  }

  test('load restores history, favorites and follow state', () {
    final store = LibraryStore(seeded());

    expect(store.history.single.drama.id, drama.id);
    expect(store.isFavorite(drama.id), isTrue);
    expect(store.following(drama.id), isNotNull);
    expect(store.watched(drama.id)?.episode, 2);
  });

  test('saveWatch commits history and refreshes follow state', () async {
    final backend = seeded();
    final store = LibraryStore(backend);
    final next = WatchEntry(
      drama: drama,
      episode: 3,
      position: 12,
      duration: 90,
      updatedAt: DateTime(2026, 1, 2),
    );

    await store.saveWatch(next);

    expect(store.watched(drama.id)?.episode, 3);
    expect(backend.commits.last.containsKey('history'), isTrue);
    expect(backend.commits.last.containsKey('followStates'), isTrue);
    expect(backend.notifications, greaterThan(0));
  });

  test('locked backend restores nothing and clear wipes state', () {
    final backend = seeded()..locked = true;
    final store = LibraryStore(backend);
    expect(store.history, isEmpty);
    expect(store.favorites, isEmpty);
    expect(store.isFavorite(drama.id), isFalse);

    store.clear();
    expect(store.rawHistory, isEmpty);
    expect(store.rawFavorites, isEmpty);
    expect(store.rawFollowStates, isEmpty);
  });
}
