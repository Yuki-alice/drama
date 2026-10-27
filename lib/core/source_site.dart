class SourceSite {
  const SourceSite(
    this.id,
    this.name,
    this.description, {
    this.restricted = false,
    this.group = '',
    this.groupName = '',
    this.entryName = '',
    this.onlineSearch = false,
    this.pagedSearch = false,
    this.suggestions = false,
  });

  final String id;
  final String name;
  final String description;
  final bool restricted;
  final String group;
  final String groupName;
  final String entryName;
  final bool onlineSearch;
  final bool pagedSearch;
  final bool suggestions;

  bool get searchSuggestions => id == 'hongguo' || suggestions;
  String get displayGroupId => group.isEmpty ? id : group;
  String get displayGroupName => groupName.isEmpty ? name : groupName;
  String get displayEntryName => entryName.isEmpty ? name : entryName;

  static const hongguo = SourceSite(
    'hongguo',
    '红果',
    '短剧 · 漫剧 · AI 剧',
    onlineSearch: true,
    suggestions: true,
  );
  static const dsd = SourceSite(
    'dsd',
    '帝果',
    '分类视频 · 在线搜索',
    restricted: true,
    onlineSearch: true,
    pagedSearch: true,
  );
  static const sorani = SourceSite(
    'sorani',
    '青空',
    '番剧 · 剧场动画 · 特摄',
    onlineSearch: true,
    pagedSearch: true,
  );
  static const guipian = SourceSite(
    'guipian',
    '鬼片',
    '鬼片 · 电视剧 · 动漫',
    onlineSearch: true,
    pagedSearch: true,
  );
  static const hanxiaoquan = SourceSite(
    'hanxiaoquan',
    '韩小圈',
    '韩剧 · 韩国电影 · 综艺动漫',
    onlineSearch: true,
    pagedSearch: true,
  );
  static const huangdou = SourceSite(
    'huangdou',
    '黄豆',
    '精选短剧',
    restricted: true,
  );
  static const huangju = SourceSite(
    'huangju',
    '剧果',
    '热门 · 最新 · 分类短剧',
    restricted: true,
    onlineSearch: true,
    pagedSearch: true,
  );
  static const yeguo = SourceSite(
    'yeguo',
    '野果',
    '分类短剧 · 在线搜索',
    restricted: true,
    onlineSearch: true,
    pagedSearch: true,
  );
  static const huangguoVideo = SourceSite(
    'huangguo-video',
    '黄果视频',
    '视频剧集',
    restricted: true,
    group: 'huangguo',
    groupName: '黄果',
    entryName: '视频',
  );
  static const huangguoAi = SourceSite(
    'huangguoai',
    '黄果 AI',
    'AI 短剧',
    restricted: true,
    group: 'huangguo',
    groupName: '黄果',
    entryName: 'AI',
  );
  static const cloudfront = SourceSite(
    'cloudfront',
    '黄果旧版',
    '旧 API 剧库',
    restricted: true,
    group: 'huangguo',
    groupName: '黄果',
    entryName: '旧版',
  );

  /// 默认开启的站源：红果、韩小圈、鬼片网、青空次元。
  static const primaryValues = [hongguo, hanxiaoquan, guipian, sorani];

  /// 敏感站源：默认关闭，可在站源管理中开启。
  static const restrictedValues = [
    huangdou,
    huangju,
    yeguo,
    dsd,
    huangguoVideo,
    huangguoAi,
    cloudfront,
  ];
  static const knownValues = [...primaryValues, ...restrictedValues];
  static const allValues = [...primaryValues, ...restrictedValues];

  /// 运行期已安装的扩展源；应用启动后由扩展安装器注入。
  /// 未安装的站源不进入 [values]，因此界面与 FFI 授权都不会误放行。
  static List<SourceSite> _extensions = const [];

  /// 当前可用站源：红果内置 + 已安装扩展。
  static List<SourceSite> get values => [
    hongguo,
    for (final site in _extensions)
      if (site.id != hongguo.id) site,
  ];
  static List<SourceSite> get effectiveValues => values;
  static bool get hasExtensions => _extensions.isNotEmpty;

  static void setInstalledExtensions(Iterable<Map<String, dynamic>> entries) {
    final next = [
      for (final entry in entries)
        if ((entry['id'] as String? ?? '').trim().isNotEmpty)
          SourceSite(
            entry['id'] as String,
            (entry['name'] as String? ?? '').trim(),
            (entry['description'] as String? ?? '').trim().isEmpty
                ? '官方扩展源'
                : entry['description'] as String,
            restricted: entry['restricted'] == true,
            group: (entry['group'] as String? ?? '').trim(),
            groupName: (entry['groupName'] as String? ?? '').trim(),
            entryName: (entry['entryName'] as String? ?? '').trim(),
            onlineSearch: entry['onlineSearch'] == true,
            pagedSearch: entry['pagedSearch'] == true,
            suggestions: entry['suggestions'] == true,
          ),
    ];
    // Go 端按 map 遍历返回，排序后再进入界面，避免每次启动顺序漂移。
    final order = {
      for (var index = 0; index < knownValues.length; index++)
        knownValues[index].id: index,
    };
    next.sort((a, b) {
      final byOrder = (order[a.id] ?? 1 << 20).compareTo(
        order[b.id] ?? 1 << 20,
      );
      return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
    });
    _extensions = next;
  }

  static void resetInstalledExtensions() => _extensions = const [];

  static bool isAvailable(String id) => values.any((site) => site.id == id);
  static bool isKnown(String id) =>
      knownValues.any((site) => site.id == id) ||
      _extensions.any((site) => site.id == id);
  static bool isRestricted(String id) => _lookup(id)?.restricted ?? false;
  static SourceSite? _lookup(String id) =>
      _extensions.where((site) => site.id == id).firstOrNull ??
      knownValues.where((site) => site.id == id).firstOrNull;
  static SourceSite? maybeById(String id) => _lookup(id);
  static SourceSite byId(String id) => _lookup(id) ?? hongguo;
}

class SourceGroup {
  const SourceGroup(this.id, this.name, this.sources);
  final String id;
  final String name;
  final List<SourceSite> sources;

  static List<SourceGroup> fromSources(Iterable<SourceSite> sources) {
    final groups = <String, List<SourceSite>>{};
    for (final source in sources) {
      (groups[source.displayGroupId] ??= []).add(source);
    }
    return [
      for (final group in groups.entries)
        SourceGroup(group.key, group.value.first.displayGroupName, group.value),
    ];
  }
}
