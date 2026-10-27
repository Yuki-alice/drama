import 'dart:convert';

import 'package:duanju_app/core/catalog_sort.dart';
import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/core/hongguo_series.dart';
import 'package:duanju_app/core/models.dart';

/// [LibraryStore] 所需的持久化能力，由 LocalStore 实现。
abstract interface class LibraryBackend {
  bool get locked;
  bool get canDownload;
  bool allowsSource(String source);
  String? read(String key);
  String? rawPreference(String key);
  Future<void> setRawPreference(String key, String value);
  Future<void> run(Future<void> Function() action);
  Future<void> commit(
    Map<String, Object> changes, {
    Iterable<String> remove,
    Set<String> clearSyncProgress,
    bool syncUrgent,
  });
  WatchEntry? lanWatch(String id);
  Set<String> get lanRecordIds;
  void invalidateLanDocument();
  void notify();
}

/// 本地观看历史、收藏、追剧状态与系列候选。
class LibraryStore {
  LibraryStore(this.backend) {
    load();
    loadSeriesCandidates();
  }

  final LibraryBackend backend;

  static const seriesKey = 'seriesCandidates';
  static const followChecksKey = 'followChecks';

  final _history = <String, WatchEntry>{};
  final _favorites = <String, Drama>{};
  final _followStates = <String, FollowState>{};
  final _seriesCandidates = <String, Drama>{};

  void load() {
    backend.invalidateLanDocument();
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    if (backend.locked) return;
    for (final row in readJsonList(backend.read('history'))) {
      try {
        final entry = WatchEntry.fromJson(row);
        _history[entry.drama.id] = entry;
      } catch (_) {}
    }
    for (final row in readJsonList(backend.read('favorites'))) {
      try {
        final drama = Drama.fromJson(row);
        _favorites[drama.id] = drama;
      } catch (_) {}
    }
    Map<String, dynamic> states = {};
    try {
      states = Map<String, dynamic>.from(
        jsonDecode(backend.read('followStates') ?? '{}') as Map,
      );
    } catch (_) {}
    for (final drama in _favorites.values) {
      try {
        _followStates[drama.id] = FollowState.fromJson(
          Map<String, dynamic>.from(states[drama.id] as Map),
        );
      } catch (_) {
        _followStates[drama.id] = FollowState.initial(
          drama,
          _history[drama.id],
        );
      }
    }
  }

  void loadSeriesCandidates() {
    _seriesCandidates.clear();
    if (backend.locked) return;
    for (final row in readJsonList(backend.rawPreference(seriesKey))) {
      try {
        final drama = Drama.fromJson(row);
        if (drama.source == SourceSite.hongguo.id) {
          _seriesCandidates[drama.id] = drama;
        }
      } catch (_) {}
    }
  }

  void clear() {
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    _seriesCandidates.clear();
  }

  Map<String, WatchEntry> get rawHistory => Map.unmodifiable(_history);
  Map<String, Drama> get rawFavorites => Map.unmodifiable(_favorites);
  Map<String, FollowState> get rawFollowStates =>
      Map.unmodifiable(_followStates);
  String encodeFollowStates(Map<String, FollowState> states) =>
      _encodeFollowStates(states);

  List<WatchEntry> get history =>
      _history.values
          .where((entry) => backend.allowsSource(entry.drama.source))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<Drama> get favorites => _favorites.values
      .where((drama) => backend.allowsSource(drama.source))
      .toList()
      .reversed
      .toList();

  WatchEntry? watched(String id) {
    WatchEntry? entry = _history[id];
    if (entry == null && isFavorite(id)) {
      entry = backend.lanWatch(id);
    }
    return entry != null && backend.allowsSource(entry.drama.source)
        ? entry
        : null;
  }

  bool isFavorite(String id) =>
      _favorites[id] != null && backend.allowsSource(_favorites[id]!.source);

  FollowState? following(String id) =>
      isFavorite(id) ? _followStates[id] : null;

  List<Drama> seriesDramasFor(Drama anchor) {
    if (!backend.allowsSource(SourceSite.hongguo.id) ||
        anchor.source != SourceSite.hongguo.id) {
      return const [];
    }
    final items = <String, Drama>{};
    for (final drama in _seriesCandidates.values) {
      if (backend.allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final drama in _favorites.values) {
      if (backend.allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final entry in _history.values) {
      if (backend.allowsSource(entry.drama.source)) {
        items[entry.drama.id] = entry.drama;
      }
    }
    final notices = <SeriesSeasonNotice>[
      ...?_followStates[anchor.id]?.seriesSeasons.values,
      for (final state in _followStates.values)
        if (state.seriesSeasons.containsKey(anchor.id))
          state.seriesSeasons[anchor.id]!,
    ];
    for (final notice in notices) {
      items.putIfAbsent(
        notice.id,
        () => Drama(
          id: notice.id,
          source: SourceSite.hongguo.id,
          sourceId: notice.id.substring(SourceSite.hongguo.id.length + 1),
          title: notice.title,
        ),
      );
    }
    final current = items.remove(anchor.id) ?? anchor;
    final rest = items.values.toList()
      ..sort((a, b) => naturalTitleCompare(a.title, b.title));
    return [current, ...rest];
  }

  Map<String, FollowCheck> get followChecks {
    try {
      final data =
          jsonDecode(backend.rawPreference(followChecksKey) ?? '{}') as Map;
      return {
        for (final entry in data.entries)
          entry.key as String: FollowCheck.fromJson(entry.value),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveFollowChecks(Map<String, FollowCheck> checks) =>
      backend.run(() async {
        if (backend.locked) return;
        await backend.setRawPreference(
          followChecksKey,
          jsonEncode({
            for (final entry in checks.entries)
              if (_favorites.containsKey(entry.key))
                entry.key: entry.value.toJson(),
          }),
        );
      });

  Future<void> toggleFavorite(Drama drama) {
    return backend.run(() async {
      if (!backend.allowsSource(drama.source)) return;
      final entries = Map.of(_favorites);
      final states = Map.of(_followStates);
      if (entries.containsKey(drama.id)) {
        entries.remove(drama.id);
        states.remove(drama.id);
      } else {
        if (entries.length >= 20000) throw StateError('追剧数量已达上限，请先整理追剧');
        entries[drama.id] = drama;
        states[drama.id] = FollowState.initial(drama, _history[drama.id]);
      }
      await backend.commit({
        'favorites': jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        'followStates': _encodeFollowStates(states),
      });
      load();
      backend.notify();
    });
  }

  String _encodeFollowStates(Map<String, FollowState> states) => jsonEncode({
    for (final entry in states.entries) entry.key: entry.value.toJson(),
  });

  Future<void> setFollowStatus(Drama drama, FollowStatus status) {
    return backend.run(() async {
      if (!backend.allowsSource(drama.source)) return;
      if (!_favorites.containsKey(drama.id) && _favorites.length >= 20000) {
        throw StateError('追剧数量已达上限，请先整理追剧');
      }
      final current = _favorites[drama.id]?.merge(drama) ?? drama;
      final entries = Map.of(_favorites)..[drama.id] = current;
      final state =
          (_followStates[drama.id] ??
                  FollowState.initial(current, _history[drama.id]))
              .observe(current)
              .withStatus(status);
      final states = Map.of(_followStates)..[drama.id] = state;
      await backend.commit({
        'favorites': jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        'followStates': _encodeFollowStates(states),
      });
      load();
      backend.notify();
    });
  }

  Future<void> markUpdatesRead(String id) {
    return backend.run(() async {
      if (!isFavorite(id)) return;
      final states = Map.of(_followStates)
        ..[id] = _followStates[id]!.markRead();
      await backend.commit({'followStates': _encodeFollowStates(states)});
      load();
      backend.notify();
    });
  }

  Future<void> markSeriesSeasonRead(String id, String seasonId) {
    return backend.run(() async {
      if (!isFavorite(id)) return;
      final current = _followStates[id]!;
      final updated = current.markSeriesSeasonRead(seasonId);
      if (identical(current, updated)) return;
      final states = Map.of(_followStates)..[id] = updated;
      await backend.commit({'followStates': _encodeFollowStates(states)});
      load();
      backend.notify();
    });
  }

  Future<void> saveWatch(WatchEntry entry) {
    return backend.run(() async {
      if (!backend.allowsSource(entry.drama.source)) return;
      final previous = _history[entry.drama.id]?.drama;
      final current = previous == null
          ? entry
          : WatchEntry(
              drama: previous.merge(entry.drama),
              episode: entry.episode,
              position: entry.position,
              duration: entry.duration,
              updatedAt: entry.updatedAt,
            );
      final entries = Map.of(_history)..[entry.drama.id] = current;
      final sorted = entries.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final following = _followStates[entry.drama.id];
      final states = Map.of(_followStates);
      final favorites = Map.of(_favorites);
      if (following != null) {
        states[entry.drama.id] = following.afterPlayback(current);
        favorites[entry.drama.id] = favorites[entry.drama.id]!.merge(
          current.drama,
        );
      }
      await backend.commit({
        'history': jsonEncode(
          sorted.take(300).map((entry) => entry.toJson()).toList(),
        ),
        if (following != null) ...{
          'followStates': _encodeFollowStates(states),
          'favorites': jsonEncode(
            favorites.values.map((entry) => entry.toJson()).toList(),
          ),
        },
      }, syncUrgent: false);
      load();
      backend.notify();
    });
  }

  WatchEntry? mediaWatched(String id) {
    if (!backend.canDownload) return null;
    try {
      final data = jsonDecode(backend.read('mediaHistory') ?? '{}') as Map;
      final entry = data[id] == null
          ? null
          : WatchEntry.fromJson(Map<String, dynamic>.from(data[id] as Map));
      return entry != null && backend.allowsSource(entry.drama.source)
          ? entry
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMediaWatch(String id, WatchEntry entry) {
    return backend.run(() async {
      if (!backend.canDownload || !backend.allowsSource(entry.drama.source)) {
        return;
      }
      final data = jsonDecode(backend.read('mediaHistory') ?? '{}') as Map;
      data.remove(id);
      data[id] = entry.toJson();
      while (data.length > 300) {
        data.remove(data.keys.first);
      }
      await backend.commit({'mediaHistory': jsonEncode(data)});
    });
  }

  Future<void> clearHistory() {
    return backend.run(() async {
      if (backend.locked) return;
      await backend.commit(
        {},
        remove: ['history'],
        clearSyncProgress: {..._history.keys, ...backend.lanRecordIds},
      );
      load();
      backend.notify();
    });
  }

  Future<void> removeHistory(String id) {
    return backend.run(() async {
      if (watched(id) == null) return;
      final entries = Map.of(_history)..remove(id);
      await backend.commit(
        {
          'history': jsonEncode(
            entries.values.map((entry) => entry.toJson()).toList(),
          ),
        },
        clearSyncProgress: {id},
      );
      load();
      backend.notify();
    });
  }

  Future<void> refreshDrama(Drama drama) =>
      _refreshDramas([drama], cacheSeriesCandidates: false);

  Future<void> refreshDramas(Iterable<Drama> dramas) =>
      _refreshDramas(dramas, cacheSeriesCandidates: true);

  Future<void> _refreshDramas(
    Iterable<Drama> dramas, {
    required bool cacheSeriesCandidates,
  }) {
    final updates = dramas.toList();
    return backend.run(() async {
      if (backend.locked) return;
      final changes = <String, Object>{};
      final favorites = Map.of(_favorites);
      final history = Map.of(_history);
      final states = Map.of(_followStates);
      final seriesCandidates = Map.of(_seriesCandidates);
      for (final drama in updates) {
        if (!backend.allowsSource(drama.source)) continue;
        if (cacheSeriesCandidates && drama.source == SourceSite.hongguo.id) {
          seriesCandidates[drama.id] = (seriesCandidates[drama.id] ?? drama)
              .merge(drama);
        }
        final favorite = favorites[drama.id];
        if (favorite != null) {
          favorites[drama.id] = favorite.merge(drama);
          states[drama.id] = states[drama.id]!.observe(favorites[drama.id]!);
        }
        final watched = history[drama.id];
        if (watched != null) {
          history[drama.id] = WatchEntry(
            drama: watched.drama.merge(drama),
            episode: watched.episode,
            position: watched.position,
            duration: watched.duration,
            updatedAt: watched.updatedAt,
          );
        }
      }
      final candidates = <String, Drama>{
        for (final entry in history.values) entry.drama.id: entry.drama,
        ...favorites,
        for (final drama in updates)
          if (backend.allowsSource(drama.source)) drama.id: drama,
      };
      for (final state in states.values) {
        for (final notice in state.seriesSeasons.values) {
          candidates.putIfAbsent(
            notice.id,
            () => Drama(
              id: notice.id,
              source: SourceSite.hongguo.id,
              sourceId: notice.id.substring(SourceSite.hongguo.id.length + 1),
              title: notice.title,
            ),
          );
        }
      }
      final favoriteIds = favorites.keys.toSet();
      for (final favorite in favorites.values) {
        if (favorite.source != SourceSite.hongguo.id ||
            states[favorite.id] == null) {
          continue;
        }
        states[favorite.id] = observeHongguoSeriesSeasons(
          anchor: favorite,
          state: states[favorite.id]!,
          candidates: candidates.values,
          favoriteIds: favoriteIds,
        );
      }
      final favoriteJson = jsonEncode(
        favorites.values.map((entry) => entry.toJson()).toList(),
      );
      final historyJson = jsonEncode(
        history.values.map((entry) => entry.toJson()).toList(),
      );
      final statesJson = _encodeFollowStates(states);
      final cachedCandidates = cacheSeriesCandidates
          ? (seriesCandidates.values.toList()
                  ..sort((a, b) => a.id.compareTo(b.id)))
                .take(2000)
                .toList()
          : null;
      final seriesCandidateJson = cachedCandidates == null
          ? null
          : jsonEncode(
              cachedCandidates.map((entry) => entry.toJson()).toList(),
            );
      if (favoriteJson !=
          jsonEncode(
            _favorites.values.map((entry) => entry.toJson()).toList(),
          )) {
        changes['favorites'] = favoriteJson;
      }
      if (historyJson !=
          jsonEncode(_history.values.map((entry) => entry.toJson()).toList())) {
        changes['history'] = historyJson;
      }
      if (statesJson != _encodeFollowStates(_followStates)) {
        changes['followStates'] = statesJson;
      }
      final seriesChanged =
          seriesCandidateJson != null &&
          seriesCandidateJson != backend.rawPreference(seriesKey);
      if (seriesChanged) {
        await backend.setRawPreference(seriesKey, seriesCandidateJson);
        _seriesCandidates
          ..clear()
          ..addEntries(
            cachedCandidates!.map((drama) => MapEntry(drama.id, drama)),
          );
      }
      if (changes.isEmpty) {
        if (seriesChanged) backend.notify();
        return;
      }
      await backend.commit(changes);
      load();
      backend.notify();
    });
  }
}
