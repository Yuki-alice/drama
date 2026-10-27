import 'package:duanju_app/features/player/playback_health_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports a stall after 20s without position progress', () {
    var now = DateTime(2026, 1, 1);
    final reasons = <String>[];
    final controller = PlaybackHealthController(
      recover: reasons.add,
      now: () => now,
      snapshot: () => const PlaybackHealthSnapshot(
        closed: false,
        acceptErrors: true,
        loading: false,
        failed: false,
        position: Duration(seconds: 8),
        playing: true,
        foreground: true,
      ),
    );
    addTearDown(controller.dispose);

    controller.check();
    now = now.add(const Duration(seconds: 21));
    controller.check();

    expect(reasons, ['position_stalled_20s']);
  });

  test('does not report while paused or loading', () {
    var now = DateTime(2026, 1, 1);
    final reasons = <String>[];
    var snapshot = const PlaybackHealthSnapshot(
      closed: false,
      acceptErrors: true,
      loading: true,
      failed: false,
      position: Duration(seconds: 8),
      playing: true,
      foreground: true,
    );
    final controller = PlaybackHealthController(
      recover: reasons.add,
      now: () => now,
      snapshot: () => snapshot,
    );
    addTearDown(controller.dispose);

    controller.check();
    now = now.add(const Duration(seconds: 30));
    controller.check();
    snapshot = const PlaybackHealthSnapshot(
      closed: false,
      acceptErrors: true,
      loading: false,
      failed: false,
      position: Duration(seconds: 8),
      playing: false,
      foreground: true,
    );
    controller.check();

    expect(reasons, isEmpty);
  });

  test('resets the stall window after a seek', () {
    var now = DateTime(2026, 1, 1);
    var position = const Duration(seconds: 8);
    final reasons = <String>[];
    final controller = PlaybackHealthController(
      recover: reasons.add,
      now: () => now,
      snapshot: () => PlaybackHealthSnapshot(
        closed: false,
        acceptErrors: true,
        loading: false,
        failed: false,
        position: position,
        playing: true,
        foreground: true,
      ),
    );
    addTearDown(controller.dispose);

    controller.check();
    now = now.add(const Duration(seconds: 15));
    position = const Duration(minutes: 2);
    controller.check();
    now = now.add(const Duration(seconds: 15));
    controller.check();

    expect(reasons, isEmpty);
  });
}
