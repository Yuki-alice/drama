import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/rust_core.dart';
import 'catalog_providers.dart';
import 'playback_repository.dart';

/// 下载记录（Rust `downloadList` 单条解包）。
@immutable
class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.seriesId,
    required this.title,
    required this.cover,
    required this.episode,
    required this.vid,
    required this.quality,
    required this.total,
    required this.done,
    required this.state,
    required this.error,
    this.speed = 0,
  });

  final String id;
  final String seriesId;
  final String title;
  final String cover;
  final int episode;
  final String vid;
  final int quality;
  final int total;
  final int done;
  final String state;
  final String error;

  /// 实时吞吐（字节/秒），由 Rust `Meter`（EMA）算好后随列表带回。
  ///
  /// 只有 `downloading` 的任务非 0；Dart 不做任何速度换算，避免两边算法漂移。
  final int speed;

  double get progress =>
      total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : 0.0;

  bool get isCompleted => state == 'completed';

  factory DownloadRecord.fromJson(Map<String, Object?> json) => DownloadRecord(
        id: json['id'] as String? ?? '',
        seriesId: json['seriesId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        episode: (json['episode'] as num?)?.toInt() ?? 0,
        vid: json['vid'] as String? ?? '',
        quality: (json['quality'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        done: (json['done'] as num?)?.toInt() ?? 0,
        state: json['state'] as String? ?? '',
        error: json['error'] as String? ?? '',
        speed: (json['speed'] as num?)?.toInt() ?? 0,
      );
}

/// 下载设置（`downloadList` / `downloadSetConcurrency` 共用的解析结果）。
///
/// [parallel] = 同时下载的任务数（1~6，Rust 侧持久化）；
/// [connections] = 每个任务分摊到的连接数（由 Rust 按总连接预算算出，
/// Dart 只显示，不自己算——否则两边口径会分叉）。
@immutable
class DownloadSettings {
  const DownloadSettings({
    this.parallel = fallbackParallel,
    this.connections = fallbackConnections,
    this.dir = '',
  });

  /// Rust 侧无返回时的保守显示值（`DEFAULT_PARALLEL=2` / `CONNECTIONS_PER_TASK=3`）。
  static const int fallbackParallel = 2;
  static const int fallbackConnections = 3;

  final int parallel;
  final int connections;
  final String dir;

  /// 并发上限（Rust `MAX_PARALLEL_LIMIT`）；UI 据此生成 chip 列表。
  static const int maxParallel = 6;

  factory DownloadSettings.fromJson(Map<String, Object?> json) =>
      DownloadSettings(
        parallel:
            (json['parallel'] as num?)?.toInt() ?? fallbackParallel,
        connections:
            (json['connections'] as num?)?.toInt() ?? fallbackConnections,
        dir: json['dir'] as String? ?? '',
      );
}

/// 搬迁结果（`moveDownloads`）：目标目录 + 条目数 + 字节数。
@immutable
class DownloadMoveResult {
  const DownloadMoveResult({
    required this.dir,
    required this.moved,
    required this.bytes,
  });

  final String dir;
  final int moved;
  final int bytes;
}

/// 下载仓库：开始/列表/暂停/重试/取消/删除/离线播放地址。
/// 长任务跑 Rust 独立运行时，Dart 只发指令 + 轮询列表取进度。
class DownloadRepository {
  const DownloadRepository(this._core);

  final CoreCaller _core;

  Future<Map<String, Object?>> _call(
      String op, Map<String, Object?> params) async {
    final envelope = await _core.call(op, params: params);
    if (envelope['ok'] == true) {
      final data = envelope['data'];
      if (data is Map) return Map<String, Object?>.from(data);
      return const <String, Object?>{};
    }
    throw RustCoreException.fromEnvelope(envelope);
  }

  Future<DownloadRecord> start({
    required String seriesId,
    required int episode,
    String vid = '',
    String title = '',
    String cover = '',
    int quality = 0,
  }) async {
    final data = await _call('downloadStart', <String, Object?>{
      'seriesId': seriesId,
      'episode': episode,
      if (vid.isNotEmpty) 'vid': vid,
      if (title.isNotEmpty) 'title': title,
      if (cover.isNotEmpty) 'cover': cover,
      if (quality > 0) 'quality': quality,
    });
    return DownloadRecord.fromJson(data);
  }

  Future<List<DownloadRecord>> list() async {
    final data = await _call('downloadList', const <String, Object?>{});
    final raw = data['tasks'];
    if (raw is! List) return const [];
    return <DownloadRecord>[
      for (final item in raw)
        if (item is Map) DownloadRecord.fromJson(Map<String, Object?>.from(item)),
    ];
  }

  Future<void> pause(String id) async {
    await _call('downloadPause', <String, Object?>{'id': id});
  }

  Future<void> retry(String id) async {
    await _call('downloadRetry', <String, Object?>{'id': id});
  }

  Future<void> cancel(String id) async {
    await _call('downloadCancel', <String, Object?>{'id': id});
  }

  Future<void> delete(String id, {bool files = false}) async {
    await _call('downloadDelete', <String, Object?>{
      'id': id,
      if (files) 'files': true,
    });
  }

  /// 下载设置（并发数由 Rust 持久化，这里只读出来显示 / 回填 UI）。
  Future<DownloadSettings> settings() async {
    final data = await _call('downloadList', const <String, Object?>{});
    return DownloadSettings.fromJson(data);
  }

  /// 调整同时下载的任务数（1~6），立即生效 **并** 持久化。
  ///
  /// 返回 Rust 侧最终生效值（含由总连接预算算出的每任务连接数）。
  Future<DownloadSettings> setConcurrency(int parallel) async {
    final data = await _call(
      'downloadSetConcurrency',
      <String, Object?>{'parallel': parallel},
    );
    return DownloadSettings.fromJson(data);
  }

  /// 搬迁下载目录到 [dir]（先停机 → 复制 → 切根 → 重写索引 → 删旧）。
  ///
  /// 这是**重操作**：Rust 内层预算 600s、Dart 外层 620s；期间在途任务会被
  /// 掐回排队，完成后自动续跑。UI 需要在这段时间给反馈，不能当成瞬时 op。
  Future<DownloadMoveResult> moveDownloads(String dir) async {
    final data = await _call('moveDownloads', <String, Object?>{'dir': dir});
    return DownloadMoveResult(
      dir: data['dir'] as String? ?? dir,
      moved: (data['moved'] as num?)?.toInt() ?? 0,
      bytes: (data['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// 离线播放计划（`playLocal`）：本集下载已完成时直接出本地文件的代理流。
  ///
  /// 返回结构与在线 [PlaybackPlan] 同构（`offline=true`），
  /// 因此播放器代码无需区分线上线下。未完成 / 无文件 → 抛异常。
  Future<PlaybackPlan> localPlan({
    required String seriesId,
    required int episode,
  }) async {
    final data = await _call('playLocal', <String, Object?>{
      'id': seriesId,
      'episode': episode,
    });
    final plan = PlaybackPlan.fromJson(data);
    if (plan.proxyUrl.isEmpty) {
      throw const RustCoreException('PARSE', 'playLocal 缺少 proxyUrl', false);
    }
    return plan;
  }
}

DownloadRepository _repository(Ref ref) {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) throw StateError('Rust 核心不可用');
  return DownloadRepository(SeriesCoreShim(holder.core));
}

/// 下载设置（并发数 / 每任务连接数 / 下载目录）。
///
/// 与 [downloadListProvider] 分开单取一次，避免设置页为了读并发数
/// 而白白开起 2 秒一轮的任务轮询。
final downloadSettingsProvider = FutureProvider.autoDispose<DownloadSettings>((
  ref,
) async {
  return _repository(ref).settings();
});

/// 调整并发数（成功返回生效值；核心不可用或 Rust 拒绝返回 `null`）。
///
/// Rust 会拒绝越界值（1~6），所以调用方不必自己夹范围——夹了反而会
/// 掩盖「两边上限不一致」的问题。
Future<DownloadSettings?> applyDownloadConcurrency(
  WidgetRef ref,
  int parallel,
) async {
  final holder = ref.read(rustCoreProvider);
  if (holder == null) return null;
  try {
    final applied = await DownloadRepository(
      SeriesCoreShim(holder.core),
    ).setConcurrency(parallel);
    return applied;
  } catch (_) {
    return null;
  } finally {
    // 失败也要刷新：让 chip 弹回 Rust 侧真正生效的值，
    // 而不是停在用户点的那个（未生效）选项上。
    ref.invalidate(downloadSettingsProvider);
  }
}

/// 搬迁下载目录（成功返回结果；失败返回 `null`，错误原因由 UI 另行提示）。
///
/// 该 op 最长 620s（先停机再搬），故调用方要显式给出等待反馈。
Future<DownloadMoveResult?> moveDownloadDir(WidgetRef ref, String dir) async {
  final holder = ref.read(rustCoreProvider);
  if (holder == null) return null;
  try {
    final result = await DownloadRepository(
      SeriesCoreShim(holder.core),
    ).moveDownloads(dir);
    ref.invalidate(downloadSettingsProvider);
    ref.invalidate(downloadListProvider);
    return result;
  } catch (_) {
    return null;
  }
}

/// 下载列表轮询（页面可见时 2 秒一刷；失败保留旧值）。
final downloadListProvider =
    StreamProvider.autoDispose<List<DownloadRecord>>((ref) async* {
  Future<List<DownloadRecord>> fetch() async {
    try {
      return await _repository(ref).list();
    } catch (_) {
      return const <DownloadRecord>[];
    }
  }
  var last = await fetch();
  yield last;
  await for (final _ in Stream.periodic(const Duration(seconds: 2))) {
    try {
      last = await _repository(ref).list();
    } catch (_) {
      // 轮询失败保留旧值。
    }
    yield last;
    if (ref.mounted == false) break;
  }
});
