import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../domain/models/drama.dart';

/// 下载任务状态（PRD F-07，各带中文文案）。
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
  });

  final String dramaId;

  final String dramaTitle;

  /// 1-based 集号。
  final int episode;

  final DownloadStatus status;

  /// 0.0 ~ 1.0。
  final double progress;
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

/// 下载分组数据（W2 mock：取推荐前 3 部，每部前 8 集）。
final downloadGroupsProvider = FutureProvider<List<DownloadGroup>>((ref) async {
  final repository = ref.watch(catalogRepositoryProvider);
  final page = await repository.catalog(categoryId: 'recommend', page: 0);
  final dramas = page.items.take(3).toList(growable: false);
  final groups = <DownloadGroup>[];
  for (final drama in dramas) {
    final detail = await repository.detail(drama.id);
    groups.add(
      DownloadGroup(
        drama: drama,
        tasks: <DownloadTask>[
          for (final episode in detail.episodes.take(8))
            DownloadTask(
              dramaId: drama.id,
              dramaTitle: drama.title,
              episode: episode.index,
              status: _statusFor(episode.index),
              progress: _progressFor(episode.index),
            ),
        ],
      ),
    );
  }
  return groups;
});

/// 按集号循环取状态，保证 completed/downloading/paused/failed/queued 混合出现。
DownloadStatus _statusFor(int episode) =>
    DownloadStatus.values[(episode - 1) % DownloadStatus.values.length];

/// 确定性进度：已完成 = 1.0；排队 = 0.0；其余按「集号 / 8」估算。
double _progressFor(int episode) => switch (_statusFor(episode)) {
  DownloadStatus.completed => 1.0,
  DownloadStatus.queued => 0.0,
  _ => (episode / 8).clamp(0.1, 0.95).toDouble(),
};
