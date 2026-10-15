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
  });

  final String dramaId;

  final String dramaTitle;

  /// 1-based 集号。
  final int episode;

  final DownloadStatus status;

  /// 0.0 ~ 1.0。
  final double progress;

  /// Rust 侧任务 id（`seriesId:episode`），操作（暂停/重试/删除）用。
  final String id;
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
  final groups = <String, List<DownloadRecord>>{};
  for (final record in records) {
    groups.putIfAbsent(record.seriesId, () => []).add(record);
  }
  return Stream.value(<DownloadGroup>[
    for (final entry in groups.entries)
      DownloadGroup(
        drama: Drama(
          id: entry.key,
          title: entry.value.first.title.isNotEmpty
              ? entry.value.first.title
              : entry.key,
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
              episode: record.episode,
              status: _statusFrom(record.state),
              progress: record.progress,
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
