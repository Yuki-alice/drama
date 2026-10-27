import 'danmaku_models.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'resource_settings.dart';
import 'source_status.dart';

/// 站源目录与详情能力。
abstract interface class CatalogGateway {
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<DramaDetail> detail(Drama drama);
  Future<String> cover(Drama drama, {bool force = false});
  bool coverCached(Drama drama);
  Future<List<CatalogCategory>> categories(String source, {bool force = false});
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  });
  Future<List<RankingBoard>> rankingBoards();
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  });
  Future<List<String>> suggestions(String query);
  Future<void> cancelCatalog();
  Future<void> cancelSuggestions();
  Future<void> cancelRecommendations();
  Future<Drama?> supplementMetadata(Drama drama);
  Future<Drama> followCheck(Drama drama);
}

/// 播放地址解析、预加载、弹幕与会话释放。
abstract interface class PlaybackGateway {
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  });
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode);
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  });
  Future<void> cancelPreload();
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  });
  Future<void> cancelHandoff();
  Future<void> cancelPlayback();
  Future<void> release(String session);
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  });
  Future<void> cancelDanmaku();
}

/// 下载任务与批次控制。
abstract interface class DownloadGateway {
  bool get supportsDownloads;
  Future<List<DownloadJob>> downloads();
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  });
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  });
  Future<void> controlDownloads(String command, {String id = ''});
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  });
  Future<int> workLease(String id, String command);
}

/// 存储目录与迁移。
abstract interface class StorageGateway {
  Future<Map<String, dynamic>> storage();
  Future<String> downloadDirectory();
  Future<void> moveDownloads(String directory);
}

/// 站源扩展的安装、启用与任务状态。
abstract interface class SourceGateway {
  bool get supportsSourceManagement;
  Future<SourceStatus> sourceStatus(String source);
  Future<List<Map<String, dynamic>>> extensionIndex();
  Future<List<Map<String, dynamic>>> installedExtensions();
  Future<Map<String, dynamic>> installExtension(
    String source, {
    String? url,
    String? sha256,
    String? code,
  });
  Future<void> uninstallExtension(String source);
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  });
  Future<SourceStatus> cancelSourceJob(String source);

  /// 该源可编辑的设置项（目前是镜像地址）。不支持时返回空列表。
  Future<List<Map<String, dynamic>>> sourceSettings(String source);

  /// 写入单项设置；[value] 为空表示清除，回落到扩展默认值。
  Future<void> saveSourceSetting(String source, String key, String value);
}

/// 局域网设备互联。
abstract interface class LanGateway {
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  );
}

/// 资源/代理设置。
abstract interface class SettingsGateway {
  Future<ResourceSettings> resourceSettings();
  Future<ResourceSettings> saveResourceSettings(ResourceSettings settings);
}
