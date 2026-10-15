import 'dart:io';

import 'package:drama_app/data/repositories/caching_catalog_repository.dart';
import 'package:drama_app/data/repositories/catalog_repository.dart';
import 'package:drama_app/data/services/cache_store.dart';
import 'package:drama_app/domain/models/drama.dart';
import 'package:drama_app/domain/models/drama_category.dart';
import 'package:drama_app/domain/models/episode.dart';
import 'package:flutter_test/flutter_test.dart';

/// W2 缓存与弱网韧性：`CachingCatalogRepository` 单测。
///
/// 用「会抛错的 fake inner」驱动弱网回退 / 榜单熔断；用可注入文件与时钟的
/// [FileCacheStore] 驱动 TTL 与重启续载。离线、无网络。
void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('caching_repo_test');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  File cacheFile(String name) => File('${directory.path}/$name');

  test('(i) 有缓存时断网 → 返回缓存并把 stale 提示置位', () async {
    var now = DateTime.fromMillisecondsSinceEpoch(0);
    final store = FileCacheStore(file: cacheFile('stale.json'), clock: () => now);
    await store.load();
    final inner = _FakeInner();
    String? stale;
    final repo = CachingCatalogRepository(
      inner: inner,
      store: store,
      onStale: (message) => stale = message,
    );

    final first = await repo.catalog(categoryId: 'hot', page: 0);
    expect(first.items, isNotEmpty);
    expect(stale, isNull); // 网络成功 → 清空提示
    expect(
      await store.isFresh(CacheKeys.catalog('hot', 0), CacheTtl.fallback),
      isTrue,
    );

    // 缓存过期 + 断网：回退到过期缓存，提示置位。
    now = DateTime.fromMillisecondsSinceEpoch(CacheTtl.fresh.inMilliseconds + 1);
    inner.fail = true;
    final page = await repo.catalog(categoryId: 'hot', page: 0);
    expect(page.items.length, first.items.length);
    expect(stale, isNotNull);
    expect(inner.catalogCalls, 2); // 确实尝试过网络
    await store.clear();
  });

  test('(ii) 完全无缓存时错误上抛', () async {
    final store = FileCacheStore(file: cacheFile('nocache.json'));
    await store.load();
    final repo = CachingCatalogRepository(
      inner: _FakeInner()..fail = true,
      store: store,
    );

    await expectLater(
      repo.catalog(categoryId: 'cold', page: 0),
      throwsA(isA<StateError>()),
    );
  });

  test('(iii) 榜单连续 3 次失败后熔断，不再请求网络', () async {
    var now = DateTime.fromMillisecondsSinceEpoch(0);
    final store = FileCacheStore(
      file: cacheFile('breaker.json'),
      clock: () => now,
    );
    await store.load();
    // 预置 24h 内旧榜（列表统一编码为 `{items: [...]}`）。
    await store.write(CacheKeys.ranking('hot'), <String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'id': 'd1',
          'title': 'T1',
          'categoryId': 'hot',
          'categoryName': 'H',
          'episodeCount': 3,
        },
      ],
    });
    final inner = _FakeInner();
    final repo = CachingCatalogRepository(inner: inner, store: store);

    // 超出 5min 新鲜窗口，但仍在 24h 回退窗口内。
    now = DateTime.fromMillisecondsSinceEpoch(
      CacheTtl.rankingFresh.inMilliseconds + 1,
    );
    inner.fail = true;

    for (var i = 0; i < 3; i++) {
      final result = await repo.ranking(boardId: 'hot');
      expect(result, isNotEmpty); // 网络失败 → 回退旧榜，不抛错
    }
    expect(inner.rankingCalls, 3); // 每次失败都尝试过网络

    // 第 4 次：熔断已打开且冷却中 → 直接返回旧榜，不再请求网络。
    final fallback = await repo.ranking(boardId: 'hot');
    expect(fallback.map((drama) => drama.id).toList(), <String>['d1']);
    expect(inner.rankingCalls, 3);
    await store.clear();
  });

  test('(iv) cachedPages 读回 meta，且重启后仍可恢复', () async {
    final target = cacheFile('meta.json');
    final store = FileCacheStore(file: target);
    await store.load();
    final repo = CachingCatalogRepository(inner: _FakeInner(), store: store);

    await repo.catalog(categoryId: 'hot', page: 0);
    await repo.catalog(categoryId: 'hot', page: 1);
    await repo.catalog(categoryId: 'hot', page: 2);
    expect(await repo.cachedPages('hot'), 3);
    expect(await repo.cachedPages('unknown'), 0);

    // 「重启」：落盘后新实例可读回水位。
    await store.flush();
    final reopened = FileCacheStore(file: target);
    await reopened.load();
    final reopenedRepo = CachingCatalogRepository(
      inner: _FakeInner(),
      store: reopened,
    );
    expect(await reopenedRepo.cachedPages('hot'), 3);
  });
}

/// 可切换失败的 fake inner：验证弱网回退与熔断。
class _FakeInner implements CatalogRepository {
  bool fail = false;
  int catalogCalls = 0;
  int rankingCalls = 0;

  @override
  Future<List<DramaCategory>> categories() async => const <DramaCategory>[];

  @override
  Future<CatalogPage> catalog({required String categoryId, int page = 0}) async {
    catalogCalls++;
    if (fail) throw StateError('offline');
    return CatalogPage(items: <Drama>[_drama(page)], hasMore: page < 2);
  }

  @override
  Future<List<Drama>> ranking({required String boardId}) async {
    rankingCalls++;
    if (fail) throw StateError('offline');
    return <Drama>[_drama(0)];
  }

  @override
  Future<List<Drama>> recommendations() async {
    if (fail) throw StateError('offline');
    return <Drama>[_drama(0)];
  }

  @override
  Future<List<Drama>> search(String query) async => const <Drama>[];

  @override
  Future<List<String>> suggest(String query) async => const <String>[];

  @override
  Future<DramaDetail> detail(String seriesId) async {
    if (fail) throw StateError('offline');
    return DramaDetail(drama: _drama(0), episodes: const <Episode>[]);
  }
}

Drama _drama(int n) => Drama(
  id: 'd$n',
  title: 'T$n',
  categoryId: 'hot',
  categoryName: 'H',
  episodeCount: 3,
);
