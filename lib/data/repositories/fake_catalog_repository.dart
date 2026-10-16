import '../../domain/models/drama.dart';
import '../../domain/models/drama_category.dart';
import '../../domain/models/episode.dart';
import 'catalog_repository.dart';

/// 本地 mock 仓库：**离线/核心不可用时的回退**，也是 widget 测试的默认数据源。
///
/// 与真实现同签名（全部 `Future`），因此上层无感知。
class FakeCatalogRepository implements CatalogRepository {
  FakeCatalogRepository();

  static const int _pageSize = 12;

  /// 免费/可试看集上限（对齐 实测口径）。
  static const int freeEpisodeCount = 10;

  static const List<DramaCategory> _categories = HongguoCategories.all;

  static const List<String> _titles = <String>[
    '总裁的隐婚妻子',
    '重生之豪门千金',
    '闪婚老公竟是首富',
    '天才医妃',
    '都市战神归来',
    '我在古代当团宠',
    '穿书后我成了反派',
    '深夜诊所',
    '迷雾档案',
    '一纸婚约',
    '王牌赘婿',
    '千金归来复仇记',
    '电竞少女的春天',
    '八零年代小娇妻',
    '首富的替嫁新娘',
    '我的老婆是大佬',
    '龙王令',
    '天才宝宝之爹地别跑',
    '末世重生录',
    '魔尊的掌心宠',
    '罪案笔记',
    '甜蜜陷阱',
    '顾少的独宠',
    '傲世神医',
    '锦鲤娘子',
    '双面千金',
    '和离后前夫后悔了',
    '山村神医',
    '都市逍遥客',
    '王牌女特工',
    '奶爸的修仙日常',
    '真假千金',
    '霸总的合约情人',
    '纨绔世子妃',
    '重生八零女神医',
    '深夜食堂老板娘',
  ];

  late final List<Drama> _all = _buildAll();

  List<Drama> _buildAll() {
    // 排除「推荐」——它是聚合分类，不是真实题材。
    final realCategories = _categories.skip(1).toList(growable: false);
    return <Drama>[
      for (var i = 0; i < _titles.length; i++)
        _buildDrama(
          index: i,
          category: realCategories[i % realCategories.length],
        ),
    ];
  }

  Drama _buildDrama({required int index, required DramaCategory category}) {
    final episodeCount = 60 + (index * 7) % 61;
    return Drama(
      id: 'd${(index + 1).toString().padLeft(3, '0')}',
      title: _titles[index],
      categoryId: category.id,
      categoryName: category.name,
      episodeCount: episodeCount,
      summary:
          '${_titles[index]}：${category.name}题材短剧，共 $episodeCount 集。'
          '本条目为本地 mock 数据（Rust 核心不可用时的回退），'
          '用于离线与 widget 测试；联网时由红果免签轨①供给真实目录。',
      tags: <String>[category.name, index.isEven ? '高甜' : '反转', '一口气看完'],
      status: index % 3 == 0 ? DramaStatus.ongoing : DramaStatus.finished,
      vip: index % 5 == 0,
    );
  }

  @override
  Future<List<DramaCategory>> categories() async => _categories;

  @override
  Future<CatalogPage> catalog({
    required String categoryId,
    int page = 0,
  }) async {
    final base = categoryId == 'recommend'
        ? _all
        : _all.where((drama) => drama.categoryId == categoryId).toList();
    final start = page * _pageSize;
    if (start >= base.length) {
      return const CatalogPage(items: <Drama>[], hasMore: false);
    }
    final end = (start + _pageSize).clamp(0, base.length);
    return CatalogPage(
      items: base.sublist(start, end),
      hasMore: end < base.length,
    );
  }

  @override
  Future<List<CatalogPage>> catalogPages({
    required String categoryId,
    int depth = 0,
  }) async {
    // mock 无水位概念：`depth` 为 0 时按单页处理。
    if (depth <= 0) return <CatalogPage>[await catalog(categoryId: categoryId)];
    // mock 数据无网络，逐页取即可（真实实现由 Rust 一次往返聚合）。
    final pages = <CatalogPage>[];
    for (var page = 0; page < depth; page++) {
      pages.add(await catalog(categoryId: categoryId, page: page));
    }
    return pages;
  }

  @override
  Future<List<Drama>> ranking({required String boardId}) async {
    final base = switch (boardId) {
      'rising' => _all.reversed.toList(),
      'finished' =>
        _all.where((drama) => drama.status == DramaStatus.finished).toList(),
      _ => List<Drama>.of(_all),
    };
    return base.take(20).toList(growable: false);
  }

  @override
  Future<List<Drama>> recommendations() async =>
      _all.take(10).toList(growable: false);

  @override
  Future<List<Drama>> search(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const <Drama>[];
    return _all
        .where((drama) => drama.title.contains(keyword))
        .toList(growable: false);
  }

  @override
  Future<List<String>> suggest(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const <String>[];
    return _all
        .where((drama) => drama.title.contains(keyword))
        .map((drama) => drama.title)
        .take(8)
        .toList(growable: false);
  }

  @override
  Future<DramaDetail> detail(String seriesId) async {
    final drama = _all.where((item) => item.id == seriesId).firstOrNull;
    if (drama == null) {
      throw StateError('未找到剧集 $seriesId');
    }
    return DramaDetail(drama: drama, episodes: _episodesOf(drama));
  }

  @override
  Future<EpisodeGroups> episodeGroups({
    required String seriesId,
    int groupSize = 0,
  }) async {
    // mock 也走同一口径：组大小默认 50（与 Rust `EPISODE_GROUP_SIZE` 一致），
    // 分组在这里算，调用方不必区分真源/mock。
    final size = groupSize <= 0 ? 50 : groupSize;
    final drama = _all.where((item) => item.id == seriesId).firstOrNull;
    if (drama == null) {
      return EpisodeGroups(groupSize: size, total: 0, groups: const <EpisodeGroup>[]);
    }
    final episodes = _episodesOf(drama);
    final groups = <EpisodeGroup>[];
    for (var i = 0; i < episodes.length; i += size) {
      final end = (i + size).clamp(0, episodes.length);
      final chunk = episodes.sublist(i, end);
      groups.add(
        EpisodeGroup(
          index: groups.length,
          start: i + 1,
          end: end,
          label: '${i + 1}-$end',
          episodes: chunk,
        ),
      );
    }
    return EpisodeGroups(groupSize: size, total: episodes.length, groups: groups);
  }

  List<Episode> _episodesOf(Drama drama) => <Episode>[
    for (var no = 1; no <= drama.episodeCount; no++)
      Episode(
        index: no,
        title: '第 $no 集',
        vid: 'mock-$no',
        duration: const Duration(minutes: 2, seconds: 24),
        locked: no > freeEpisodeCount,
      ),
  ];
}

extension<T> on Iterable<T> {
  /// `firstOrNull`（不引入 `package:collection` 只为这一个方法）。
  T? get firstOrNull => isEmpty ? null : first;
}
