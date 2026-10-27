import 'package:duanju_app/features/player/playback_recovery_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('queues recovery when playback stays stalled', () async {
    final reasons = <String>[];
    var generation = 3;
    var foreground = true;
    var position = const Duration(seconds: 10);
    var playing = true;
    final scheduler = PlaybackRecoveryScheduler(
      recover: reasons.add,
      canRecover: () => true,
      isForeground: () => foreground,
      generation: () => generation,
      position: () => position,
      playerState: () =>
          (playing: playing, buffering: false, width: 1280, position: position),
    );
    addTearDown(scheduler.dispose);

    scheduler.queue('player_error');
    await Future<void>.delayed(const Duration(milliseconds: 950));

    expect(reasons, ['player_error']);
    expect(scheduler.pending, isFalse);
  });

  test('skips recovery when playback advanced during the window', () async {
    final reasons = <String>[];
    var position = const Duration(seconds: 10);
    final scheduler = PlaybackRecoveryScheduler(
      recover: reasons.add,
      canRecover: () => true,
      isForeground: () => true,
      generation: () => 1,
      position: () => position,
      playerState: () =>
          (playing: true, buffering: false, width: 1280, position: position),
    );
    addTearDown(scheduler.dispose);

    scheduler.queue('early_completion');
    position = const Duration(seconds: 12);
    await Future<void>.delayed(const Duration(milliseconds: 950));

    expect(reasons, isEmpty);
  });

  test('does not queue while the app is in the background', () async {
    final reasons = <String>[];
    final scheduler = PlaybackRecoveryScheduler(
      recover: reasons.add,
      canRecover: () => true,
      isForeground: () => false,
      generation: () => 1,
      position: () => Duration.zero,
      playerState: () => (
        playing: true,
        buffering: false,
        width: 1280,
        position: Duration.zero,
      ),
    );
    addTearDown(scheduler.dispose);

    scheduler.queue('player_error');
    await Future<void>.delayed(const Duration(milliseconds: 950));

    expect(reasons, isEmpty);
    expect(scheduler.pending, isTrue);
  });
}
