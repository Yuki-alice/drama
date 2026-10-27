import 'dart:convert';

import 'package:duanju_app/core/catalog_sort.dart';
import 'package:duanju_app/core/download_preferences.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/playback_preferences.dart';

/// [SettingsStore] 所需的偏好读写能力，由 LocalStore 实现。
abstract interface class SettingsBackend {
  bool get locked;
  bool allowsSource(String source);
  List<SourceSite> get availableSources;
  String? read(String key);
  bool? readBool(String key);
  Future<void> run(Future<void> Function() action);
  Future<void> commit(Map<String, Object> changes);
  void notify();
}

/// 主题、播放/下载偏好、目录视图与搜索记录。
class SettingsStore {
  SettingsStore(this.backend);

  final SettingsBackend backend;

  bool get hideVip =>
      backend.locked ? true : backend.readBool('hideVip') ?? true;

  String get themeMode {
    final value = backend.locked ? null : backend.read('themeMode');
    return {'light', 'dark', 'system'}.contains(value) ? value! : 'system';
  }

  bool get autoExport =>
      !backend.locked && (backend.readBool('autoExport') ?? false);
  bool get exportPosters =>
      !backend.locked && (backend.readBool('exportPosters') ?? false);

  String get source {
    if (backend.locked) return '';
    final value = backend.read('source') ?? '';
    final sources = backend.availableSources;
    return sources.any((site) => site.id == value)
        ? value
        : sources.firstOrNull?.id ?? '';
  }

  DownloadPreferences get downloadPreferences {
    if (backend.locked) return const DownloadPreferences();
    try {
      return DownloadPreferences.fromJson(
        jsonDecode(backend.read('downloadPreferences') ?? '{}')
            as Map<String, dynamic>,
      );
    } catch (_) {
      return const DownloadPreferences();
    }
  }

  PlaybackPreferences get playbackPreferences {
    if (backend.locked) return const PlaybackPreferences();
    try {
      return PlaybackPreferences.fromJson(
        jsonDecode(backend.read('playback') ?? '{}') as Map<String, dynamic>,
      );
    } catch (_) {
      return const PlaybackPreferences();
    }
  }

  CatalogView get catalogView {
    if (backend.locked) return const CatalogView();
    try {
      return CatalogView.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(backend.read('catalogView') ?? '{}') as Map,
        ),
      );
    } catch (_) {
      return const CatalogView();
    }
  }

  List<String> get recentSearches {
    if (backend.locked) return const [];
    try {
      return (jsonDecode(backend.read('recentSearches') ?? '[]') as List)
          .whereType<String>()
          .take(20)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _setting(String key, Object value) => backend.run(() async {
    if (backend.locked) throw StateError('当前用户已变更，请重试');
    await backend.commit({key: value});
    backend.notify();
  });

  Future<void> setExportPosters(bool value) => _setting('exportPosters', value);

  Future<void> setAutoExport(bool value) => _setting('autoExport', value);

  Future<void> setHideVip(bool value) => _setting('hideVip', value);

  Future<void> setSource(String value) {
    if (!backend.allowsSource(value)) {
      return Future.error(StateError('当前用户没有此站源权限'));
    }
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

  Future<void> setCatalogView(CatalogView value) =>
      _setting('catalogView', jsonEncode(value.toJson()));

  Future<void> setCatalogSource(String source, {required bool allSources}) {
    return backend.run(() async {
      if (!backend.allowsSource(source)) {
        throw StateError('当前用户没有此站源权限');
      }
      await backend.commit({
        'source': source,
        'catalogView': jsonEncode(
          catalogView.copyWith(allSources: allSources).toJson(),
        ),
      });
      backend.notify();
    });
  }

  Future<void> rememberSearch(String text) {
    final query = text.trim();
    if (query.isEmpty || query.runes.length > 80) return Future.value();
    return backend.run(() async {
      if (backend.locked) return;
      final entries = [
        query,
        ...recentSearches.where(
          (entry) => normalizedSearchText(entry) != normalizedSearchText(query),
        ),
      ].take(20).toList();
      await backend.commit({'recentSearches': jsonEncode(entries)});
      backend.notify();
    });
  }

  Future<void> forgetSearch(String text) {
    final entries = recentSearches.where((entry) => entry != text).toList();
    return _setting('recentSearches', jsonEncode(entries));
  }

  Future<void> clearRecentSearches() => _setting('recentSearches', '[]');
}
