import 'package:flutter/foundation.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';

/// 观看进度持久化：去重、串行写入与保存告警，不依赖播放器实例。
class PlaybackProgressController extends ChangeNotifier {
  PlaybackProgressController({
    required this.store,
    required this.repository,
    required this.detail,
    this.mediaId,
    this.flushLan,
  });

  final LocalStore store;
  final AppRepository repository;
  final DramaDetail detail;
  final String? mediaId;
  final VoidCallback? flushLan;

  int _openedIndex = -1;
  String? _savedKey;
  String? _warning;
  bool _disposed = false;

  int get openedIndex => _openedIndex;
  String? get warning => _warning;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void beginEpisode() {
    _openedIndex = -1;
  }

  void markOpened(int index) {
    _openedIndex = index;
  }

  Future<void> save({
    required Duration position,
    required Duration duration,
    bool flush = false,
  }) async {
    if (_openedIndex < 0) return;
    final seconds = position.inMilliseconds / 1000;
    final total = duration.inMilliseconds / 1000;
    if (seconds < .1) return;
    final key = '${mediaId ?? detail.drama.id}:$_openedIndex:$seconds:$total';
    if (_savedKey == key && _warning == null) {
      if (flush && mediaId == null) flushLan?.call();
      return;
    }
    final entry = WatchEntry(
      drama: repository.catalogUpdates.current(detail.drama),
      episode: detail.episodes[_openedIndex].number,
      position: seconds,
      duration: total,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (mediaId == null) {
        await store.saveWatch(entry);
        if (flush) flushLan?.call();
      } else {
        await store.saveMediaWatch(mediaId!, entry);
      }
      _savedKey = key;
      if (_warning != null) {
        _warning = null;
        notifyListeners();
      }
    } catch (_) {
      if (_warning == null) {
        _warning = '观看进度尚未保存，请检查存储空间后重试。';
        notifyListeners();
      }
    }
  }
}
