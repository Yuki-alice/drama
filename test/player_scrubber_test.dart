import 'package:drama_app/ui/core/playback/playback_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放偏好与进度条的**纯逻辑**验证（不依赖 libmpv，可在 CI 跑）。
void main() {
  group('PlaybackSettings.qualityParam', () {
    test('档位映射到期望清晰度上限，3=最高不限', () {
      expect(const PlaybackSettings(quality: 0).qualityParam, 480);
      expect(const PlaybackSettings(quality: 1).qualityParam, 720);
      expect(const PlaybackSettings(quality: 2).qualityParam, 1080);
      // 3 → 0 表示「不限/最高」（Rust 侧语义见 SourceProvider::play）。
      expect(const PlaybackSettings(quality: 3).qualityParam, 0);
    });

    test('档位标签与 labels 对齐，越界不崩', () {
      expect(const PlaybackSettings(quality: 0).qualityLabel, '标清');
      expect(const PlaybackSettings(quality: 1).qualityLabel, '高清');
      expect(const PlaybackSettings(quality: 2).qualityLabel, '超清');
      expect(const PlaybackSettings(quality: 3).qualityLabel, '最高');
      // 越界值必须被钳制而不是抛异常（设置项来自持久化，可能被手改）。
      expect(const PlaybackSettings(quality: 99).qualityLabel, isNotEmpty);
      expect(const PlaybackSettings(quality: -5).qualityLabel, isNotEmpty);
    });

    test('labels 长度覆盖全部合法档位', () {
      expect(PlaybackSettings.labels.length, greaterThanOrEqualTo(4));
    });
  });

  group('PlaybackSettings 默认值', () {
    test('默认高清 + 自动连播 + 进入即播', () {
      const s = PlaybackSettings();
      expect(s.quality, 1);
      expect(s.qualityParam, 720);
      expect(s.autoPlayNext, isTrue);
      expect(s.autoPlayOnOpen, isTrue);
    });

    test('copyWith 只改指定项', () {
      const s = PlaybackSettings();
      final t = s.copyWith(autoPlayNext: false);
      expect(t.autoPlayNext, isFalse);
      expect(t.quality, s.quality);
      expect(t.autoPlayOnOpen, s.autoPlayOnOpen);
    });
  });
}
