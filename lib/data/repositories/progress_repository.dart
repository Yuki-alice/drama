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
  });

  final String id;
  final String title;
  final String cover;
  final int episode;
  final Duration position;
  final Duration duration;

  factory FollowEntry.fromJson(Map<String, Object?> json) => FollowEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        episode: (json['episode'] as num?)?.toInt() ?? 1,
        position: Duration(
            seconds: (json['positionSecs'] as num?)?.toInt() ?? 0),
        duration: Duration(
            seconds: (json['durationSecs'] as num?)?.toInt() ?? 0),
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
  }) async {
    await _call(opFollowPut, <String, Object?>{
      'id': id,
      if (title.isNotEmpty) 'title': title,
      if (cover.isNotEmpty) 'cover': cover,
      'episode': episode,
      'positionSecs': position.inSeconds,
      'durationSecs': duration.inSeconds,
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

ProgressRepository _repository(Ref ref) {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) throw StateError('Rust 核心不可用');
  return ProgressRepository(SeriesCoreShim(holder.core));
}

/// 追剧列表 provider（追剧页消费；切页时 invalidate 刷新）。
final followListProvider = FutureProvider<List<FollowEntry>>((ref) async {
  return _repository(ref).follows();
});

/// 历史列表 provider。
final historyListProvider = FutureProvider<List<HistoryEntry>>((ref) async {
  return _repository(ref).history();
});
