import 'dart:convert';
import 'dart:io';

import 'package:drama_app/data/services/cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// W2 缓存与弱网韧性：`FileCacheStore` 纯 Dart 单测（离线、无网络）。
///
/// 存储文件与时钟均可注入，保证 TTL / 淘汰 / 持久化断言确定性。
void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('cache_store_test');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  File file(String name) => File('${directory.path}/$name');

  group('TTL 与同步读', () {
    test('新鲜命中、过期未命中、忽略 ttl 仍可兜底', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000);
      final store = FileCacheStore(file: file('ttl.json'), clock: () => now);
      await store.load();
      await store.write('k', <String, Object?>{'v': 1});

      expect(store.read<Object?>('k'), isNotNull);
      expect(
        store.read<Object?>('k', ttl: const Duration(seconds: 1)),
        isNotNull,
      );
      expect(await store.isFresh('k', const Duration(seconds: 1)), isTrue);

      // 过期：年龄超过 ttl。
      now = DateTime.fromMillisecondsSinceEpoch(1000 + 1001);
      expect(store.read<Object?>('k', ttl: const Duration(seconds: 1)), isNull);
      expect(await store.isFresh('k', const Duration(seconds: 1)), isFalse);
      // 不传 ttl → 忽略时效仍可读（供弱网回退）。
      expect(store.read<Object?>('k'), isNotNull);
      await store.clear();
    });

    test('catalogDepth 读回分页水位，超 24h 失效', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000);
      final store = FileCacheStore(file: file('depth.json'), clock: () => now);
      await store.load();
      await store.write(CacheKeys.catalogDepth('hot'), 3);
      expect(store.catalogDepth('hot'), 3);
      expect(store.catalogDepth('unknown'), isNull);

      now = DateTime.fromMillisecondsSinceEpoch(
        1000 + CacheTtl.fallback.inMilliseconds + 1,
      );
      expect(store.catalogDepth('hot'), isNull);
      await store.clear();
    });

    test('remove 后不再命中，clear 清空', () async {
      final store = FileCacheStore(file: file('remove.json'));
      await store.load();
      await store.write('a', 1);
      await store.write('b', 2);
      await store.remove('a');
      await store.flush();

      expect(store.read<Object?>('a', ttl: CacheTtl.fallback), isNull);
      expect(store.read<Object?>('b', ttl: CacheTtl.fallback), isNotNull);
      await store.clear();
      expect(store.read<Object?>('b', ttl: CacheTtl.fallback), isNull);
    });
  });

  group('容量淘汰', () {
    test('超过 maxEntries 淘汰最旧', () async {
      var tick = 0;
      final store = FileCacheStore(
        file: file('entries.json'),
        maxEntries: 3,
        clock: () => DateTime.fromMillisecondsSinceEpoch(tick += 1),
      );
      await store.load();
      await store.write('a', 1);
      await store.write('b', 2);
      await store.write('c', 3);
      await store.write('d', 4); // 超上限，淘汰最旧 'a'

      expect(store.read<Object?>('a', ttl: CacheTtl.fallback), isNull);
      expect(store.read<Object?>('b', ttl: CacheTtl.fallback), isNotNull);
      expect(store.read<Object?>('d', ttl: CacheTtl.fallback), isNotNull);
      await store.clear();
    });
  });

  group('崩溃安全', () {
    test('损坏文件被丢弃并从空缓存继续（不抛错）', () async {
      final target = file('catalog_cache.json'); // 默认文件名
      await target.writeAsString('{ 这不是合法 JSON');

      final store = FileCacheStore(file: target);
      await store.load(); // 不应抛异常

      expect(store.read<Object?>('x'), isNull);
      expect(await target.exists(), isFalse); // 丢弃损坏文件
    });

    test('原子写：flush 后内容合法、临时文件不残留、重载可恢复', () async {
      final target = file('atomic.json');
      final store = FileCacheStore(file: target);
      await store.load();
      await store.write('k', <String, Object?>{'a': 1});
      await store.flush();

      final decoded =
          jsonDecode(await target.readAsString()) as Map<String, Object?>;
      expect(decoded['k'], isNotNull);
      expect(await File('${target.path}.tmp').exists(), isFalse);

      final reopened = FileCacheStore(file: target);
      await reopened.load();
      expect(reopened.read<Object?>('k', ttl: CacheTtl.fallback), isNotNull);
    });
  });
}
