import '../../domain/models/drama.dart';
import '../../domain/models/drama_category.dart';
import '../../domain/models/episode.dart';

/// 目录数据仓库（ARCH §5）。
///
/// **W2 起本接口是异步的**：真数据来自 Rust 免签轨①（网络 I/O），mock 实现
/// （[FakeCatalogRepository]）也保持同签名，因此 UI/ViewModel 无需感知数据来源。
///
/// 能力契约：未声明能力必须**返回错误**而不是空列表冒充"查过了"
/// （SourceSpec §11.1；错误码见 `RustCoreException.code`）。
abstract interface class CatalogRepository {
  /// 首页分类（路由级常量；真实源=红果官网内容类型）。
  Future<List<DramaCategory>> categories();

  /// 分类分页（PRD F-01）。`page` 从 0 起。
  Future<CatalogPage> catalog({required String categoryId, int page});

  /// 榜单（PRD F-03）。`boardId` 见 [RankingBoards]。
  Future<List<Drama>> ranking({required String boardId});

  /// 推荐位（PRD F-03）。
  Future<List<Drama>> recommendations();

  /// 在线搜索（PRD F-02）。
  Future<List<Drama>> search(String query);

  /// 搜索联想（PRD F-02）。
  Future<List<String>> suggest(String query);

  /// 详情 + 选集（PRD F-04）——真源一次请求拿全（`detail` op）。
  Future<DramaDetail> detail(String seriesId);
}

/// 一页目录结果。
class CatalogPage {
  const CatalogPage({required this.items, required this.hasMore});

  final List<Drama> items;

  /// 是否还有下一页（PRD F-01 的"加载更多"兜底）。
  final bool hasMore;
}

/// 详情 + 选集。
class DramaDetail {
  const DramaDetail({required this.drama, required this.episodes});

  final Drama drama;
  final List<Episode> episodes;
}

/// 红果官网内容类型（真实源分类；route 即 URL 路径段）。
///
/// W2 起取代 W1 的 7 个 mock 题材分类——真实源的顶层分类是内容类型，
/// 题材筛选（都市/古装/…）由分类页的 `selectorList` 提供，属 W4 增强。
abstract final class HongguoCategories {
  static const List<DramaCategory> all = <DramaCategory>[
    DramaCategory(id: 'recommend', name: '推荐'),
    DramaCategory(id: 'real-drama', name: '真人短剧'),
    DramaCategory(id: 'comic-drama', name: '漫剧'),
    DramaCategory(id: 'ai-drama', name: 'AI 漫'),
    DramaCategory(id: 'comic', name: '漫画'),
  ];
}

/// 榜单板（PRD F-03）。真实源无独立榜单接口，映射到首页分栏（EVIDENCE §21.3）。
abstract final class RankingBoards {
  static const List<DramaCategory> all = <DramaCategory>[
    DramaCategory(id: 'hot', name: '热搜榜'),
    DramaCategory(id: 'rising', name: '飙升榜'),
    DramaCategory(id: 'finished', name: '完结榜'),
  ];
}
