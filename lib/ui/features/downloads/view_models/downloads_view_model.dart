import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/download_repository.dart';
import '../../../../data/repositories/playback_repository.dart';
import '../../../../domain/models/drama.dart';

/// 下载任务状态（各带中文文案）。
enum DownloadStatus {
  queued('排队中'),
  downloading('下载中'),
  paused('已暂停'),
  completed('已完成'),
  failed('下载失败');

  const DownloadStatus(this.label);

  final String label;
}

/// 单条下载任务（某部剧的某一集）。
@immutable
class DownloadTask {
  const DownloadTask({
    required this.dramaId,
    required this.dramaTitle,
    required this.episode,
    required this.status,
    required this.progress,
    this.id = '',
    this.total = 0,
    this.done = 0,
    this.speed = 0,
    this.error = '',
    this.source = 'hongguo',
  });

  final String dramaId;

  final String dramaTitle;

  /// 所属源（离线播放 `playLocal` 按源查表）。
  final String source;

  /// 1-based 集号。
  final int episode;

  final DownloadStatus status;

  /// 0.0 ~ 1.0。
  final double progress;

  /// Rust 侧任务 id（`source:seriesId:episode`），操作（暂停/重试/删除）用。
  final String id;

  /// 资源总字节数（未知为 0）。
  final int total;

  /// 已下载字节数。
  final int done;

  /// 实时吞吐（字节/秒），仅 [DownloadStatus.downloading] 有意义。
  final int speed;

  /// 失败原因（`failed` 时的 Rust 原文）。
  final String error;
}

/// 按剧分组的下载任务集合。
@immutable
class DownloadGroup {
  const DownloadGroup({required this.drama, required this.tasks});

  final Drama drama;

  final List<DownloadTask> tasks;

  int get completedCount =>
      tasks.where((task) => task.status == DownloadStatus.completed).length;
}

/// 下载分组数据：Rust 真实任务按剧分组（`downloadListProvider` 轮询驱动）。
final downloadGroupsProvider = StreamProvider<List<DownloadGroup>>((ref) {
  final records = ref.watch(downloadListProvider).value ?? const [];
  // 按（源，剧）分组：跨源同 seriesId 是不同剧，不可并组。
  final groups = <String, List<DownloadRecord>>{};
  for (final record in records) {
    groups.putIfAbsent('${record.source}:${record.seriesId}', () => []).add(record);
  }
  return Stream.value(<DownloadGroup>[
    for (final entry in groups.entries)
      DownloadGroup(
        drama: Drama(
          id: entry.value.first.seriesId,
          source: entry.value.first.source,
          title: entry.value.first.title.isNotEmpty
              ? entry.value.first.title
              : entry.value.first.seriesId,
          categoryId: '',
          categoryName: '',
          episodeCount: entry.value.fold<int>(
              0, (max, r) => r.episode > max ? r.episode : max),
        ),
        tasks: <DownloadTask>[
          for (final record in entry.value)
            DownloadTask(
              id: record.id,
              dramaId: record.seriesId,
              dramaTitle: record.title,
              source: record.source,
              episode: record.episode,
              status: _statusFrom(record.state),
              progress: record.progress,
              total: record.total,
              done: record.done,
              speed: record.speed,
              error: record.error,
            ),
        ],
      ),
  ]);
});

/// Rust 状态串 → UI 状态（未知按排队处理，不抛异常）。
DownloadStatus _statusFrom(String state) => switch (state) {
      'downloading' => DownloadStatus.downloading,
      'paused' => DownloadStatus.paused,
      'completed' => DownloadStatus.completed,
      'failed' => DownloadStatus.failed,
      _ => DownloadStatus.queued,
    };

/// 任务行操作：暂停/继续/重试/删除（经仓库调 Rust op，失败静默）。
Future<void> downloadAction(WidgetRef ref, DownloadTask task) async {
  final holder = ref.read(rustCoreProvider);
  if (holder == null || task.id.isEmpty) return;
  final repository = DownloadRepository(SeriesCoreShim(holder.core));
  try {
    switch (task.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.queued:
        await repository.pause(task.id);
      case DownloadStatus.paused:
      case DownloadStatus.failed:
        await repository.retry(task.id);
      case DownloadStatus.completed:
        await repository.delete(task.id, files: true);
    }
  } catch (_) {
    // 操作失败静默，下轮轮询自愈。
  }
  ref.invalidate(downloadListProvider);
}
