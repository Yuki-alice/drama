import 'dart:async';

import 'package:duanju_app/features/player/player_controls.dart';
import 'package:duanju_app/features/player/player_interactions.dart';
import 'package:duanju_app/features/player/player_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放器控件层的测试。
///
/// 这组测试是 `PlayerSurface` 抽象存在的理由：`PlayerControls` 与
/// `PlayerInteractions` 此前直接依赖 media_kit 的 `Player`，而 `Player`
/// 构造时要加载原生 libmpv，在 flutter_test 里会抛
/// `Cannot find Mpv.framework`——控件层因此完全没有覆盖。
/// 现在用一个纯 Dart 的假 surface 就能完整驱动。

/// 纯 Dart 的假播放器：状态可变、流可控、命令有记录。
class FakePlayerSurface implements PlayerSurface {
  FakePlayerSurface({
    this.playing = false,
    this.buffering = false,
    this.position = Duration.zero,
    this.duration = const Duration(minutes: 10),
    this.buffer = Duration.zero,
    this.volume = 100,
    this.completed = false,
  });

  bool playing;
  bool buffering;
  bool completed;
  Duration position;
  Duration duration;
  Duration buffer;
  double volume;

  final seeks = <Duration>[];
  final volumeChanges = <double>[];
  final rateChanges = <double>[];
  int playCalls = 0;
  int pauseCalls = 0;

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffer = StreamController<Duration>.broadcast();
  final _volume = StreamController<double>.broadcast();

  @override
  PlayerSurfaceState get state => PlayerSurfaceState(
    playing: playing,
    completed: completed,
    buffering: buffering,
    position: position,
    duration: duration,
    buffer: buffer,
    volume: volume,
  );

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get bufferingStream => _buffering.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<Duration> get bufferStream => _buffer.stream;
  @override
  Stream<double> get volumeStream => _volume.stream;

  /// 模拟播放器上报新状态，触发控件重建。
  void emitPlaying(bool value) {
    playing = value;
    _playing.add(value);
  }

  void emitPosition(Duration value) {
    position = value;
    _position.add(value);
  }

  void emitVolume(double value) {
    volume = value;
    _volume.add(value);
  }

  @override
  Future<void> play() async => playCalls++;

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> seek(Duration target) async => seeks.add(target);

  @override
  Future<void> setVolume(double value) async {
    volume = value;
    volumeChanges.add(value);
  }

  @override
  Future<void> setRate(double value) async => rateChanges.add(value);

  void dispose() {
    _playing.close();
    _buffering.close();
    _position.close();
    _duration.close();
    _buffer.close();
    _volume.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<FakePlayerSurface> pumpControls(
    WidgetTester tester, {
    FakePlayerSurface? surface,
    bool enabled = true,
    bool fullscreen = false,
    String qualityLabel = '自动',
    double speed = 1.0,
    bool showDanmaku = false,
    VoidCallback? onTogglePlayback,
    VoidCallback? onFullscreen,
    Future<void> Function(Duration)? onSeek,
  }) async {
    final fake = surface ?? FakePlayerSurface();
    if (surface == null) addTearDown(fake.dispose);
    final interactions = PlayerInteractions(
      surface: fake,
      available: () => enabled,
      baseSpeed: () => speed,
      onTogglePlayback: onTogglePlayback ?? () {},
      onFullscreen: onFullscreen ?? () {},
      onEpisode: (_) => '第1集',
      onSeek: onSeek,
    );
    addTearDown(interactions.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerControls(
            surface: fake,
            interactions: interactions,
            enabled: enabled,
            fullscreen: fullscreen,
            showOnPlaybackReady: true,
            onFullscreen: onFullscreen ?? () {},
            onBack: () {},
            onPrevious: null,
            onNext: null,
            title: '测试剧集',
            onTogglePlayback: onTogglePlayback ?? () {},
            onEpisodes: () async {},
            onSpeed: () async {},
            onQuality: () async {},
            speed: speed,
            qualityLabel: qualityLabel,
            onFocusSurface: () {},
            onSeek: onSeek,
            showDanmaku: showDanmaku,
          ),
        ),
      ),
    );
    await tester.pump();
    return fake;
  }

  testWidgets('播放中显示暂停图标，暂停时显示播放图标', (tester) async {
    final surface = await pumpControls(tester);

    IconData? iconOf() {
      final finder = find.descendant(
        of: find.byKey(const ValueKey('player-toggle-playback')),
        matching: find.byType(Icon),
      );
      if (finder.evaluate().isEmpty) return null;
      return (tester.widget<Icon>(finder.first)).icon;
    }

    expect(iconOf(), Icons.play_arrow_rounded);

    // 播放器上报开始播放 → 图标应切换（控件此时会淡出，但仍在树里）。
    surface.emitPlaying(true);
    await tester.pump();
    await tester.pump();
    expect(iconOf(), Icons.pause_rounded);

    surface.emitPlaying(false);
    await tester.pump();
    await tester.pump();
    expect(iconOf(), Icons.play_arrow_rounded);
  });

  testWidgets('点击播放按钮回调宿主而不是直接操作播放器', (tester) async {
    var toggles = 0;
    final surface = await pumpControls(
      tester,
      onTogglePlayback: () => toggles++,
    );

    await tester.tap(find.byKey(const ValueKey('player-toggle-playback')));
    await tester.pump();

    expect(toggles, 1);
    // 控件只负责回调，不应自行 play/pause。
    expect(surface.playCalls, 0);
    expect(surface.pauseCalls, 0);
  });

  testWidgets('禁用时不响应播放按钮', (tester) async {
    var toggles = 0;
    await pumpControls(
      tester,
      enabled: false,
      onTogglePlayback: () => toggles++,
    );

    await tester.tap(
      find.byKey(const ValueKey('player-toggle-playback')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(toggles, 0);
  });

  testWidgets('倍速与画质标签按传入值展示', (tester) async {
    await pumpControls(tester, speed: 1.5, qualityLabel: '1080P');

    expect(find.textContaining('1.5'), findsWidgets);
    expect(find.textContaining('1080P'), findsWidgets);
  });

  testWidgets('弹幕按钮只在声明支持时出现', (tester) async {
    await pumpControls(tester, showDanmaku: false);
    expect(find.byKey(const ValueKey('player-danmaku-toggle')), findsNothing);

    await pumpControls(tester, showDanmaku: true);
    expect(find.byKey(const ValueKey('player-danmaku-toggle')), findsWidgets);
  });

  testWidgets('进度流更新后控件随之刷新', (tester) async {
    final surface = await pumpControls(
      tester,
      surface: FakePlayerSurface(duration: const Duration(minutes: 2)),
    );
    addTearDown(surface.dispose);

    surface.emitPosition(const Duration(seconds: 30));
    await tester.pump(); // 让流事件送达监听器
    await tester.pump(); // 应用 setState 后的重建

    // 进度条的值应反映 30s / 120s；不依赖时间文案的具体格式。
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    expect(slider.value, closeTo(30, 0.5));
    expect(slider.max, closeTo(120, 0.5));
  });

  testWidgets('拖动进度条走 onSeek 回调而不是直接 seek 播放器', (tester) async {
    final seeks = <Duration>[];
    final surface = await pumpControls(
      tester,
      surface: FakePlayerSurface(position: const Duration(seconds: 10)),
      onSeek: (target) async => seeks.add(target),
    );
    addTearDown(surface.dispose);

    // 直接驱动 Slider 的 onChangeEnd：drag 在淡出状态下的命中测试不稳定，
    // 而这里要验证的是"回调路由"而不是手势识别。
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('player-progress')),
    );
    expect(slider.onChangeEnd, isNotNull);
    slider.onChangeEnd!(60);
    await tester.pump();

    expect(seeks, isNotEmpty, reason: '应走宿主的 onSeek 回调');
    expect(seeks.single, const Duration(seconds: 60));
    expect(surface.seeks, isEmpty, reason: '控件不应直接操作播放器');
  });
}
