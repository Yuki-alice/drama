import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/appearance_controller.dart';

/// 播放偏好（设置页与播放页**共用**同一份状态）。
///
/// 之前这些开关是 `settings_view.dart` 的**私有** provider，播放页根本读不到，
/// 于是「默认清晰度 / 自动连播下一集」调了没有任何效果——设置项与行为脱节
/// 比没有设置项更糟。现在提为共享 provider 并持久化。
@immutable
class PlaybackSettings {
  const PlaybackSettings({
    this.quality = 1,
    this.autoPlayNext = true,
    this.autoPlayOnOpen = true,
  });

  /// 期望清晰度上限：0 标清(480) / 1 高清(720) / 2 超清(1080) / 3 最高(0=不限)。
  ///
  /// 传给 Rust `play` 的 `quality` 参数（语义为「期望清晰度上限」，
  /// `0` 表示要最高——见 `SourceProvider::play` 的文档）。
  final int quality;

  /// 播放结束后是否自动连播下一集。
  final bool autoPlayNext;

  /// 打开播放页是否自动开始播放。
  final bool autoPlayOnOpen;

  /// 供 Rust `play{quality}` 使用的取值（3 → 0 = 不限/最高）。
  int get qualityParam => quality >= 3 ? 0 : _qualityHeights[quality];

  /// 档位对应的像素高度（用于「期望上限」语义）。
  static const List<int> _qualityHeights = <int>[480, 720, 1080];

  /// 档位显示名（设置页与播放页共用，避免两处措辞漂移）。
  static const List<String> labels = <String>['标清', '高清', '超清', '最高'];

  String get qualityLabel => labels[quality.clamp(0, labels.length - 1)];

  PlaybackSettings copyWith({
    int? quality,
    bool? autoPlayNext,
    bool? autoPlayOnOpen,
  }) => PlaybackSettings(
    quality: quality ?? this.quality,
    autoPlayNext: autoPlayNext ?? this.autoPlayNext,
    autoPlayOnOpen: autoPlayOnOpen ?? this.autoPlayOnOpen,
  );
}

/// 播放偏好控制器（持久化到 SharedPreferences）。
class PlaybackSettingsController extends Notifier<PlaybackSettings> {
  static const _keyQuality = 'playback.quality';
  static const _keyAutoNext = 'playback.autoPlayNext';
  static const _keyAutoOpen = 'playback.autoPlayOnOpen';

  /// `SharedPreferences` 未注入时（widget 测试）退化为纯内存，不抛错——
  /// 播放偏好不是关键路径，为它让整页崩掉不划算。
  SharedPreferences? get _prefs {
    try {
      return ref.read(sharedPreferencesProvider);
    } catch (_) {
      return null;
    }
  }

  @override
  PlaybackSettings build() {
    final prefs = _prefs;
    if (prefs == null) return const PlaybackSettings();
    return PlaybackSettings(
      quality: prefs.getInt(_keyQuality) ?? 1,
      autoPlayNext: prefs.getBool(_keyAutoNext) ?? true,
      autoPlayOnOpen: prefs.getBool(_keyAutoOpen) ?? true,
    );
  }

  Future<void> setQuality(int value) async {
    state = state.copyWith(quality: value);
    await _prefs?.setInt(_keyQuality, value);
  }

  Future<void> setAutoPlayNext(bool value) async {
    state = state.copyWith(autoPlayNext: value);
    await _prefs?.setBool(_keyAutoNext, value);
  }

  Future<void> setAutoPlayOnOpen(bool value) async {
    state = state.copyWith(autoPlayOnOpen: value);
    await _prefs?.setBool(_keyAutoOpen, value);
  }
}

/// 播放偏好（设置页改、播放页读）。
final playbackSettingsProvider =
    NotifierProvider<PlaybackSettingsController, PlaybackSettings>(
      PlaybackSettingsController.new,
    );
