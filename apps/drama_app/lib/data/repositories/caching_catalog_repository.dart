import '../../domain/models/drama.dart';
import '../../domain/models/drama_category.dart';
import '../../domain/models/episode.dart';
import '../services/cache_store.dart';
import '../services/rust_core.dart';
import 'catalog_repository.dart';

/// 目录仓库的**缓存与韧性**装饰器（实施计划 §4 W2 任务 5；W2 出口条件 2/3）。
///
/// 语义（不外泄给上层，UI 无感）：
/// - 每个可读方法先查**新鲜缓存**，命中直接返回、不发网络；
/// - 网络成功 → 写缓存并清除失败计数（旧榜熔断计数）；
/// - 网络失败 → 回退到「任意年龄」缓存（≤24h），命中则返回并置 stale 文案；
///   无缓存则**原样抛错**（错误可见，plan §8）；
/// - 榜单另加**每板独立熔断器**（18s 内 3 次失败）+ 24h 旧榜回退。
///
/// 并发安全：同一 key 的并发请求经 [_inFlight] 去重，只打一次网络。
class CachingCatalogRepository implements CatalogRepository {
  CachingCatalogRepository({
    required CatalogRepository inner,
    required CacheStore store,
    this.onStale,
  }) : _inner = inner,
       _store = store;

  /// 目录（含推荐/详情/搜索）的新鲜窗口，暴露给测试与诊断。
  static const Duration catalogTtl = CacheTtl.fresh;

  final CatalogRepository _inner;
  final CacheStore _store;

  /// 缓存兜底回调：`null` = 网络成功（清提示）；非 null = 当前用缓存兜底，值为提示文案。
  /// 由 provider 层接到 `staleDataNoticeProvider`（见 catalog_providers.dart）。
  final void Function(String? message)? onStale;

  /// 用缓存兜底时展示给用户的提示文案。
  static const String staleMessage = '当前显示的是缓存数据，网络恢复后会自动更新';

  /// in-flight 去重：同一 key 的并发请求复用同一个 Future。
  final Map<String, Future<Object?>> _inFlight = <String, Future<Object?>>{};

  /// 每个榜单板的独立熔断器（内存态，不持久化）。
  final Map<String, _BoardBreaker> _breakers = <String, _BoardBreaker>{};

  /// 分类为路由级常量数据，无网络 I/O，直接透传。
  @override
  Future<List<DramaCategory>> categories() => _inner.categories();

  @override
  Future<CatalogPage> catalog({required String categoryId, int page = 0}) =>
      _dedup(
        CacheKeys.catalog(categoryId, page),
        () => _catalogUncached(categoryId, page),
      );

  @override
  Future<List<Drama>> ranking({required String boardId}) =>
      _dedup(CacheKeys.ranking(boardId), () => _rankingUncached(boardId));

  @override
  Future<List<Drama>> recommendations() =>
      _dedup(CacheKeys.recommend, _recommendationsUncached);

  @override
  Future<List<Drama>> search(String query) {
    final keyword = query.trim();
    // 空关键词无意义（内层也返回空表），不落缓存。
    if (keyword.isEmpty) return _inner.search(query);
    return _dedup(CacheKeys.search(keyword), () => _searchUncached(query, keyword));
  }

  @override
  Future<List<String>> suggest(String query) {
    final keyword = query.trim();
    if (keyword.isEmpty) return _inner.suggest(query);
    return _dedup(
      CacheKeys.suggest(keyword),
      () => _suggestUncached(query, keyword),
    );
  }

  @override
  Future<DramaDetail> detail(String seriesId) =>
      _dedup(CacheKeys.detail(seriesId), () => _detailUncached(seriesId));

  /// 已缓存的分页层数（供「重启后目录分页续载不丢页」的恢复逻辑与测试使用）。
  Future<int> cachedPages(String categoryId) async =>
      _store.catalogDepth(categoryId) ?? 0;

  // ── 各 op 的缓存读写 ──────────────────────────────────────────────

  Future<CatalogPage> _catalogUncached(String categoryId, int page) async {
    final key = CacheKeys.catalog(categoryId, page);
    final fresh = _read(key, CacheTtl.fresh, _decodeCatalogPage);
    if (fresh != null) return fresh;
    try {
      final result = await _inner.catalog(categoryId: categoryId, page: page);
      await _store.write(key, _encodeCatalogPage(result));
      // 分页水位：catalog:<categoryId>:depth = max(已请求 page+1)。
      await _recordDepth(categoryId, page + 1);
      _notifyStale(null);
      return result;
    } catch (error) {
      final fallback = _read(key, CacheTtl.fallback, _decodeCatalogPage);
      if (fallback != null) {
        _notifyStale(staleMessage);
        return fallback;
      }
      rethrow;
    }
  }

  Future<List<Drama>> _recommendationsUncached() async {
    const key = CacheKeys.recommend;
    final fresh = _read(key, CacheTtl.fresh, _decodeDramas);
    if (fresh != null) return fresh;
    try {
      final items = await _inner.recommendations();
      await _store.write(key, _encodeDramas(items));
      _notifyStale(null);
      return items;
    } catch (error) {
      final fallback = _read(key, CacheTtl.fallback, _decodeDramas);
      if (fallback != null) {
        _notifyStale(staleMessage);
        return fallback;
      }
      rethrow;
    }
  }

  Future<List<Drama>> _searchUncached(String query, String keyword) async {
    final key = CacheKeys.search(keyword);
    final fresh = _read(key, CacheTtl.fresh, _decodeDramas);
    if (fresh != null) return fresh;
    try {
      final items = await _inner.search(query);
      await _store.write(key, _encodeDramas(items));
      _notifyStale(null);
      return items;
    } catch (error) {
      final fallback = _read(key, CacheTtl.fallback, _decodeDramas);
      if (fallback != null) {
        _notifyStale(staleMessage);
        return fallback;
      }
      rethrow;
    }
  }

  Future<List<String>> _suggestUncached(String query, String keyword) async {
    final key = CacheKeys.suggest(keyword);
    final fresh = _read(key, CacheTtl.fresh, _decodeStrings);
    if (fresh != null) return fresh;
    try {
      final items = await _inner.suggest(query);
      await _store.write(key, _encodeStrings(items));
      _notifyStale(null);
      return items;
    } catch (error) {
      final fallback = _read(key, CacheTtl.fallback, _decodeStrings);
      if (fallback != null) {
        _notifyStale(staleMessage);
        return fallback;
      }
      rethrow;
    }
  }

  Future<DramaDetail> _detailUncached(String seriesId) async {
    final key = CacheKeys.detail(seriesId);
    final fresh = _read(key, CacheTtl.fresh, _decodeDetail);
    if (fresh != null) return fresh;
    try {
      final detail = await _inner.detail(seriesId);
      await _store.write(key, _encodeDetail(detail));
      _notifyStale(null);
      return detail;
    } catch (error) {
      final fallback = _read(key, CacheTtl.fallback, _decodeDetail);
      if (fallback != null) {
        _notifyStale(staleMessage);
        return fallback;
      }
      rethrow;
    }
  }

  /// 榜单：新鲜窗口（5min）→ 熔断判定 → 网络 → 失败回退 24h 旧榜。
  Future<List<Drama>> _rankingUncached(String boardId) async {
    final key = CacheKeys.ranking(boardId);
    final fresh = _read(key, CacheTtl.rankingFresh, _decodeDramas);
    if (fresh != null) return fresh;

    final breaker = _breakers.putIfAbsent(boardId, _BoardBreaker.new);
    if (breaker.isOpen && !breaker.readyForTrial) {
      // 熔断打开且冷却中：直接返回 24h 内旧榜，不发网络。
      final stale = _read(key, CacheTtl.fallback, _decodeDramas);
      if (stale != null) {
        _notifyStale(staleMessage);
        return stale;
      }
      throw const RustCoreException(
        'CIRCUIT_OPEN',
        '榜单服务连续失败已暂时熔断，且无可用旧榜缓存',
        true,
      );
    }

    try {
      final items = await _inner.ranking(boardId: boardId);
      await _store.write(key, _encodeDramas(items));
      breaker.onSuccess();
      _notifyStale(null);
      return items;
    } catch (error) {
      breaker.onFailure();
      final stale = _read(key, CacheTtl.fallback, _decodeDramas);
      if (stale != null) {
        _notifyStale(staleMessage);
        return stale;
      }
      rethrow;
    }
  }

  // ── 工具 ─────────────────────────────────────────────────────────

  /// 读缓存并用 [decoder] 解码；`maxAge` 为 null 表示忽略时效（弱网兜底）。
  T? _read<T>(String key, Duration? maxAge, T Function(Object? raw) decoder) {
    final raw = maxAge == null
        ? _store.read<Object?>(key)
        : _store.read<Object?>(key, ttl: maxAge);
    if (raw == null) return null;
    try {
      return decoder(raw);
    } catch (_) {
      // 条目形状不匹配（例如降级过的旧格式）→ 视为未命中，不打断调用方。
      return null;
    }
  }

  /// 同一 key 并发去重：已在进行中的请求直接复用。
  Future<T> _dedup<T>(String key, Future<T> Function() fetch) {
    final existing = _inFlight[key];
    if (existing != null) return existing.then((value) => value as T);
    final future = fetch();
    _inFlight[key] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
  }

  Future<void> _recordDepth(String categoryId, int depth) async {
    final previous = _store.catalogDepth(categoryId) ?? 0;
    if (depth > previous) {
      await _store.write(CacheKeys.catalogDepth(categoryId), depth);
    }
  }

  void _notifyStale(String? message) {
    onStale?.call(message);
  }
}

/// 单榜单板的熔断器：18s 内累计 3 次失败 → 打开；冷却 60s 后放行一次试探。
class _BoardBreaker {
  static const Duration _window = Duration(seconds: 18);
  static const int _threshold = 3;
  static const Duration _cooldown = Duration(seconds: 60);

  final List<int> _failuresMs = <int>[];
  int? _openedAtMs;

  bool get isOpen => _openedAtMs != null;

  /// 冷却结束 → 允许一次试探（半开）。
  bool get readyForTrial {
    final opened = _openedAtMs;
    if (opened == null) return false;
    return DateTime.now().millisecondsSinceEpoch - opened >=
        _cooldown.inMilliseconds;
  }

  void onSuccess() {
    _failuresMs.clear();
    _openedAtMs = null;
  }

  void onFailure() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _failuresMs.removeWhere((t) => now - t > _window.inMilliseconds);
    _failuresMs.add(now);
    if (_openedAtMs != null || _failuresMs.length >= _threshold) {
      // 打开或续期熔断（重新开始 60s 冷却）。
      _openedAtMs = now;
    }
  }
}

// ── 序列化（缓存只存域模型，不存带时效 URL）──────────────────────────────
// 列表统一编码为 `{items: [...]}`，与 Dart 侧解码、诊断脚本口径一致。

Map<String, Object?> _encodeDrama(Drama drama) => <String, Object?>{
  'id': drama.id,
  'title': drama.title,
  'categoryId': drama.categoryId,
  'categoryName': drama.categoryName,
  'episodeCount': drama.episodeCount,
  'summary': drama.summary,
  'tags': drama.tags,
  'status': drama.status.name,
  'vip': drama.vip,
};

Map<String, Object?> _encodeDramas(List<Drama> dramas) => <String, Object?>{
  'items': <Object?>[for (final drama in dramas) _encodeDrama(drama)],
};

Drama _decodeDrama(Object? raw) {
  final json = raw is Map ? Map<String, Object?>.from(raw) : <String, Object?>{};
  return Drama(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    categoryId: json['categoryId'] as String? ?? '',
    categoryName: json['categoryName'] as String? ?? '',
    episodeCount: (json['episodeCount'] as num?)?.toInt() ?? 0,
    summary: json['summary'] as String? ?? '',
    tags: <String>[
      for (final tag in (json['tags'] as List? ?? const <Object?>[]))
        if (tag is String && tag.isNotEmpty) tag,
    ],
    status: json['status'] == 'ongoing'
        ? DramaStatus.ongoing
        : DramaStatus.finished,
    vip: json['vip'] == true,
  );
}

List<Drama> _decodeDramas(Object? raw) {
  final items = switch (raw) {
    Map map => map['items'],
    List list => list,
    _ => null,
  };
  if (items is! List) return const <Drama>[];
  return <Drama>[
    for (final item in items)
      if (item is Map) _decodeDrama(item),
  ];
}

Map<String, Object?> _encodeCatalogPage(CatalogPage page) => <String, Object?>{
  'items': <Object?>[for (final drama in page.items) _encodeDrama(drama)],
  'hasMore': page.hasMore,
};

CatalogPage _decodeCatalogPage(Object? raw) {
  final json = raw is Map ? Map<String, Object?>.from(raw) : <String, Object?>{};
  return CatalogPage(
    items: _decodeDramas(json),
    hasMore: json['hasMore'] == true,
  );
}

Map<String, Object?> _encodeEpisode(Episode episode) => <String, Object?>{
  'index': episode.index,
  'title': episode.title,
  'vid': episode.vid,
  'durationMs': episode.duration?.inMilliseconds,
  'locked': episode.locked,
};

Episode _decodeEpisode(Object? raw) {
  final json = raw is Map ? Map<String, Object?>.from(raw) : <String, Object?>{};
  final index = (json['index'] as num?)?.toInt() ?? 0;
  final ms = (json['durationMs'] as num?)?.toInt();
  return Episode(
    index: index,
    title: json['title'] as String? ?? '第 $index 集',
    vid: json['vid'] as String?,
    duration: ms == null ? null : Duration(milliseconds: ms),
    locked: json['locked'] == true,
  );
}

List<Episode> _decodeEpisodes(Object? raw) {
  if (raw is! List) return const <Episode>[];
  return <Episode>[
    for (final item in raw)
      if (item is Map) _decodeEpisode(item),
  ];
}

Map<String, Object?> _encodeDetail(DramaDetail detail) => <String, Object?>{
  'drama': _encodeDrama(detail.drama),
  'episodes': <Object?>[
    for (final episode in detail.episodes) _encodeEpisode(episode),
  ],
};

DramaDetail _decodeDetail(Object? raw) {
  final json = raw is Map ? Map<String, Object?>.from(raw) : <String, Object?>{};
  return DramaDetail(
    drama: _decodeDrama(json['drama']),
    episodes: _decodeEpisodes(json['episodes']),
  );
}

Map<String, Object?> _encodeStrings(List<String> values) => <String, Object?>{
  'items': <Object?>[...values],
};

List<String> _decodeStrings(Object? raw) {
  final items = switch (raw) {
    Map map => map['items'],
    List list => list,
    _ => null,
  };
  if (items is! List) return const <String>[];
  return <String>[
    for (final item in items)
      if (item is String && item.isNotEmpty) item,
  ];
}
