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
  HongguoCatalogRepository(this._core);

  final RustCore _core;

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

  /// 发一次请求并解包信封；`ok=false` 时抛 [RustCoreException]（含错误码/可重试）。
  ///
  /// 读类 op（`catalog`/`recommend`/`ranking`/`search`/`suggest`/`detail`）经
  /// [RustCore.call] 自动携带 App 级 `session` 与单调递增 `sequence`，Rust 侧据此仲裁
  /// （同 session 新请求取消旧在途、旧 sequence 的迟到响应丢弃为 `CANCELED`）。
  Future<Map<String, Object?>> _call(
    String op, {
    Map<String, Object?>? params,
  }) async {
    final envelope = await _core.call(op, source: _source, params: params);
    if (envelope['ok'] == true) {
      final data = envelope['data'];
      if (data is Map) return Map<String, Object?>.from(data);
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
