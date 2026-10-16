import '../../domain/models/drama.dart';
import '../../domain/models/drama_category.dart';
import '../../domain/models/episode.dart';
import '../services/rust_core.dart';
import 'catalog_repository.dart';

/// 红果免签轨① 的真实仓库：所有数据经 `RustCore` 的窄 ABI 取得。
///
/// op 契约见 `rust/core/src/lib.rs`：
/// - `catalog` params `{category, page}` → `{items:[Drama], hasMore, page}`
/// - `recommend`                        → `{items:[Drama]}`
/// - `ranking` params `{board}`          → `{items:[Drama]}`
/// - `search` params `{keyword}`         → `{items:[Drama], total}`
/// - `suggest` params `{keyword}`        → `{items:[string]}`
/// - `detail` params `{id}`              → `{drama:Drama, episodes:[Episode]}`
class HongguoCatalogRepository implements CatalogRepository {
  HongguoCatalogRepository(this._core, {this.onStale});

  final RustCore _core;

  /// 缓存兜底回调：`false` = 本次数据来自网络；`true` = 用旧值兜底
  /// （网络失败或榜单熔断中）。
  ///
  /// 缓存策略（TTL / 回退 / 熔断 / 并发去重 / 分页水位）**全部在 Rust**
  /// （`rust/core/src/cache.rs`），Dart 不持有任何缓存逻辑：Rust 在响应
  /// `data.stale` 里告知本次是否为兜底，这里只把它转成 UI 可见的提示。
  final void Function(bool stale)? onStale;

  static const String _source = 'hongguo';

  @override
  Future<List<DramaCategory>> categories() async => HongguoCategories.all;

  @override
  Future<CatalogPage> catalog({
    required String categoryId,
    int page = 0,
  }) async {
    // "推荐"走 recommend op（首页推荐位），其余内容类型走 catalog。
    if (categoryId == 'recommend') {
      final data = await _call('recommend');
      return CatalogPage(items: _dramas(data['items']), hasMore: false);
    }
    final data = await _call(
      'catalog',
      params: <String, Object?>{'category': categoryId, 'page': page},
    );
    return CatalogPage(
      items: _dramas(data['items']),
      hasMore: data['hasMore'] == true,
    );
  }

  @override
  Future<List<CatalogPage>> catalogPages({
    required String categoryId,
    int depth = 0,
  }) async {
    final data = await _call(
      'catalogPages',
      params: <String, Object?>{
        'category': categoryId,
        // 0 = 让 Rust 按自己的分页水位决定取几页。
        if (depth > 0) 'depth': depth,
      },
    );
    final pages = data['pages'];
    if (pages is! List) return const <CatalogPage>[];
    return <CatalogPage>[
      for (final page in pages)
        if (page is Map)
          CatalogPage(
            items: _dramas(page['items']),
            hasMore: page['hasMore'] == true,
          ),
    ];
  }

  @override
  Future<List<Drama>> ranking({required String boardId}) async {
    final data = await _call(
      'ranking',
      params: <String, Object?>{'board': boardId},
    );
    return _dramas(data['items']);
  }

  @override
  Future<List<Drama>> recommendations() async {
    final data = await _call('recommend');
    return _dramas(data['items']);
  }

  @override
  Future<List<Drama>> search(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const <Drama>[];
    final data = await _call(
      'search',
      params: <String, Object?>{'keyword': keyword},
    );
    return _dramas(data['items']);
  }

  @override
  Future<List<String>> suggest(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const <String>[];
    final data = await _call(
      'suggest',
      params: <String, Object?>{'keyword': keyword},
    );
    final items = data['items'];
    if (items is! List) return const <String>[];
    return <String>[
      for (final item in items)
        if (item is String && item.isNotEmpty) item,
    ];
  }

  @override
  Future<DramaDetail> detail(String seriesId) async {
    final data = await _call(
      'detail',
      params: <String, Object?>{'id': seriesId},
    );
    final dramaJson = data['drama'];
    if (dramaJson is! Map) {
      throw const RustCoreException('PARSE', 'detail 缺少 drama 字段', false);
    }
    return DramaDetail(
      drama: _drama(Map<String, Object?>.from(dramaJson)),
      episodes: _episodes(data['episodes']),
    );
  }

  @override
  Future<EpisodeGroups> episodeGroups({
    required String seriesId,
    int groupSize = 0,
  }) async {
    final data = await _call(
      'episodeGroups',
      params: <String, Object?>{
        'id': seriesId,
        // 0 = 用 Rust 侧默认组大小（与详情页口径统一）。
        if (groupSize > 0) 'groupSize': groupSize,
      },
    );
    return EpisodeGroups.fromJson(data);
  }

  /// 发一次请求并解包信封；`ok=false` 时抛 [RustCoreException]（含错误码/可重试）。
  ///
  /// 读类 op（`catalog`/`recommend`/`ranking`/`search`/`suggest`/`detail`）经
  /// [RustCore.call] 自动携带 App 级 `session` 与单调递增 `sequence`，Rust 侧据此仲裁
  /// （同 session 新请求取消旧在途、旧 sequence 的迟到响应丢弃为 `CANCELED`）。
  ///
  /// Rust 侧命中缓存时同样返回 `ok=true`，并用 `data.stale` 区分
  /// 「新鲜数据」与「网络失败后的兜底旧值」。
  Future<Map<String, Object?>> _call(
    String op, {
    Map<String, Object?>? params,
  }) async {
    final envelope = await _core.call(op, source: _source, params: params);
    if (envelope['ok'] == true) {
      final data = envelope['data'];
      if (data is Map) {
        final map = Map<String, Object?>.from(data);
        onStale?.call(map['stale'] == true);
        return map;
      }
      onStale?.call(false);
      return <String, Object?>{};
    }
    throw RustCoreException.fromEnvelope(envelope);
  }

  List<Drama> _dramas(Object? raw) {
    if (raw is! List) return const <Drama>[];
    return <Drama>[
      for (final item in raw)
        if (item is Map) _drama(Map<String, Object?>.from(item)),
    ];
  }

  List<Episode> _episodes(Object? raw) {
    if (raw is! List) return const <Episode>[];
    return <Episode>[
      for (final item in raw)
        if (item is Map) _episode(Map<String, Object?>.from(item)),
    ];
  }

  Drama _drama(Map<String, Object?> json) => Drama(
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
    // 封面已是**本次会话**的代理地址：Rust 侧在缓存读出时按当前端口生成
    // （见 rust/core/src/covers.rs 的 rewrite_to_current_port 与 cache.rs 的
    // 规范形式存储），因此这里原样使用，不做任何 URI 解析改写——
    // 海报墙滚动时每条都解析一次 URI 的开销就此消失。
    cover: json['cover'] as String? ?? '',
  );

  Episode _episode(Map<String, Object?> json) {
    final seconds = (json['durationSeconds'] as num?)?.toDouble();
    final index = (json['index'] as num?)?.toInt() ?? 0;
    return Episode(
      index: index,
      title: json['title'] as String? ?? '第 $index 集',
      vid: json['vid'] as String?,
      duration: seconds == null
          ? null
          : Duration(milliseconds: (seconds * 1000).round()),
      locked: json['locked'] == true,
    );
  }
}
