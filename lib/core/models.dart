import 'dart:convert';

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

class CatalogCategory {
  const CatalogCategory(this.id, this.name, {this.local = false});
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;
  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
      );
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.tags = const [],
    this.releaseStatus = '',
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final List<String> tags;
  final String releaseStatus;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'tags': tags,
    'releaseStatus': releaseStatus,
  };

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
    );
  }
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true,
      vertical = raw['vertical'] as bool?;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
  final bool? vertical;
}

class DramaDetail {
  DramaDetail(this.drama, this.episodes, {this.warning = ''});
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    return DramaDetail(
      Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
    );
  }
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.danmakuId = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.local = false,
  });
  final String url;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final String danmakuId;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final bool local;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    local: json['local'] == true,
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    danmakuId: json['danmakuId'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
  );
}

class WatchEntry {
  WatchEntry({
    required this.drama,
    required this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final Drama drama;
  final int episode;
  final double position;
  final double duration;
  final DateTime updatedAt;
  bool get finished => duration > 1 && position >= duration - 1;
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episode': episode,
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: intValue(json['episode']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime(2000),
  );
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.drama,
    required this.episode,
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.progress = 0,
    this.quality = 0,
    this.actualQuality = 0,
    this.error = '',
    this.created = 0,
    this.revision = 0,
    this.archived = false,
  });
  final int created;
  final int revision;
  final bool archived;
  final String id;
  final Drama drama;
  final Episode episode;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final int quality;
  final int actualQuality;
  final String error;
  bool get completed => state == 'completed';
  bool get active => state == 'queued' || state == 'downloading';
  bool get resumable => state == 'paused' || state == 'failed';
  String get stateLabel => switch (state) {
    'queued' => '等待下载',
    'downloading' => '正在下载',
    'paused' => '已暂停',
    'failed' => '下载失败',
    'completed' => '已下载',
    'removing' => '正在取消',
    _ => '等待更新',
  };
  factory DownloadJob.fromJson(Map<String, dynamic> value) => DownloadJob(
    id: value['id'] as String? ?? '',
    drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    episode: Episode(
      Map<String, dynamic>.from(value['chapter'] as Map),
      intValue(value['index']),
    ),
    state: value['state'] as String? ?? 'failed',
    bytes: intValue(value['bytes']),
    total: intValue(value['total']),
    progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    quality: intValue(value['quality']),
    actualQuality: intValue(value['actualQuality']),
    error: value['error'] as String? ?? '',
    created: intValue(value['created']),
    revision: intValue(value['revision']),
    archived: value['archived'] == true,
  );
}

List<Map<String, dynamic>> readJsonList(String? value) {
  try {
    return (jsonDecode(value ?? '[]') as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return [];
  }
}
