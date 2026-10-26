import 'package:duanju_app/core/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> create([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(Map.of(initial));
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  test('restricted sources start switched off', () async {
    final store = await create();
    expect(store.sources.map((site) => site.id), [
      'hongguo',
      'hanxiaoquan',
      'guipian',
      'sorani',
    ]);
    expect(store.sourceEnabled('hongguo'), isTrue);
    expect(store.sourceEnabled('huangdou'), isFalse);
    expect(store.allowsSource('huangdou'), isFalse);
  });

  test('switches persist across restarts', () async {
    final store = await create();
    await store.setSourceEnabled('hongguo', false);
    expect(store.allowsSource('hongguo'), isFalse);
    await store.setSourceEnabled('huangdou', true);
    expect(store.allowsSource('huangdou'), isTrue);
    final restarted = testStore(store.preferences);
    addTearDown(restarted.dispose);
    expect(restarted.sourceEnabled('hongguo'), isFalse);
    expect(restarted.allowsSource('huangdou'), isTrue);
  });

  test('a damaged switch record falls back to defaults', () async {
    final store = await create({'sourceSwitches': 'not json'});
    expect(store.configurationError, isNull);
    expect(store.sourceEnabled('hongguo'), isTrue);
    expect(store.sourceEnabled('huangdou'), isFalse);
  });
}
