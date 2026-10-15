import 'package:flutter/foundation.dart';

/// 单集领域模型（PRD F-04「选集」）。
@immutable
class Episode {
  const Episode({
    required this.index,
    required this.title,
    this.vid,
    this.duration,
    this.locked = false,
  });

  /// 1-based 集号。
  final int index;

  /// 集标题（默认「第 N 集」）。
  final String title;

  /// 源侧视频 ID（红果 `vid_list[]` 的取值）——W3 取流时使用。
  final String? vid;

  final Duration? duration;

  /// 该集是否需授权才能播放。
  ///
  /// 轨① 免签只覆盖可试看集（SourceSpec §11.4）；锁定集在 UI 上必须**明示**
  /// 「该集需 App 授权」，不得静默失败（plan §8）。
  final bool locked;
}
