import 'package:duanju_app/core/catalog_updates.dart';
import 'package:duanju_app/core/danmaku_models.dart';
import 'package:duanju_app/core/gateways.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/ranking_models.dart';
import 'package:duanju_app/core/resource_settings.dart';
import 'package:duanju_app/core/source_status.dart';

enum AppFailureKind {
  unknown,
  localMedia,
  network,
  storage,
  unsupported,
  cancelled,
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = '', AppFailureKind? kind})
    : kind =
          kind ??
          switch (code) {
            'local_media' => AppFailureKind.localMedia,
            'network' => AppFailureKind.network,
            'storage' => AppFailureKind.storage,
            'unsupported' => AppFailureKind.unsupported,
            'cancelled' => AppFailureKind.cancelled,
            _ => AppFailureKind.unknown,
          };
  final String message;
  final String code;
  final AppFailureKind kind;
  @override
  String toString() => message;
}

abstract class AppRepository
    implements
        CatalogGateway,
        PlaybackGateway,
        DownloadGateway,
        StorageGateway,
        SourceGateway,
        LanGateway,
        SettingsGateway {
  /// [updates] 由组合根注入，保证 UI 与仓库共用同一个目录更新通道。
  AppRepository({CatalogUpdates? updates})
    : catalogUpdates = updates ?? CatalogUpdates();

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw AppFailure('当前环境不支持设备互联');
  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => preload(drama, episode, quality: quality);
  @override
  Future<void> cancelHandoff() async {}
  @override
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final CatalogUpdates catalogUpdates;
  @override
  Future<void> cancelPreload() async {}
  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  @override
  Future<void> cancelDanmaku() async {}
  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  @override
  Future<void> cancelCatalog() async {}
  @override
  Future<void> cancelSuggestions() async {}
  @override
  Future<void> cancelRecommendations() async {}
  @override
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  @override
  Future<Drama> followCheck(Drama drama) async => (await detail(drama)).drama;
  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [];
  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  @override
  bool get supportsSourceManagement => false;
  @override
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({'source': source});
  @override
  Future<List<Map<String, dynamic>>> extensionIndex() async => const [];
  @override
  Future<List<Map<String, dynamic>>> installedExtensions() async => const [];
  @override
  Future<Map<String, dynamic>> installExtension(
    String source, {
    String? url,
    String? sha256,
    String? code,
  }) async => throw AppFailure('当前环境不支持扩展源');
  @override
  Future<void> uninstallExtension(String source) async =>
      throw AppFailure('当前环境不支持扩展源');
  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async => throw AppFailure('当前环境不支持站源管理');
  @override
  Future<SourceStatus> cancelSourceJob(String source) async =>
      throw AppFailure('当前环境不支持站源管理');
  @override
  Future<List<String>> suggestions(String query) async => const [];
  @override
  Future<Map<String, dynamic>> storage() async => {};
  @override
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  @override
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  @override
  Future<int> workLease(String id, String command) async => 0;
  @override
  bool get supportsDownloads => false;
  @override
  Future<List<DownloadJob>> downloads() async => [];
  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    if (expectedVersions.isNotEmpty) throw AppFailure('当前环境不支持校验后清理原分集');
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<void> initialize();
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  @override
  Future<CatalogPage> cached(String source, {String category = ''});
  @override
  Future<String> cover(Drama drama, {bool force = false});
  @override
  bool coverCached(Drama drama) => false;
  @override
  Future<DramaDetail> detail(Drama drama);
  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  @override
  Future<void> cancelPlayback();
  @override
  Future<void> release(String session);
}
