import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/source_status.dart';

/// 站源规则的状态、安装与更新逻辑；弹窗、剪贴板与选中态留在 View。
class SourcesViewModel extends ChangeNotifier {
  SourcesViewModel({required this.repository, required this.store, this.drama});

  final AppRepository repository;
  final LocalStore store;
  final Drama? drama;

  final statuses = <String, SourceStatus>{};
  final errors = <String, String>{};
  final pending = <String>{};
  final revisions = <String, int>{};
  final installed = <String, Map<String, dynamic>>{};
  final catalogBusy = <String>{};

  /// 每源设置项缓存：key 是源 ID，value 是该源的设置列表。
  final settings = <String, List<Map<String, dynamic>>>{};
  final settingsBusy = <String>{};
  List<Map<String, dynamic>> catalog = const [];
  String? catalogError;
  bool polling = false;
  bool updatingAll = false;

  /// 远端扩展仓库是否已配置。为 false 时说明这个包还没接真实索引地址，
  /// 界面上只提供随包扩展，不要把它显示成"仓库为空"。
  bool remoteConfigured = false;
  bool deleting = false;
  bool _uninstalling = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> loadExtensions({bool remote = true}) async {
    String? error;
    var rows = const <Map<String, dynamic>>[];
    try {
      rows = await repository.installedExtensions();
      SourceSite.setInstalledExtensions(rows);
      store.refreshSources();
    } catch (failure) {
      error = failure.toString();
    }
    final installedRows = {
      for (final row in rows) row['id'] as String? ?? '': row,
    };
    installed
      ..clear()
      ..addAll(installedRows);

    // 随包索引是离线兜底：它保证「规则仓库」在无网络时仍可安装。
    var entries = <Map<String, dynamic>>[];
    try {
      final raw = await rootBundle.loadString('extensions-repo/index.json');
      entries = [
        for (final row in jsonDecode(raw) as List)
          if (row is Map) Map<String, dynamic>.from(row),
      ];
    } catch (failure) {
      catalogError = failure.toString();
    }

    // 远端索引提供版本、更新与下架；失败时静默沿用随包索引。
    // 没有这一步，「扩展坏了当天修、不用发版」无法兑现。
    if (remote && repository.supportsSourceManagement) {
      try {
        final remoteRows = await repository.extensionIndex();
        if (remoteRows.isNotEmpty) {
          entries = _mergeCatalog(entries, remoteRows);
          catalogError = error;
        }
        remoteConfigured = remoteRows.isNotEmpty;
      } catch (_) {
        // 离线或索引不可达：保持随包结果，不打断站源页。
        remoteConfigured = false;
      }
    } else {
      remoteConfigured = false;
    }

    catalog = [
      for (final entry in entries)
        {
          ...entry,
          'bundled': true,
          'installed': installedRows.containsKey(entry['id']),
          'updateAvailable':
              installedRows[entry['id']]?['version'] != null &&
              entry['version'] != null &&
              installedRows[entry['id']]!['version'] != entry['version'],
        },
    ];
    catalogError ??= error;
    notifyListeners();
  }

  /// 合并随包与远端索引：远端优先（它是最新元数据），随包条目保留为兜底。
  List<Map<String, dynamic>> _mergeCatalog(
    List<Map<String, dynamic>> bundled,
    List<Map<String, dynamic>> remote,
  ) {
    final merged = <String, Map<String, dynamic>>{
      for (final entry in bundled) entry['id'] as String? ?? '': entry,
    };
    for (final entry in remote) {
      final id = entry['id'] as String? ?? '';
      if (id.isEmpty) continue;
      merged[id] = {...?merged[id], ...entry};
    }
    return merged.values.toList();
  }

  Future<void> toggleInCatalog(Map<String, dynamic> entry) async {
    final id = entry['id'] as String? ?? '';
    if (id.isEmpty || catalogBusy.contains(id)) return;
    catalogBusy.add(id);
    notifyListeners();
    try {
      if (entry['installed'] == true) {
        await repository.uninstallExtension(id);
      } else {
        await _install(entry);
      }
      await loadExtensions();
      await refresh();
    } catch (failure) {
      catalogError = failure.toString();
      notifyListeners();
    } finally {
      catalogBusy.remove(id);
      notifyListeners();
    }
  }

  /// 安装或更新：优先用随包脚本（离线可用），远端条目回落到带摘要的下载。
  Future<void> _install(Map<String, dynamic> entry) async {
    final id = entry['id'] as String;
    String? code;
    try {
      code = await rootBundle.loadString('extensions-repo/extensions/$id.js');
    } catch (_) {
      code = null;
    }
    if (code != null) {
      await repository.installExtension(id, code: code);
      return;
    }
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty) throw AppFailure('该规则没有可用的下载地址');
    await repository.installExtension(
      id,
      url: url,
      sha256: entry['sha256'] as String?,
    );
  }

  Future<void> refresh() async {
    if (polling) return;
    polling = true;
    try {
      final targets = store.sources;
      await Future.wait([
        for (final source in targets)
          (() async {
            final revision = revisions[source.id] ?? 0;
            try {
              final status = await repository.sourceStatus(source.id);
              if (revision != (revisions[source.id] ?? 0)) return;
              statuses[source.id] = status;
              errors.remove(source.id);
              notifyListeners();
            } catch (failure) {
              if (revision == (revisions[source.id] ?? 0)) {
                errors[source.id] = failure.toString();
                notifyListeners();
              }
            }
          })(),
      ]);
    } finally {
      polling = false;
    }
  }

  Future<void> run(SourceSite source, String operation) async {
    if (pending.contains(source.id)) return;
    pending.add(source.id);
    errors.remove(source.id);
    revisions[source.id] = (revisions[source.id] ?? 0) + 1;
    notifyListeners();
    try {
      final status = operation == 'cancel'
          ? await repository.cancelSourceJob(source.id)
          : await repository.startSourceJob(
              source.id,
              operation,
              drama: source.id == drama?.source ? drama : null,
            );
      statuses[source.id] = status;
      notifyListeners();
    } catch (error) {
      errors[source.id] = error.toString();
      notifyListeners();
    } finally {
      pending.remove(source.id);
      notifyListeners();
    }
  }

  /// 加载某源的设置项；只对已安装的扩展源有意义。
  Future<void> loadSettings(String source) async {
    if (settingsBusy.contains(source)) return;
    settingsBusy.add(source);
    notifyListeners();
    try {
      settings[source] = await repository.sourceSettings(source);
    } catch (failure) {
      errors[source] = failure.toString();
    } finally {
      settingsBusy.remove(source);
      notifyListeners();
    }
  }

  /// 写入单项设置；成功后重新读取，保证界面与落盘一致。
  Future<bool> saveSetting(String source, String key, String value) async {
    if (settingsBusy.contains(source)) return false;
    settingsBusy.add(source);
    errors.remove(source);
    notifyListeners();
    try {
      await repository.saveSourceSetting(source, key, value);
      await loadSettings(source);
      return true;
    } catch (failure) {
      errors[source] = failure.toString();
      return false;
    } finally {
      settingsBusy.remove(source);
      notifyListeners();
    }
  }

  Future<void> updateAll(List<SourceSite> sources) async {
    if (updatingAll || sources.isEmpty) return;
    updatingAll = true;
    notifyListeners();
    for (final source in sources) {
      await run(source, 'update');
    }
    updatingAll = false;
    notifyListeners();
  }

  Future<void> toggle(SourceSite source, bool enabled) async {
    errors.remove(source.id);
    notifyListeners();
    try {
      await store.setSourceEnabled(source.id, enabled);
      if (enabled) unawaited(refresh());
    } catch (error) {
      errors[source.id] = error.toString();
      notifyListeners();
    }
  }

  Future<void> uninstall(List<SourceSite> sources) async {
    if (_uninstalling || sources.isEmpty) return;
    _uninstalling = true;
    deleting = true;
    notifyListeners();
    for (final source in sources) {
      try {
        await repository.uninstallExtension(source.id);
      } catch (error) {
        errors[source.id] = error.toString();
      }
    }
    await loadExtensions();
    deleting = false;
    _uninstalling = false;
    notifyListeners();
  }

  void setDeleting(bool value) {
    if (deleting == value) return;
    deleting = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
