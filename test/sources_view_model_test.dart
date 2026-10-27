import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/source_status.dart';
import 'package:duanju_app/features/sources/sources_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _SourcesRepository extends FixtureRepository {
  final installedRows = <Map<String, dynamic>>[];
  final started = <String>[];
  final uninstalled = <String>[];
  bool failStatus = false;

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<Map<String, dynamic>>> installedExtensions() async =>
      installedRows;

  @override
  Future<SourceStatus> sourceStatus(String source) async {
    if (failStatus) throw AppFailure('状态读取失败');
    return SourceStatus.fromJson({'source': source, 'count': 2});
  }

  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async {
    started.add('$source:$operation');
    return SourceStatus.fromJson({'source': source, 'count': 1});
  }

  @override
  Future<void> uninstallExtension(String source) async {
    uninstalled.add(source);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SourcesViewModel> build(
    _SourcesRepository repository, {
    Future<void> Function()? beforeReturn,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final model = SourcesViewModel(repository: repository, store: store);
    addTearDown(model.dispose);
    await beforeReturn?.call();
    return model;
  }

  test('loadExtensions exposes installed rules and bundled catalog', () async {
    final repository = _SourcesRepository()
      ..installedRows.add({'id': 'dsd', 'version': '1.0.0'});
    final model = await build(repository);

    await model.loadExtensions();

    expect(model.installed['dsd']?['version'], '1.0.0');
    expect(model.catalog, isNotEmpty);
    expect(
      model.catalog.any((entry) => entry['id'] == 'dsd' && entry['installed']),
      isTrue,
    );
  });

  test('refresh loads status for every enabled source', () async {
    final model = await build(_SourcesRepository());

    await model.refresh();

    expect(model.statuses, isNotEmpty);
    expect(model.errors, isEmpty);
    expect(model.polling, isFalse);
  });

  test('refresh records per-source failures', () async {
    final model = await build(_SourcesRepository()..failStatus = true);

    await model.refresh();

    expect(model.statuses, isEmpty);
    expect(model.errors, isNotEmpty);
    expect(model.errors.values.first, contains('状态读取失败'));
  });

  test('run starts a job and clears pending state', () async {
    final repository = _SourcesRepository();
    final model = await build(repository);
    await model.refresh();
    final source = SourceSite.knownValues.first;

    await model.run(source, 'update');

    expect(repository.started, contains('${source.id}:update'));
    expect(model.pending, isEmpty);
    expect(model.statuses[source.id], isNotNull);
  });

  test('uninstall delegates to repository and resets deleting flag', () async {
    final repository = _SourcesRepository();
    final model = await build(repository);
    model.setDeleting(true);

    await model.uninstall([SourceSite.knownValues.first]);

    expect(repository.uninstalled, contains(SourceSite.knownValues.first.id));
    expect(model.deleting, isFalse);
  });

  test('toggle persists the enabled switch', () async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final model = SourcesViewModel(
      repository: _SourcesRepository(),
      store: store,
    );
    addTearDown(model.dispose);
    final source = store.sources.first;

    await model.toggle(source, false);

    expect(store.sourceEnabled(source.id), isFalse);
  });
}
