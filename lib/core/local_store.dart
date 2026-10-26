import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/core/local_snapshot.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/core/download_preferences.dart';
import 'package:duanju_app/core/catalog_sort.dart';
import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/core/hongguo_series.dart';
import 'package:duanju_app/core/lan_sync_models.dart';

part 'local_store_sync.dart';

/// 单用户本地存储：历史、追剧、站源开关与各项设置。
class LocalStore extends ChangeNotifier {
  LocalStore(this.preferences) {
    _initialize();
  }

  final SharedPreferences preferences;
  LocalSnapshot? _snapshot;
  LanDocument? _lanDocumentCache;
  int _lanRevision = 0;
  int _lanUrgentRevision = 0;
  int get lanRevision => _lanRevision;
  int get lanUrgentRevision => _lanUrgentRevision;
  final Map<String, WatchEntry> _history = {};
  final Map<String, Drama> _favorites = {};
  final Map<String, FollowState> _followStates = {};
  final Map<String, Drama> _seriesCandidates = {};
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;
  String? _configurationError;
  Map<String, bool> _sourceSwitches = {};

  void _initialize() {
    try {
      _snapshot = LocalSnapshot(preferences);
      _configurationError = null;
      _loadSourceSwitches();
      _loadLibrary();
      _loadSeriesCandidates();
    } catch (_) {
      _block('本地配置损坏，已锁定访问。原始记录已保留，请重新读取或从备份恢复。');
    }
  }

  void _block(String message) {
    _configurationError = message;
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    _seriesCandidates.clear();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 扩展安装/卸载后刷新站源列表；其余本地数据不变。
  void refreshSources() => _notify();

  String? _string(String key) => _snapshot?.getString(key);
  bool? _bool(String key) => _snapshot?.getBool(key);
  String? get configurationError => _configurationError;
  bool get locked => _configurationError != null;

  bool get canDownload => !locked;
  bool allowsSource(String source) =>
      !locked && SourceSite.isAvailable(source) && sourceEnabled(source);
  List<SourceSite> get sources =>
      SourceSite.values.where((site) => allowsSource(site.id)).toList();

  bool sourceEnabled(String source) =>
      _sourceSwitches[source] ?? !SourceSite.isRestricted(source);

  void _loadSourceSwitches() {
    try {
      final raw = _string('sourceSwitches');
      _sourceSwitches = raw == null
          ? {}
          : Map<String, bool>.from(jsonDecode(raw) as Map);
    } catch (_) {
      _sourceSwitches = {};
    }
  }

  Future<void> setSourceEnabled(String source, bool enabled) {
    if (!SourceSite.isAvailable(source)) {
      return Future.error(StateError('站源无效'));
    }
    return _queue(() async {
      final switches = {..._sourceSwitches, source: enabled};
      await _commit({'sourceSwitches': jsonEncode(switches)});
      _sourceSwitches = switches;
      _notify();
    });
  }

  void _loadLibrary() {
    _lanDocumentCache = null;
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    if (_configurationError != null) return;
    for (final row in readJsonList(_string('history'))) {
      try {
        final entry = WatchEntry.fromJson(row);
        _history[entry.drama.id] = entry;
      } catch (_) {}
    }
    for (final row in readJsonList(_string('favorites'))) {
      try {
        final drama = Drama.fromJson(row);
        _favorites[drama.id] = drama;
      } catch (_) {}
    }
    Map<String, dynamic> states = {};
    try {
      states = Map<String, dynamic>.from(
        jsonDecode(_string('followStates') ?? '{}') as Map,
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

  String get _seriesKey => 'seriesCandidates';
  String get _followChecksKey => 'followChecks';

  Map<String, FollowCheck> get followChecks {
    try {
      final data =
          jsonDecode(preferences.getString(_followChecksKey) ?? '{}') as Map;
      return {
        for (final entry in data.entries)
          entry.key as String: FollowCheck.fromJson(entry.value),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveFollowChecks(Map<String, FollowCheck> checks) =>
      _queue(() async {
        if (locked) return;
        await preferences.setString(
          _followChecksKey,
          jsonEncode({
            for (final entry in checks.entries)
              if (_favorites.containsKey(entry.key))
                entry.key: entry.value.toJson(),
          }),
        );
      });

  void _loadSeriesCandidates() {
    _seriesCandidates.clear();
    if (_configurationError != null) return;
    for (final row in readJsonList(preferences.getString(_seriesKey))) {
      try {
        final drama = Drama.fromJson(row);
        if (drama.source == SourceSite.hongguo.id) {
          _seriesCandidates[drama.id] = drama;
        }
      } catch (_) {}
    }
  }

  List<WatchEntry> get history =>
      _history.values
          .where((entry) => allowsSource(entry.drama.source))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  List<Drama> get favorites => _favorites.values
      .where((drama) => allowsSource(drama.source))
      .toList()
      .reversed
      .toList();
  WatchEntry? watched(String id) {
    WatchEntry? entry = _history[id];
    if (entry == null && isFavorite(id)) {
      try {
        entry = lanDocument.records[id]?.watch;
      } catch (_) {}
    }
    return entry != null && allowsSource(entry.drama.source) ? entry : null;
  }

  bool isFavorite(String id) =>
      _favorites[id] != null && allowsSource(_favorites[id]!.source);
  FollowState? following(String id) =>
      isFavorite(id) ? _followStates[id] : null;
  List<Drama> seriesDramasFor(Drama anchor) {
    if (!allowsSource(SourceSite.hongguo.id) ||
        anchor.source != SourceSite.hongguo.id) {
      return const [];
    }
    final items = <String, Drama>{};
    for (final drama in _seriesCandidates.values) {
      if (allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final drama in _favorites.values) {
      if (allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final entry in _history.values) {
      if (allowsSource(entry.drama.source)) items[entry.drama.id] = entry.drama;
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

  bool get hideVip =>
      _configurationError == null ? _bool('hideVip') ?? true : true;

  String get themeMode {
    final value = _configurationError == null ? _string('themeMode') : null;
    return {'light', 'dark', 'system'}.contains(value) ? value! : 'system';
  }

  bool get autoExport => !locked && (_bool('autoExport') ?? false);
  bool get exportPosters => !locked && (_bool('exportPosters') ?? false);
  String get source {
    if (locked) return '';
    final value = _string('source') ?? '';
    return sources.any((site) => site.id == value)
        ? value
        : sources.firstOrNull?.id ?? '';
  }

  DownloadPreferences get downloadPreferences {
    if (locked) return const DownloadPreferences();
    try {
      return DownloadPreferences.fromJson(
        jsonDecode(_string('downloadPreferences') ?? '{}')
            as Map<String, dynamic>,
      );
    } catch (_) {
      return const DownloadPreferences();
    }
  }

  PlaybackPreferences get playbackPreferences {
    if (locked) return const PlaybackPreferences();
    try {
      return PlaybackPreferences.fromJson(
        jsonDecode(_string('playback') ?? '{}') as Map<String, dynamic>,
      );
    } catch (_) {
      return const PlaybackPreferences();
    }
  }

  CatalogView get catalogView {
    if (locked) return const CatalogView();
    try {
      return CatalogView.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(_string('catalogView') ?? '{}') as Map,
        ),
      );
    } catch (_) {
      return const CatalogView();
    }
  }

  List<String> get recentSearches {
    if (locked) return const [];
    try {
      return (jsonDecode(_string('recentSearches') ?? '[]') as List)
          .whereType<String>()
          .take(20)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setCatalogView(CatalogView value) =>
      _setting('catalogView', jsonEncode(value.toJson()));

  Future<void> setCatalogSource(String source, {required bool allSources}) {
    return _queue(() async {
      if (!allowsSource(source)) {
        throw StateError('当前用户没有此站源权限');
      }
      await _commit({
        'source': source,
        'catalogView': jsonEncode(
          catalogView.copyWith(allSources: allSources).toJson(),
        ),
      });
      _notify();
    });
  }

  Future<void> rememberSearch(String text) {
    final query = text.trim();
    if (query.isEmpty || query.runes.length > 80) return Future.value();
    return _queue(() async {
      if (locked) return;
      final entries = [
        query,
        ...recentSearches.where(
          (entry) => normalizedSearchText(entry) != normalizedSearchText(query),
        ),
      ].take(20).toList();
      await _commit({'recentSearches': jsonEncode(entries)});
      _notify();
    });
  }

  Future<void> clearRecentSearches() => _setting('recentSearches', '[]');

  Future<void> forgetSearch(String text) {
    final entries = recentSearches
        .where((entry) => entry != text)
        .toList();
    return _setting('recentSearches', jsonEncode(entries));
  }

  Future<void> _commit(
    Map<String, Object> changes, {
    Iterable<String> remove = const [],
    bool replace = false,
    bool trackSync = true,
    bool syncUrgent = true,
    Set<String> clearSyncProgress = const {},
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null) throw StateError('请先恢复本地配置');
    final values = replace ? <String, Object>{} : snapshot.values;
    for (final key in remove) {
      values.remove(key);
    }
    values.addAll(changes);
    if (trackSync && !replace) {
      _trackLanChanges(
        values,
        keys: {...changes.keys, ...remove},
        clearProgress: clearSyncProgress,
      );
    }
    try {
      await snapshot.commit(values);
      if (trackSync &&
          !replace &&
          {...changes.keys, ...remove}.any(
            (key) =>
                key == 'favorites' || key == 'history' || key == 'followStates',
          )) {
        _lanRevision++;
        if (syncUrgent) _lanUrgentRevision++;
      }
    } on SnapshotRecoveryRequired catch (error) {
      _block(error.toString());
      _notify();
      rethrow;
    }
  }

  Future<void> _setting(String key, Object value) {
    return _queue(() async {
      if (locked) throw StateError('当前用户已变更，请重试');
      await _commit({key: value});
      _notify();
    });
  }

  Future<void> setExportPosters(bool value) => _setting('exportPosters', value);
  Future<void> setAutoExport(bool value) => _setting('autoExport', value);
  Future<void> setHideVip(bool value) => _setting('hideVip', value);
  Future<void> setSource(String value) {
    if (!allowsSource(value)) return Future.error(StateError('当前用户没有此站源权限'));
    return _setting('source', value);
  }

  Future<void> setThemeMode(String value) =>
      {'light', 'dark', 'system'}.contains(value)
      ? _setting('themeMode', value)
      : Future.value();
  Future<void> setPlaybackPreferences(PlaybackPreferences value) {
    PlaybackPreferences.fromJson(value.toJson());
    return _setting('playback', jsonEncode(value.toJson()));
  }

  Future<void> setDownloadPreferences(DownloadPreferences value) {
    DownloadPreferences.fromJson(value.toJson());
    return _setting('downloadPreferences', jsonEncode(value.toJson()));
  }

  Future<void> toggleFavorite(Drama drama) {
    return _queue(() async {
      if (!allowsSource(drama.source)) return;
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
      await _commit({
        'favorites': jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        'followStates': _encodeFollowStates(states),
      });
      _loadLibrary();
      _notify();
    });
  }

  String _encodeFollowStates(Map<String, FollowState> states) => jsonEncode({
    for (final entry in states.entries) entry.key: entry.value.toJson(),
  });

  Future<void> setFollowStatus(Drama drama, FollowStatus status) {
    return _queue(() async {
      if (!allowsSource(drama.source)) return;
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
      await _commit({
        'favorites': jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        'followStates': _encodeFollowStates(states),
      });
      _loadLibrary();
      _notify();
    });
  }

  Future<void> markUpdatesRead(String id) {
    return _queue(() async {
      if (!isFavorite(id)) return;
      final states = Map.of(_followStates)
        ..[id] = _followStates[id]!.markRead();
      await _commit({'followStates': _encodeFollowStates(states)});
      _loadLibrary();
      _notify();
    });
  }

  Future<void> markSeriesSeasonRead(String id, String seasonId) {
    return _queue(() async {
      if (!isFavorite(id)) return;
      final current = _followStates[id]!;
      final updated = current.markSeriesSeasonRead(seasonId);
      if (identical(current, updated)) return;
      final states = Map.of(_followStates)..[id] = updated;
      await _commit({'followStates': _encodeFollowStates(states)});
      _loadLibrary();
      _notify();
    });
  }

  Future<void> saveWatch(WatchEntry entry) {
    return _queue(() async {
      if (!allowsSource(entry.drama.source)) return;
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
      await _commit({
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
      _loadLibrary();
      _notify();
    });
  }

  WatchEntry? mediaWatched(String id) {
    if (!canDownload) return null;
    try {
      final data = jsonDecode(_string('mediaHistory') ?? '{}') as Map;
      final entry = data[id] == null
          ? null
          : WatchEntry.fromJson(Map<String, dynamic>.from(data[id] as Map));
      return entry != null && allowsSource(entry.drama.source) ? entry : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMediaWatch(String id, WatchEntry entry) {
    return _queue(() async {
      if (!canDownload || !allowsSource(entry.drama.source)) {
        return;
      }
      final data = jsonDecode(_string('mediaHistory') ?? '{}') as Map;
      data.remove(id);
      data[id] = entry.toJson();
      while (data.length > 300) {
        data.remove(data.keys.first);
      }
      await _commit({'mediaHistory': jsonEncode(data)});
    });
  }

  Future<void> clearHistory() {
    return _queue(() async {
      if (locked) return;
      await _commit(
        {},
        remove: ['history'],
        clearSyncProgress: {..._history.keys, ...lanDocument.records.keys},
      );
      _loadLibrary();
      _notify();
    });
  }

  Future<void> removeHistory(String id) {
    return _queue(() async {
      if (watched(id) == null) return;
      final entries = Map.of(_history)..remove(id);
      await _commit(
        {
          'history': jsonEncode(
            entries.values.map((entry) => entry.toJson()).toList(),
          ),
        },
        clearSyncProgress: {id},
      );
      _loadLibrary();
      _notify();
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
    return _queue(() async {
      if (locked) return;
      final changes = <String, Object>{};
      final favorites = Map.of(_favorites);
      final history = Map.of(_history);
      final states = Map.of(_followStates);
      final seriesCandidates = Map.of(_seriesCandidates);
      for (final drama in updates) {
        if (!allowsSource(drama.source)) continue;
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
          if (allowsSource(drama.source)) drama.id: drama,
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
          seriesCandidateJson != preferences.getString(_seriesKey);
      if (seriesChanged) {
        await preferences.setString(_seriesKey, seriesCandidateJson);
        _seriesCandidates
          ..clear()
          ..addEntries(
            cachedCandidates!.map((drama) => MapEntry(drama.id, drama)),
          );
      }
      if (changes.isEmpty) {
        if (seriesChanged) _notify();
        return;
      }
      await _commit(changes);
      _loadLibrary();
      _notify();
    });
  }

  Future<String> exportBackup() async {
    await _writes.catchError((Object _) {});
    final content = jsonEncode({
      'schema': 2,
      'app': 'zhenguojian',
      'themeMode': themeMode,
      'autoExport': autoExport,
      'exportPosters': exportPosters,
      'sourceSwitches': _sourceSwitches,
      'library': {
        ..._backupFollowSync(),
        'history': readJsonList(_string('history')),
        'favorites': readJsonList(_string('favorites')),
        'followStates': jsonDecode(_string('followStates') ?? '{}'),
        'seriesCandidates': readJsonList(preferences.getString(_seriesKey)),
        'mediaHistory': jsonDecode(_string('mediaHistory') ?? '{}'),
        'source': _string('source') ?? '',
        'hideVip': _bool('hideVip') ?? true,
        'playback': jsonDecode(_string('playback') ?? '{}'),
        'downloadPreferences': jsonDecode(
          _string('downloadPreferences') ?? '{}',
        ),
        'catalogView': jsonDecode(_string('catalogView') ?? '{}'),
        'recentSearches': jsonDecode(_string('recentSearches') ?? '[]'),
      },
    });
    if (utf8.encode(content).length > 8 * 1024 * 1024) {
      throw StateError('备份超过 8 MiB 保存上限，请先整理记录；尚未写出备份文件');
    }
    validateBackup(content);
    return content;
  }

  Map<String, dynamic> validateBackup(String content) {
    if (utf8.encode(content).length > 8 * 1024 * 1024) {
      throw const FormatException('备份文件过大');
    }
    final data = jsonDecode(content) as Map<String, dynamic>;
    if (data['app'] != 'zhenguojian' || data['schema'] != 2) {
      throw const FormatException('不支持的备份格式');
    }
    if (data.containsKey('themeMode') &&
        !{'light', 'dark', 'system'}.contains(data['themeMode'])) {
      throw const FormatException('备份主题设置无效');
    }
    _validateBackupLibrary(data['library'] as Map);
    return data;
  }

  void _validateBackupLibrary(Map library) {
    final history = library['history'] as List,
        favorites = library['favorites'] as List;
    final media = library['mediaHistory'] as Map? ?? {};
    if (media.length > 300 ||
        history.length > 300 ||
        favorites.length > 20000) {
      throw const FormatException('备份记录过多');
    }
    for (final row in [...history, ...media.values]) {
      WatchEntry.fromJson(Map<String, dynamic>.from(row as Map));
    }
    for (final row in favorites) {
      Drama.fromJson(Map<String, dynamic>.from(row as Map));
    }
    final states = library['followStates'] as Map? ?? {};
    final seriesCandidates = library['seriesCandidates'] as List? ?? [];
    final favoriteIds = favorites.map((row) => (row as Map)['id']).toSet();
    _readBackupFollowSync(library);
    if (states.length > 20000 ||
        states.keys.any((id) => id is! String || !favoriteIds.contains(id))) {
      throw const FormatException('备份追剧状态无效');
    }
    for (final row in states.values) {
      FollowState.fromJson(Map<String, dynamic>.from(row as Map));
    }
    if (seriesCandidates.length > 2000) {
      throw const FormatException('备份系列候选过多');
    }
    for (final row in seriesCandidates) {
      Drama.fromJson(Map<String, dynamic>.from(row as Map));
    }
    if (library['hideVip'] is! bool || library['source'] is! String) {
      throw const FormatException('备份设置无效');
    }
    PlaybackPreferences.fromJson(
      Map<String, dynamic>.from(library['playback'] as Map? ?? {}),
    );
    DownloadPreferences.fromJson(
      Map<String, dynamic>.from(library['downloadPreferences'] as Map? ?? {}),
    );
    CatalogView.fromJson(
      Map<String, dynamic>.from(library['catalogView'] as Map? ?? {}),
    );
    final searches = library['recentSearches'] as List? ?? [];
    if (searches.length > 20 ||
        searches.any((value) => value is! String || value.runes.length > 80)) {
      throw const FormatException('备份搜索记录无效');
    }
  }

  Future<void> _installBackup(Map<String, dynamic> data) async {
    final library = data['library'] as Map;
    final syncRecords = _readBackupFollowSync(library);
    final values = <String, Object>{
      'themeMode': data['themeMode'] as String? ?? themeMode,
      'autoExport': data['autoExport'] == true,
      'exportPosters': data['exportPosters'] == true,
      'sourceSwitches': jsonEncode(
        data['sourceSwitches'] is Map
            ? data['sourceSwitches']
            : const <String, bool>{},
      ),
      if (syncRecords != null)
        'lanRecords': jsonEncode(
          LanDocument(replica: lanID(), records: syncRecords).toJson(),
        ),
      'history': jsonEncode(library['history']),
      'favorites': jsonEncode(library['favorites']),
      'followStates': jsonEncode(library['followStates'] ?? {}),
      'mediaHistory': jsonEncode(library['mediaHistory'] ?? {}),
      'source': library['source'] as String,
      'hideVip': library['hideVip'] as bool,
      'playback': jsonEncode(library['playback'] ?? {}),
      'downloadPreferences': jsonEncode(library['downloadPreferences'] ?? {}),
      'catalogView': jsonEncode(library['catalogView'] ?? {}),
      'recentSearches': jsonEncode(library['recentSearches'] ?? []),
    };
    await _commit(values, replace: true);
    await preferences.setString(
      _seriesKey,
      jsonEncode(library['seriesCandidates'] ?? []),
    );
    _configurationError = null;
    _loadSourceSwitches();
    _loadLibrary();
    _loadSeriesCandidates();
    _notify();
  }

  Future<void> importBackup(String content) => _queue(() async {
    await _installBackup(validateBackup(content));
  });

  Future<void> recoverBackup(String content) => _queue(() async {
    if (_configurationError == null) throw StateError('请从设置中恢复备份');
    final data = validateBackup(content);
    _snapshot ??= LocalSnapshot.empty(preferences);
    await _installBackup(data);
  });

  String exportRecoveryData() {
    if (_configurationError == null) throw StateError('请从设置中导出备份');
    return jsonEncode({
      'app': 'zhenguojian',
      'recovery': true,
      'values': {
        for (final key in preferences.getKeys())
          if (LocalSnapshot.owns(key) || key == LocalSnapshot.storageKey)
            key: preferences.get(key),
      },
    });
  }

  Future<void> reload() => _queue(() async {
    await preferences.reload();
    _initialize();
    _notify();
  });

  Future<void> _queue(Future<void> Function() action) {
    _writes = _writes.catchError((Object _) {}).then((_) => action());
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
