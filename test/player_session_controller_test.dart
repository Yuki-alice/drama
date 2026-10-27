import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/features/player/playback_loader.dart';
import 'package:duanju_app/features/player/playback_preloader.dart';
import 'package:duanju_app/features/player/playback_progress_controller.dart';
import 'package:duanju_app/features/player/player_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _Host implements PlayerPlaybackHost {
  @override
  bool closed = false;
  @override
  bool foreground = true;
  bool playing = false;
  bool completed = false;
  double playhead = 0;
  final opened = <PlaybackPlan>[];
  final failures = <String>[];
  int attaches = 0;
  int detaches = 0;
  int saves = 0;
  int playPauses = 0;
  int recoveryQueued = 0;
  int stops = 0;

  @override
  bool get localOnly => false;

  @override
  bool get allowOnlineFallback => true;

  @override
  bool get playerPlaying => playing;

  @override
  bool get playerCompleted => completed;

  @override
  double get playheadSeconds => playhead;

  @override
  Future<void> saveProgress({bool flush = false}) async => saves++;

  @override
  void cancelInteractions() {}

  @override
  void resetSeekSequence() {}

  @override
  void suspendEnhancement() {}

  @override
  Future<void> beforeMedia() async {}

  @override
  Future<void> stopPlayer() async => stops++;

  @override
  Future<void> openPlan(
    PlaybackPlan plan, {
    required double position,
    required bool play,
  }) async {
    opened.add(plan);
    playhead = position;
  }

  @override
  void mediaReady() {}

  @override
  Future<void> applySpeed() async {}

  @override
  Future<void> playOrPause() async => playPauses++;

  @override
  void setDanmakuPlan(PlaybackPlan? plan) {}

  @override
  void syncDanmaku() {}

  @override
  void acknowledgeHandoff() {}

  @override
  void bumpMenu() {}

  @override
  void attachLan(PlayerSessionController controller) => attaches++;

  @override
  void detachLan() => detaches++;

  @override
  void resetHealth() {}

  @override
  void queueRecovery(String reason) => recoveryQueued++;

  @override
  void cancelPendingRecovery() {}

  @override
  void failHandoff(String message) => failures.add(message);

  @override
  void releaseHandoffOwnership() {}
}

class _LocalRepository extends FixtureRepository {
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => const PlaybackPlan(
    url: 'file:///tmp/local.mp4',
    local: true,
    session: 'local-session',
  );
}

class _FailingRepository extends FixtureRepository {
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => throw AppFailure('合成解析失败');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const drama = Drama(
    id: 'hongguo:session',
    source: 'hongguo',
    title: '会话测试剧',
    episodes: 2,
  );
  final detail = DramaDetail(drama, [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
    Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
  ]);

  Future<(PlayerSessionController, _Host)> build({
    FixtureRepository? repository,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final repo = repository ?? FixtureRepository();
    final host = _Host();
    final progress = PlaybackProgressController(
      store: store,
      repository: repo,
      detail: detail,
    );
    addTearDown(progress.dispose);
    final controller = PlayerSessionController(
      repository: repo,
      detail: detail,
      loader: PlaybackLoader(repo),
      preloader: PlaybackPreloader(repo),
      progress: progress,
      host: host,
      initialIndex: 0,
      preferences: const PlaybackPreferences(),
    );
    addTearDown(controller.dispose);
    return (controller, host);
  }

  test('play resolves a plan and opens the player', () async {
    final (controller, host) = await build();

    await controller.play(0);

    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
    expect(controller.plan, isNotNull);
    expect(host.opened, hasLength(1));
    expect(controller.progress.openedIndex, 0);
    expect(host.attaches, greaterThan(0));
  });

  test('play surfaces resolution failures without hanging loading', () async {
    final (controller, host) = await build(repository: _FailingRepository());

    await controller.play(0);

    expect(controller.loading, isFalse);
    expect(controller.plan, isNull);
    expect(controller.error, contains('合成解析失败'));
    expect(host.failures, isNotEmpty);
    expect(host.opened, isEmpty);
  });

  test('switching episodes resets opened progress and plan', () async {
    final (controller, host) = await build();
    await controller.play(0);

    await controller.play(1);

    expect(controller.index, 1);
    expect(host.opened, hasLength(2));
    expect(controller.progress.openedIndex, 1);
  });

  test('togglePlayback follows player state and notifies host', () async {
    final (controller, host) = await build();
    await controller.play(0);

    host.playing = false;
    await controller.togglePlayback();
    expect(controller.playIntent, isTrue);
    expect(host.playPauses, 1);

    host.playing = true;
    await controller.togglePlayback();
    expect(controller.playIntent, isFalse);
    expect(host.playPauses, 2);
  });

  test('recover replays through the refresh path', () async {
    final (controller, host) = await build();
    await controller.play(0);
    host.opened.clear();

    await controller.recover(reason: 'player_error');

    expect(controller.error, isNull);
    expect(host.opened, hasLength(1));
  });

  test('recover stops on a local plan and explains the failure', () async {
    final (controller, host) = await build(repository: _LocalRepository());
    await controller.play(0);

    await controller.recover(reason: 'player_error');

    expect(host.stops, greaterThan(0));
    expect(controller.loading, isFalse);
    expect(controller.error, contains('本地视频读取失败'));
  });

  test('retry keeps the current playhead', () async {
    final (controller, host) = await build();
    await controller.play(0);
    host.playhead = 33;

    await controller.retry(quality: 720);

    expect(controller.requestedQuality, 720);
    expect(host.opened, hasLength(2));
    expect(controller.qualityLabel, '720P');
  });
}
