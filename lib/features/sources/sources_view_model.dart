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
  List<Map<String, dynamic>> catalog = const [];
  String? catalogError;
  bool polling = false;
  bool updatingAll = false;
  bool deleting = false;
  bool _uninstalling = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> loadExtensions() async {
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
    try {
      final raw = await rootBundle.loadString('extensions-repo/index.json');
      final entries = [
        for (final row in jsonDecode(raw) as List)
          if (row is Map)
            {
              ...Map<String, dynamic>.from(row),
              'bundled': true,
              'installed': installedRows.containsKey(row['id']),
            },
      ];
      installed
        ..clear()
        ..addAll(installedRows);
      catalog = entries;
      catalogError = error;
      notifyListeners();
    } catch (failure) {
      installed
        ..clear()
        ..addAll(installedRows);
      catalog = [
        for (final entry in installedRows.values)
          {...entry, 'bundled': true, 'installed': true},
      ];
      catalogError = error ?? failure.toString();
      notifyListeners();
    }
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
        final code = await rootBundle.loadString(
          'extensions-repo/extensions/$id.js',
        );
        await repository.installExtension(id, code: code);
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
