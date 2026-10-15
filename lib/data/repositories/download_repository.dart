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

  double get progress =>
      total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : 0.0;

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
      );
}

/// 下载仓库：开始/列表/暂停/重试/取消/删除/离线播放地址。
/// 长任务跑 Rust 独立运行时，Dart 只发指令 + 轮询列表取进度。
class DownloadRepository {
  const DownloadRepository(this._core);

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

  /// 离线播放地址（任务必须已完成；返回本机代理 URL）。
  Future<String> offlineUrl(String id) async {
    final data = await _call('playFile', <String, Object?>{'id': id});
    final url = data['proxyUrl'] as String?;
    if (url == null || url.isEmpty) {
      throw const RustCoreException('PARSE', 'playFile 缺少 proxyUrl', false);
    }
    return url;
  }
}

DownloadRepository _repository(Ref ref) {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) throw StateError('Rust 核心不可用');
  return DownloadRepository(SeriesCoreShim(holder.core));
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
