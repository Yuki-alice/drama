import 'dart:async';

/// 播放异常后的延迟恢复：先给播放器 900ms 自愈窗口，再决定是否重播。
class PlaybackRecoveryScheduler {
  PlaybackRecoveryScheduler({
    required this.recover,
    required this.canRecover,
    required this.isForeground,
    required this.generation,
    required this.position,
    required this.playerState,
  });

  final void Function(String reason) recover;
  final bool Function() canRecover;
  final bool Function() isForeground;
  final int Function() generation;
  final Duration Function() position;
  final ({bool playing, bool buffering, int width, Duration position})
  Function()
  playerState;

  Timer? _timer;
  bool _pending = false;

  bool get pending => _pending;

  void queue(String reason) {
    if (!canRecover()) return;
    _pending = true;
    if (!isForeground() || (_timer?.isActive ?? false)) return;
    final ticket = generation();
    final from = position();
    _timer = Timer(const Duration(milliseconds: 900), () {
      if (!canRecover() || ticket != generation() || !isForeground()) return;
      _pending = false;
      final state = playerState();
      if (state.playing &&
          !state.buffering &&
          state.width > 0 &&
          state.position > from + const Duration(milliseconds: 300)) {
        return;
      }
      recover(reason);
    });
  }

  void clearPending() => _pending = false;

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}
