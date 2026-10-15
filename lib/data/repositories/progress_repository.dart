import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/rust_core.dart';
import 'catalog_providers.dart';
import 'playback_repository.dart';

/// 追剧条目（Rust `followList` 解包）。
@immutable
class FollowEntry {
  const FollowEntry({
    required this.id,
    required this.title,
    required this.cover,
    required this.episode,
    required this.position,
    required this.duration,
    this.totalEpisode = 0,
  });

  final String id;
  final String title;
  final String cover;
  final int episode;
  final Duration position;
  final Duration duration;

  /// 总集数；`0` = 未知（旧记录或未提供）。
  final int totalEpisode;

  factory FollowEntry.fromJson(Map<String, Object?> json) => FollowEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        episode: (json['episode'] as num?)?.toInt() ?? 1,
        position: Duration(
            seconds: (json['positionSecs'] as num?)?.toInt() ?? 0),
        duration: Duration(
            seconds: (json['durationSecs'] as num?)?.toInt() ?? 0),
        totalEpisode: (json['totalEpisode'] as num?)?.toInt() ?? 0,
      );
}

/// 历史条目（Rust `historyGet` 解包）。
@immutable
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.episode,
    required this.position,
    required this.duration,
  });

  final String id;
  final int episode;
  final Duration position;
  final Duration duration;

  factory HistoryEntry.fromJson(Map<String, Object?> json) => HistoryEntry(
        id: json['id'] as String? ?? '',
        episode: (json['episode'] as num?)?.toInt() ?? 1,
        position: Duration(
            seconds: (json['positionSecs'] as num?)?.toInt() ?? 0),
        duration: Duration(
            seconds: (json['durationSecs'] as num?)?.toInt() ?? 0),
      );
}

/// 进度仓库：追剧 + 历史，Rust 持久化，Dart 只做解包与 provider。
/// 无核心时抛 [StateError]（调用方走错误态）。
class ProgressRepository {
  const ProgressRepository(this._core);

  final SeriesCoreShim _core;

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

  Future<List<T>> _items<T>(
    String op,
    Map<String, Object?> params,
    T Function(Map<String, Object?>) decode,
  ) async {
    final data = await _call(op, params);
    final raw = data['items'];
    if (raw is! List) return const [];
    return <T>[
      for (final item in raw)
        if (item is Map) decode(Map<String, Object?>.from(item)),
    ];
  }

  Future<void> follow({
    required String id,
    String title = '',
    String cover = '',
    int episode = 1,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    int totalEpisode = 0,
  }) async {
    await _call(opFollowPut, <String, Object?>{
      'id': id,
      if (title.isNotEmpty) 'title': title,
      if (cover.isNotEmpty) 'cover': cover,
      'episode': episode,
      'positionSecs': position.inSeconds,
      'durationSecs': duration.inSeconds,
      if (totalEpisode > 0) 'totalEpisode': totalEpisode,
    });
  }

  Future<void> unfollow(String id) async {
    await _call(opFollowDel, <String, Object?>{'id': id});
  }

  Future<List<FollowEntry>> follows() =>
      _items(opFollowList, const <String, Object?>{}, FollowEntry.fromJson);

  Future<void> reportProgress({
    required String id,
    required int episode,
    required Duration position,
    required Duration duration,
  }) async {
    await _call(opHistoryPut, <String, Object?>{
      'id': id,
      'episode': episode,
      'positionSecs': position.inSeconds,
      'durationSecs': duration.inSeconds,
    });
  }

  Future<List<HistoryEntry>> history() =>
      _items(opHistoryGet, const <String, Object?>{}, HistoryEntry.fromJson);

  /// 单剧续播信息：`historyGet{id}` → 该剧的 [HistoryEntry]；无记录返回 `null`。
  ///
  /// 播放页据此定位上次看到第几集、第几秒；与 [history] 走同一 op 的 `id` 分支。
  Future<HistoryEntry?> resumeFor(String id) async {
    final data = await _call(opHistoryGet, <String, Object?>{'id': id});
    final raw = data['item'];
    if (raw is! Map) return null;
    return HistoryEntry.fromJson(Map<String, Object?>.from(raw));
  }

  Future<void> clearHistory() async {
    await _call(opHistoryClear, const <String, Object?>{});
  }
}

/// op 名常量（与 Rust 分发同名，改名需两边同步）。
const String opFollowPut = 'followPut';
const String opFollowDel = 'followDel';
const String opFollowList = 'followList';
const String opHistoryPut = 'historyPut';
const String opHistoryGet = 'historyGet';
const String opHistoryClear = 'historyClear';

/// 由已取到的核心句柄构造仓库；`null` 核心（native asset 缺失）抛 [StateError]。
///
/// 之所以接收句柄而非 `ref`：读侧 provider 拿到的是 `Ref`、写侧
/// [ProgressActions] 拿到的是 `WidgetRef`，两者在 Riverpod 3 无公开公共父类。
ProgressRepository _repositoryOf(RustCoreHolder? holder) {
  if (holder == null) throw StateError('Rust 核心不可用');
  return ProgressRepository(SeriesCoreShim(holder.core));
}

/// 追剧列表 provider（追剧页消费；切页时 invalidate 刷新）。
final followListProvider = FutureProvider<List<FollowEntry>>((ref) async {
  return _repositoryOf(ref.watch(rustCoreProvider)).follows();
});

/// 历史列表 provider。
final historyListProvider = FutureProvider<List<HistoryEntry>>((ref) async {
  return _repositoryOf(ref.watch(rustCoreProvider)).history();
});

/// 当前是否已追剧（详情页按钮态）。`false` 亦用于「核心不可用」——
/// 此时按钮不显示已追剧态，避免误导。
final isFollowingProvider = FutureProvider.family<bool, String>((
  ref,
  id,
) async {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) return false;
  final list = await ProgressRepository(
    SeriesCoreShim(holder.core),
  ).follows();
  return list.any((entry) => entry.id == id);
});

/// 某剧的续播位置（播放页定位起始集/秒）；无记录返回 `null`。
final resumeProvider = FutureProvider.family<HistoryEntry?, String>((
  ref,
  id,
) async {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) return null;
  return ProgressRepository(SeriesCoreShim(holder.core)).resumeFor(id);
});

/// 追剧写入操作。写成功后失效受影响的读 provider，UI 自动刷新。
///
/// 每次调用显式传入 `ref`（而非在构造时捕获），避免 Provider 重建后
/// 持有失效的 `Ref`。
///
/// 写入失败**向上抛**（调用方决定如何提示），不静默吞掉——
/// 与缓存兜底的「回退但可见」口径一致。
class ProgressActions {
  ProgressActions();

  /// 加入/更新追剧。`drama` 的基本信息随写入，供追剧页离线渲染。
  Future<void> follow(
    WidgetRef ref, {
    required String id,
    String title = '',
    int episode = 1,
    int totalEpisode = 0,
  }) async {
    await _repositoryOf(ref.read(rustCoreProvider)).follow(
      id: id,
      title: title,
      episode: episode,
      totalEpisode: totalEpisode,
    );
    ref.invalidate(followListProvider);
    ref.invalidate(isFollowingProvider(id));
  }

  /// 取消追剧（幂等）。
  Future<void> unfollow(WidgetRef ref, String id) async {
    await _repositoryOf(ref.read(rustCoreProvider)).unfollow(id);
    ref.invalidate(followListProvider);
    ref.invalidate(isFollowingProvider(id));
  }

  /// 观看进度上报：同时刷新追剧条目与历史。
  Future<void> reportProgress(
    WidgetRef ref, {
    required String id,
    required int episode,
    required Duration position,
    required Duration duration,
  }) async {
    await _repositoryOf(ref.read(rustCoreProvider)).reportProgress(
      id: id,
      episode: episode,
      position: position,
      duration: duration,
    );
    ref.invalidate(historyListProvider);
    ref.invalidate(resumeProvider(id));
    ref.invalidate(followListProvider);
  }

  /// 上报节流状态：同一部剧 [reportWindow] 内只落一次盘。
  DateTime? _lastReportAt;
  String? _lastReportId;

  /// 是否应跳过本次上报（纯时间判定，便于单测）。
  bool shouldThrottle(
    String id,
    DateTime now, {
    Duration window = reportWindow,
  }) {
    final last = _lastReportAt;
    if (last == null || _lastReportId != id) return false;
    return now.difference(last) < window;
  }

  /// 记录一次成功上报的时刻。
  void markReported(String id, DateTime now) {
    _lastReportAt = now;
    _lastReportId = id;
  }
}

/// 进度上报最小间隔（播放中每 5s 落盘一次足够；进度条本身仍实时渲染）。
const Duration reportWindow = Duration(seconds: 5);

/// 追剧/进度写操作入口。
final progressActionsProvider = Provider<ProgressActions>(
  (ref) => ProgressActions(),
);
