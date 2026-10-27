import 'package:flutter/foundation.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';

/// 观看进度持久化：去重、节流写入与保存告警，不依赖播放器实例。
///
/// 播放时位置连续变化，只靠"值未变就跳过"无法降低写盘频率；这里额外加一层
/// 节流：距上次落盘不足 [minInterval] 且位置前进不足 [minAdvanceMs] 时跳过，
/// 由下一次心跳补写。暂停/退出/切集走 flush，不受节流限制。
class PlaybackProgressController extends ChangeNotifier {
  PlaybackProgressController({
    required this.store,
    required this.repository,
    required this.detail,
    this.mediaId,
    this.flushLan,
    this.minInterval = const Duration(seconds: 15),
    this.minAdvanceMs = 5000,
  });

  final LocalStore store;
  final AppRepository repository;
  final DramaDetail detail;
  final String? mediaId;
  final VoidCallback? flushLan;

  /// 两次落盘之间的最小间隔（不含 flush）。
  final Duration minInterval;

  /// 相对上次落盘的进度前进量下限（毫秒）。
  final int minAdvanceMs;

  int _openedIndex = -1;
  String? _savedKey;
  String? _warning;
  bool _disposed = false;
  DateTime? _lastSavedAt;
  double _lastSavedPosition = 0;

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
    _resetThrottle();
  }

  void markOpened(int index) {
    _openedIndex = index;
    // 切集是本集的第一次记录，不应被上一集的节流窗口拖住。
    _resetThrottle();
  }

  void _resetThrottle() {
    _lastSavedAt = null;
    _lastSavedPosition = 0;
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
    if (!flush && _throttled(seconds)) return;
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
      _lastSavedAt = DateTime.now();
      _lastSavedPosition = seconds;
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

  bool _throttled(double seconds) {
    final last = _lastSavedAt;
    if (last == null) return false;
    if (DateTime.now().difference(last) >= minInterval) return false;
    // 位置回退（拖回开头）也要写，避免节流把用户操作吃掉。
    return (seconds - _lastSavedPosition) * 1000 < minAdvanceMs;
  }
}
