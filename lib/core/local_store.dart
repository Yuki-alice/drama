import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/core/local_snapshot.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/core/source_access_policy.dart';
import 'package:duanju_app/core/download_preferences.dart';
import 'package:duanju_app/core/catalog_sort.dart';
import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/core/library_store.dart';
import 'package:duanju_app/core/settings_store.dart';
import 'package:duanju_app/core/lan_sync_models.dart';

part 'local_store_sync.dart';

/// 单用户本地存储：历史、追剧、站源开关与各项设置。
class LocalStore extends ChangeNotifier
    implements LibraryBackend, SettingsBackend {
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
  LibraryStore? _library;
  late final SettingsStore _settings = SettingsStore(this);
  LibraryStore get _lib => _library!;
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;
  String? _configurationError;
  SourceAccessPolicy _policy = SourceAccessPolicy.empty;

  void _initialize() {
    try {
      _snapshot = LocalSnapshot(preferences);
      _configurationError = null;
      _loadSourceSwitches();
      _library = LibraryStore(this);
    } catch (_) {
      _block('本地配置损坏，已锁定访问。原始记录已保留，请重新读取或从备份恢复。');
    }
  }

  void _block(String message) {
    _configurationError = message;
    _library?.clear();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 扩展安装/卸载后刷新站源列表；其余本地数据不变。
  void refreshSources() => _notify();

  String? _string(String key) => _snapshot?.getString(key);
  bool? _bool(String key) => _snapshot?.getBool(key);
  String? get configurationError => _configurationError;
  @override
  bool get locked => _configurationError != null;

  @override
  bool get canDownload => !locked;
  @override
  bool allowsSource(String source) => !locked && _policy.allows(source);

  List<SourceSite> get sources => locked ? const [] : _policy.available;

  bool sourceEnabled(String source) => _policy.enabled(source);

  void _loadSourceSwitches() {
    _policy = SourceAccessPolicy.decode(_string('sourceSwitches'));
  }

  Future<void> setSourceEnabled(String source, bool enabled) {
    if (!SourceSite.isAvailable(source)) {
      return Future.error(StateError('站源无效'));
    }
    return _queue(() async {
      final policy = _policy.withSource(source, enabled);
      await _commit({'sourceSwitches': policy.encode()});
      _policy = policy;
      _notify();
    });
  }

  String get _seriesKey => 'seriesCandidates';

  Map<String, FollowCheck> get followChecks => _lib.followChecks;

  Future<void> saveFollowChecks(Map<String, FollowCheck> checks) =>
      _lib.saveFollowChecks(checks);

  List<WatchEntry> get history => _lib.history;
  List<Drama> get favorites => _lib.favorites;
  WatchEntry? watched(String id) => _lib.watched(id);
  bool isFavorite(String id) => _lib.isFavorite(id);
  FollowState? following(String id) => _lib.following(id);
  List<Drama> seriesDramasFor(Drama anchor) => _lib.seriesDramasFor(anchor);

  bool get hideVip => _settings.hideVip;

  String get themeMode => _settings.themeMode;

  bool get autoExport => _settings.autoExport;
  bool get exportPosters => _settings.exportPosters;
  String get source => _settings.source;
  DownloadPreferences get downloadPreferences => _settings.downloadPreferences;
  PlaybackPreferences get playbackPreferences => _settings.playbackPreferences;
  CatalogView get catalogView => _settings.catalogView;
  List<String> get recentSearches => _settings.recentSearches;

  Future<void> setCatalogView(CatalogView value) =>
      _settings.setCatalogView(value);

  Future<void> setCatalogSource(String source, {required bool allSources}) =>
      _settings.setCatalogSource(source, allSources: allSources);

  Future<void> rememberSearch(String text) => _settings.rememberSearch(text);

  Future<void> clearRecentSearches() => _settings.clearRecentSearches();

  Future<void> forgetSearch(String text) => _settings.forgetSearch(text);

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

  Future<void> setExportPosters(bool value) =>
      _settings.setExportPosters(value);
  Future<void> setAutoExport(bool value) => _settings.setAutoExport(value);
  Future<void> setHideVip(bool value) => _settings.setHideVip(value);
  Future<void> setSource(String value) => _settings.setSource(value);
  Future<void> setThemeMode(String value) => _settings.setThemeMode(value);
  Future<void> setPlaybackPreferences(PlaybackPreferences value) =>
      _settings.setPlaybackPreferences(value);
  Future<void> setDownloadPreferences(DownloadPreferences value) =>
      _settings.setDownloadPreferences(value);

  Future<void> toggleFavorite(Drama drama) => _lib.toggleFavorite(drama);
  Future<void> setFollowStatus(Drama drama, FollowStatus status) =>
      _lib.setFollowStatus(drama, status);
  Future<void> markUpdatesRead(String id) => _lib.markUpdatesRead(id);
  Future<void> markSeriesSeasonRead(String id, String seasonId) =>
      _lib.markSeriesSeasonRead(id, seasonId);
  Future<void> saveWatch(WatchEntry entry) => _lib.saveWatch(entry);
  WatchEntry? mediaWatched(String id) => _lib.mediaWatched(id);
  Future<void> saveMediaWatch(String id, WatchEntry entry) =>
      _lib.saveMediaWatch(id, entry);
  Future<void> clearHistory() => _lib.clearHistory();
  Future<void> removeHistory(String id) => _lib.removeHistory(id);
  Future<void> refreshDrama(Drama drama) => _lib.refreshDrama(drama);
  Future<void> refreshDramas(Iterable<Drama> dramas) =>
      _lib.refreshDramas(dramas);

  Future<String> exportBackup() async {
    await _writes.catchError((Object _) {});
    final content = jsonEncode({
      'schema': 2,
      'app': 'zhenguojian',
      'themeMode': themeMode,
      'autoExport': autoExport,
      'exportPosters': exportPosters,
      'sourceSwitches': _policy.raw,
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
    _lib.load();
    _lib.loadSeriesCandidates();
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
  String? read(String key) => _string(key);

  @override
  String? rawPreference(String key) => preferences.getString(key);

  @override
  Future<void> setRawPreference(String key, String value) =>
      preferences.setString(key, value);

  @override
  Future<void> run(Future<void> Function() action) => _queue(action);

  @override
  Future<void> commit(
    Map<String, Object> changes, {
    Iterable<String> remove = const [],
    Set<String> clearSyncProgress = const {},
    bool syncUrgent = true,
  }) => _commit(
    changes,
    remove: remove,
    clearSyncProgress: clearSyncProgress,
    syncUrgent: syncUrgent,
  );

  @override
  bool? readBool(String key) => _bool(key);

  @override
  List<SourceSite> get availableSources => sources;

  @override
  WatchEntry? lanWatch(String id) {
    try {
      return lanDocument.records[id]?.watch;
    } catch (_) {
      return null;
    }
  }

  @override
  Set<String> get lanRecordIds {
    try {
      return lanDocument.records.keys.toSet();
    } catch (_) {
      return const {};
    }
  }

  @override
  void invalidateLanDocument() => _lanDocumentCache = null;

  @override
  void notify() => _notify();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
