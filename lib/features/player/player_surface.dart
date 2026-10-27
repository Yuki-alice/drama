import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 播放器表层：控件与手势实际需要的那部分播放能力。
///
/// 存在的理由：`PlayerControls`（1085 行）与 `PlayerInteractions` 此前直接
/// 依赖 media_kit 的 `Player`，而 `Player` 构造时要加载原生 libmpv，
/// 在 flutter_test 里会抛 `Cannot find Mpv.framework`——整个控件层因此
/// 无法测试。这里把"控件需要什么"显式声明出来，media_kit 只是其中一种
/// 实现，测试可以给一个纯 Dart 的假实现。
///
/// 刻意保持窄：只包含控件与手势实际读取的字段与命令。播放器的完整能力
/// （播放列表、音轨、截图等）不在这里，避免抽象层随 media_kit 一起膨胀。
abstract interface class PlayerSurface {
  /// 当前状态的快照；控件在 build 里同步读取。
  PlayerSurfaceState get state;

  /// 播放状态流：控件与手势都要响应"开始/停止播放"。
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<double> get volumeStream;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
}

/// [PlayerSurface.state] 的不可变快照。
@immutable
class PlayerSurfaceState {
  const PlayerSurfaceState({
    this.playing = false,
    this.completed = false,
    this.buffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.volume = 100,
  });

  final bool playing;
  final bool completed;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final double volume;
}

/// 把 media_kit 的 `Player` 适配成 [PlayerSurface]。
///
/// 这是生产环境唯一的实现；除它之外不应有代码直接依赖 `Player`。
class MediaKitPlayerSurface implements PlayerSurface {
  MediaKitPlayerSurface(this.player);

  final Player player;

  @override
  PlayerSurfaceState get state {
    final current = player.state;
    return PlayerSurfaceState(
      playing: current.playing,
      completed: current.completed,
      buffering: current.buffering,
      position: current.position,
      duration: current.duration,
      buffer: current.buffer,
      volume: current.volume,
    );
  }

  @override
  Stream<bool> get playingStream => player.stream.playing;

  @override
  Stream<bool> get bufferingStream => player.stream.buffering;

  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get durationStream => player.stream.duration;

  @override
  Stream<Duration> get bufferStream => player.stream.buffer;

  @override
  Stream<double> get volumeStream => player.stream.volume;

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);

  @override
  Future<void> setRate(double rate) => player.setRate(rate);
}
