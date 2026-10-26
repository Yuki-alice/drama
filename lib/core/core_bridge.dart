import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/danmaku_models.dart';
import 'package:duanju_app/features/downloads/background_downloads.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/source_status.dart';
import 'package:duanju_app/core/ranking_models.dart';
import 'package:duanju_app/widgets/cover_decoder.dart';
import 'package:duanju_app/core/catalog_updates.dart';
import 'package:duanju_app/features/downloads/download_collections.dart';
import 'package:duanju_app/core/resource_settings.dart';
import 'package:duanju_app/core/diary_service.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

/// 动态库句柄与函数符号进程内只解析一次；
/// [_nativeSymbols] 首次访问发生在工作 isolate 中。
final (_DartRequest, _DartFree) _nativeSymbols = _resolveSymbols();

(_DartRequest, _DartFree) _resolveSymbols() {
  final DynamicLibrary library;
  if (Platform.isAndroid) {
    library = DynamicLibrary.open('libduanju_core.so');
  } else if (Platform.isWindows) {
    library = DynamicLibrary.open(
      path.join(path.dirname(Platform.resolvedExecutable), 'duanju_core.dll'),
    );
  } else if (Platform.isMacOS) {
    library = DynamicLibrary.open(
      path.join(
        path.dirname(Platform.resolvedExecutable),
        'libduanju_core.dylib',
      ),
    );
  } else if (Platform.isLinux) {
    library = DynamicLibrary.open(
      path.join(
        path.dirname(Platform.resolvedExecutable),
        'lib',
        'libduanju_core.so',
      ),
    );
  } else if (Platform.isIOS) {
    library = DynamicLibrary.process();
  } else {
    throw UnsupportedError('当前平台暂不支持原生核心');
  }
  final request = library.lookupFunction<_NativeRequest, _DartRequest>(
    'DuanjuRequest',
  );
  final free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');
  return (request, free);
}

String _nativeRequest(String body) {
  final (request, free) = _nativeSymbols;
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) {
      throw StateError('本地核心没有返回结果');
    }
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) {
      free(output);
    }
  }
}

/// 与 Go 侧 nativeDispatch 的 action 超时（app_runtime.go）配对：
/// 本表每个条目必须长于 Go 侧对应值，保证原生核心先超时并自行清理，
/// Dart 超时后仅负责补发 cancelRead。
const _nativeActionTimeouts = <String, int>{
  'moveDownloads': 620, // Go 侧 10 分钟
  'danmaku': 15, // Go 侧 10 秒
  'preload': 20, // Go 侧 15 秒
};
const _nativeDefaultTimeout = 70; // Go 侧默认 60 秒

/// 常驻工作 isolate：JSON 编解码与 FFI 调用都在非 UI 线程执行，
/// 替代每请求 Isolate.run 的开销。worker 内 Dart 异常不会导致退出；
/// worker 一旦意外退出，后续请求在重建后重试。
class NativeChannel {
  NativeChannel._() {
    _spawn();
  }
  static final NativeChannel instance = NativeChannel._();

  ReceivePort? _port;
  SendPort? _requests;
  Completer<SendPort>? _ready;
  final _pending = <int, Completer<Object?>>{};
  int _sequence = 0;

  void _spawn() {
    _port?.close();
    final ready = _ready = Completer<SendPort>();
    final port = ReceivePort();
    _port = port;
    port.listen((message) {
      if (message is SendPort) {
        _requests = message;
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is List && message.length == 3) {
        final id = message[0] as int;
        final pending = _pending.remove(id);
        if (pending == null || pending.isCompleted) return;
        final failure = message[2] as String?;
        if (failure != null) {
          pending.completeError(AppFailure(failure));
        } else {
          pending.complete(message[1]);
        }
      }
    }, onDone: _onWorkerExited);
    unawaited(
      Isolate.spawn(_channelWorkerMain, port.sendPort)
          .then((worker) {
            final exits = ReceivePort();
            exits.listen((_) => _onWorkerExited());
            worker.addOnExitListener(exits.sendPort);
          })
          .catchError((Object error, StackTrace stack) {
            if (!ready.isCompleted) ready.completeError(error);
            _failAll('本地核心加载失败，请使用完整安装包重新安装');
          }),
    );
  }

  void _onWorkerExited() {
    _requests = null;
    _failAll('本地核心通道已断开，请重试');
  }

  void _failAll(String message) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(AppFailure(message));
    }
    _pending.clear();
  }

  Future<Object?> execute(Map<String, dynamic> input) {
    var ready = _ready;
    if (ready == null || ready.isCompleted && _requests == null) {
      // 通道未建立或 worker 已退出：重建并等待新 worker 就绪。
      _spawn();
      ready = _ready;
    }
    final id = ++_sequence;
    final pending = Completer<Object?>();
    _pending[id] = pending;
    unawaited(() async {
      try {
        final requests = await ready!.future;
        requests.send((id, input));
      } catch (_) {
        if (!pending.isCompleted) {
          pending.completeError(AppFailure('本地核心加载失败，请使用完整安装包重新安装'));
        }
      }
    }());
    return pending.future;
  }
}

@pragma('vm:entry-point')
Future<void> _channelWorkerMain(SendPort initial) async {
  final replies = ReceivePort();
  initial.send(replies.sendPort);
  await for (final message in replies) {
    final (id, input) = message as (int, Map<String, dynamic>);
    try {
      final body = jsonEncode(input);
      final response = jsonDecode(_nativeRequest(body));
      // 回传必须是 List：父 isolate 的监听器按 List 解析，
      // 使用 Dart record 会被静默丢弃并让调用永远等待。
      initial.send([id, response, null]);
    } catch (error) {
      initial.send([id, null, error.toString()]);
    }
  }
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw AppFailure('当前环境不支持设备互联');
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => preload(drama, episode, quality: quality);
  Future<void> cancelHandoff() async {}
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  Future<void> cancelDanmaku() async {}
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<Drama> followCheck(Drama drama) async => (await detail(drama)).drama;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({'source': source});
  Future<List<Map<String, dynamic>>> extensionIndex() async => const [];
  Future<List<Map<String, dynamic>>> installedExtensions() async => const [];
  Future<Map<String, dynamic>> installExtension(
    String source, {
    String? url,
    String? sha256,
    String? code,
  }) async => throw AppFailure('当前环境不支持扩展源');
  Future<void> uninstallExtension(String source) async =>
      throw AppFailure('当前环境不支持扩展源');
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async => throw AppFailure('当前环境不支持站源管理');
  Future<SourceStatus> cancelSourceJob(String source) async =>
      throw AppFailure('当前环境不支持站源管理');
  Future<List<String>> suggestions(String query) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
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

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<String> cover(Drama drama, {bool force = false});
  bool coverCached(Drama drama) => false;
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<void> cancelPlayback();
  Future<void> release(String session);
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  static final _coverPaths = <String, String>{};
  static const _maxCoverPaths = 2000;
  NativeRepository({this.background = false});
  final bool background;
  LocalStore? access;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) => _call({'action': 'lan', 'command': command, 'lan': payload});

  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    final data = await _read('handoff', {
      'action': 'prepareHandoff',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': access != null && !access!.canDownload,
    });
    return PlaybackPlan.fromJson(data);
  }

  @override
  Future<void> cancelHandoff() => _cancelReads('handoff');

  @override
  Future<ResourceSettings> resourceSettings() async =>
      ResourceSettings.fromJson(await _call({'action': 'resourceSettings'}));

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => ResourceSettings.fromJson(
    await _call({
      'action': 'saveResourceSettings',
      'settings': settings.toJson(),
    }),
  );

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      });
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelDanmaku() => _cancelReads('danmaku');

  @override
  Future<void> cancelPreload() => _cancelReads('preload');

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => PlaybackPlan.fromJson(
    await _read('preload', {
      'action': 'preload',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': online || access?.canDownload == false,
    }),
  );

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    _authorize('hongguo');
    if (plan.local || plan.session.isEmpty || plan.danmakuId.isEmpty) {
      throw AppFailure('本集暂不支持弹幕');
    }
    return DanmakuPage.fromJson(
      await _read('danmaku', {
        'action': 'danmaku',
        'playbackSession': plan.session,
        'startMs': startMs,
        'durationMs': durationMs,
      }),
      episodeId: plan.danmakuId,
      startMs: startMs,
      durationMs: durationMs,
    );
  }

  @override
  Future<void> cancelCatalog() => _cancelReads('catalog-');
  @override
  Future<void> cancelSuggestions() => _cancelReads('suggestions');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    _authorize('hongguo');
    return CatalogPage.fromJson(
      await _read('recommendations-$genre', {
        'action': 'recommendations',
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!(drama.source == 'hongguo' && drama.onlineDate.isEmpty ||
        drama.source == 'huangdou' &&
            (drama.heat.isEmpty || drama.vipStatus == null))) {
      return null;
    }
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  Future<Drama> followCheck(Drama drama) async {
    _authorize(drama.source);
    final result = await _call({
      'action': 'followCheck',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final result = await _call({'action': 'rankingBoards'});
    return [
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isAvailable(board.source) &&
              (access?.allowsSource(board.source) ?? true),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage.fromJson(
    await _call({
      'action': 'rankings',
      'board': board,
      'page': page,
      'force': force,
    }),
  );

  @override
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson(
        await _call({'action': 'sourceStatus', 'source': source}),
      );

  @override
  Future<List<Map<String, dynamic>>> extensionIndex() async {
    final result = await _call({'action': 'extensionIndex'});
    return [
      for (final row in result['entries'] as List? ?? const [])
        Map<String, dynamic>.from(row as Map),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> installedExtensions() async {
    final result = await _call({'action': 'installedExtensions'});
    return [
      for (final row in result['entries'] as List? ?? const [])
        Map<String, dynamic>.from(row as Map),
    ];
  }

  @override
  Future<Map<String, dynamic>> installExtension(
    String source, {
    String? url,
    String? sha256,
    String? code,
  }) async => Map<String, dynamic>.from(
    await _call({
      'action': 'installExtension',
      'source': source,
      if (url != null && url.isNotEmpty) 'extensionUrl': url,
      if (sha256 != null && sha256.isNotEmpty) 'extensionSha256': sha256,
      if (code != null && code.isNotEmpty) 'extensionCode': code,
    }),
  );

  @override
  Future<void> uninstallExtension(String source) async {
    await _call({'action': 'uninstallExtension', 'source': source});
  }

  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async {
    _authorize(source);
    if (drama != null && drama.source != source) throw AppFailure('站源与剧集不匹配');
    await BackgroundDownloads.ensureStarted();
    return SourceStatus.fromJson(
      await _call({
        'action': 'sourceJob',
        'source': source,
        'command': operation,
        if (drama != null) 'drama': drama.toJson(),
      }),
    );
  }

  @override
  Future<SourceStatus> cancelSourceJob(String source) async =>
      SourceStatus.fromJson(
        await _call({'action': 'cancelSourceJob', 'source': source}),
      );

  void _authorize(String source) {
    if (!SourceSite.isAvailable(source)) {
      throw AppFailure('当前版本不包含此站源');
    }
  }

  void _downloadPermission() {
    if (access != null && access!.locked) {
      throw AppFailure('本地配置已锁定，请先恢复配置');
    }
  }

  @override
  Future<List<String>> suggestions(String query) async {
    _authorize('hongguo');
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

  @override
  Future<String> downloadDirectory() async {
    _downloadPermission();
    return (await _call({'action': 'downloadDirectory'}))['directory']
            as String? ??
        '';
  }

  @override
  Future<Map<String, dynamic>> storage() async {
    _downloadPermission();
    return _call({'action': 'storage'});
  }

  @override
  Future<void> moveDownloads(String directory) async {
    _downloadPermission();
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      await _call({'action': 'moveDownloads', 'directory': directory});
    } finally {
      await workLease('storage', 'end');
    }
  }

  @override
  Future<int> workLease(String id, String command) async => intValue(
    (await _call({
      'action': 'workLease',
      'jobId': id,
      'command': command,
    }))['count'],
  );
  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      if (!unrestricted && access?.locked == true) {
        throw AppFailure('本地配置已锁定，请先恢复配置');
      }
      if (action == 'rankings') {
        _authorize(RankingBoard.sourceForID(input['board'] as String));
      }
      if (action == 'recommendations' ||
          action == 'cachedRecommendations' ||
          action == 'suggestions' ||
          action == 'danmaku') {
        _authorize('hongguo');
      }
      if ({
        'catalog',
        'cached',
        'categories',
        'sourceStatus',
        'sourceJob',
        'cancelSourceJob',
      }.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
        'cover',
        'prepareCover',
        'detail',
        'metadata',
        'resolve',
        'preload',
        'prepareHandoff',
        'enqueueDownloads',
        'localPlayback',
      }.contains(action)) {
        _authorize((input['drama'] as Map)['source'] as String);
      }
      if (!unrestricted &&
          {
            'downloads',
            'controlDownloads',
            'controlDownloadBatch',
            'storage',
            'downloadDirectory',
            'moveDownloads',
            'workLease',
          }.contains(action)) {
        _downloadPermission();
      }
      if (action == 'resolve' && access != null && !access!.canDownload) {
        input['force'] = true;
      }
      final response = await NativeChannel.instance
          .execute(input)
          .timeout(
            Duration(
              seconds: _nativeActionTimeouts[action] ?? _nativeDefaultTimeout,
            ),
          );
      final body = response as Map<dynamic, dynamic>;
      if (body['ok'] != true) {
        throw AppFailure(
          body['error'] as String? ?? '读取失败，请重试',
          code: body['code'] as String? ?? '',
        );
      }
      final data = body['data'];
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'danmaku',
            'preload',
            'prepareHandoff',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      throw AppFailure('站源响应超时，请重试');
    } catch (failure) {
      DiaryService.add('[Core] ${input['action']} 异常: $failure');
      throw AppFailure('本地核心加载失败，请使用完整安装包重新安装');
    }
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    if (!background) {
      DiaryService.nativeLogPath = path.join(directory.path, 'logs', 'app.log');
    }
    await _call({'action': 'initialize', 'directory': directory.path});
    if (!background) await BackgroundDownloads.prepare();
    if (!background) {
      SystemProxyMonitor.start((value) async {
        await _call({'action': 'updateSystemProxy', 'systemProxy': value});
      });
    }
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final result = await _read('categories-$source', {
      'action': 'categories',
      'source': source,
      'force': force,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage.fromJson(
    await _read('catalog-$source', {
      'action': 'catalog',
      'source': source,
      'page': page,
      'query': query,
      'category': category,
      'force': force,
    }),
  );
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage.fromJson(
        await _call({
          'action': 'cached',
          'source': source,
          'category': category,
        }),
      );
  @override
  bool coverCached(Drama drama) =>
      _coverPaths.containsKey('${drama.id}\u0000${drama.cover}');

  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final key = '${drama.id}\u0000${drama.cover}';
    final known = force ? null : _coverPaths.remove(key);
    if (known != null) {
      _authorize(drama.source);
      if (await File(known).exists()) {
        _coverPaths[key] = known;
        return known;
      }
    }
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    final file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    if (result['heic'] != true) return _rememberCover(key, file);
    final converted = await _coverDecoder.convert(
      file,
      () => _call({'action': 'prepareCover', 'drama': drama.toJson()}),
      force: force,
    );
    _authorize(drama.source);
    return _rememberCover(key, converted);
  }

  String _rememberCover(String key, String path) {
    // LinkedHashMap 按插入序淘汰近似 LRU：命中时重插使条目变为最新。
    _coverPaths.remove(key);
    _coverPaths[key] = path;
    while (_coverPaths.length > _maxCoverPaths) {
      _coverPaths.remove(_coverPaths.keys.first);
    }
    return path;
  }

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail.fromJson(
    await _call({'action': 'detail', 'drama': drama.toJson()}),
  );
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'sequence': ++_playbackSequence,
    }),
  );
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  bool get supportsDownloads => access?.canDownload ?? true;

  @override
  Future<List<DownloadJob>> downloads() async {
    final result = await _call({'action': 'downloads'});
    return (result['jobs'] as List? ?? [])
        .whereType<Map>()
        .map((value) => DownloadJob.fromJson(Map<String, dynamic>.from(value)))
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source);
    await BackgroundDownloads.ensureStarted();
    final result = await _call({
      'action': 'enqueueDownloads',
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source);
    await BackgroundDownloads.ensureStarted();
    final result = await _call({
      'action': 'enqueueDownloads',
      'force': true,
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    _downloadPermission();
    if (ids.isEmpty || ids.length > 500) throw AppFailure('每批请选择 1 至 500 个任务');
    final visible = (await downloads()).map((job) => job.id).toSet();
    if (ids.any((id) => !visible.contains(id))) {
      throw AppFailure('部分任务已删除或无权操作，请刷新');
    }
    if (command == 'resume') await BackgroundDownloads.ensureStarted();
    return DownloadBatchResult.fromJson(
      await _call({
        'action': 'controlDownloadBatch',
        'command': command,
        'jobIds': ids,
        if (expectedVersions.isNotEmpty) 'expectedVersions': expectedVersions,
      }),
    );
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    _downloadPermission();
    if (command == 'resume' || command == 'resumeAll') {
      await BackgroundDownloads.ensureStarted();
    }
    await _call({
      'action': 'controlDownloads',
      'command': command,
      'jobId': id,
    });
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
    });
    if ((result['url'] as String? ?? '').isEmpty) return null;
    return PlaybackPlan.fromJson(result);
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': true,
      'sequence': ++_playbackSequence,
    }),
  );

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }
}
