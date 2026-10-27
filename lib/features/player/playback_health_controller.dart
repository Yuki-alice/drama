import 'dart:async';

import 'package:duanju_app/features/player/playback_recovery.dart';

class PlaybackHealthSnapshot {
  const PlaybackHealthSnapshot({
    required this.closed,
    required this.acceptErrors,
    required this.loading,
    required this.failed,
    required this.position,
    required this.playing,
    required this.foreground,
  });

  final bool closed;
  final bool acceptErrors;
  final bool loading;
  final bool failed;
  final Duration position;
  final bool playing;
  final bool foreground;
}

/// 每秒检查播放位置是否停滞；只负责判定与回调，停止/重播由调用方处理。
class PlaybackHealthController {
  PlaybackHealthController({
    required this.recover,
    required this.snapshot,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final void Function(String reason) recover;
  final PlaybackHealthSnapshot Function() snapshot;
  final DateTime Function() _now;
  final _health = PlaybackHealth();
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => check());
  }

  void check() => _tick();

  void _tick() {
    final state = snapshot();
    if (state.closed ||
        !state.acceptErrors ||
        state.loading ||
        state.failed ||
        !state.foreground) {
      return;
    }
    if (_health.stalled(
      position: state.position,
      playing: state.playing,
      foreground: state.foreground,
      now: _now(),
    )) {
      recover('position_stalled_20s');
    }
  }

  void reset() => _health.reset();

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
