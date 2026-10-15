import 'package:drama_app/data/repositories/playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackPlan.fromJson', () {
    test('完整信封解析', () {
      final plan = PlaybackPlan.fromJson(<String, Object?>{
        'proxyUrl': 'http://127.0.0.1:9/play/abc/video.mp4',
        'url': 'https://cdn.example/x.mp4',
        'vid': '123',
        'encrypted': true,
        'quality': 1080,
        'durationSecs': 62.5,
        'variants': <Object?>[
          <String, Object?>{
            'url': 'https://cdn.example/x.mp4',
            'quality': 1080,
          },
          <String, Object?>{'url': 'https://cdn.example/y.mp4', 'quality': 720},
        ],
      });
      expect(plan.proxyUrl, contains('127.0.0.1'));
      expect(plan.encrypted, isTrue);
      expect(plan.quality, 1080);
      expect(plan.duration, const Duration(milliseconds: 62500));
      expect(plan.variants, hasLength(2));
      expect(plan.qualities, <int>[1080, 720]);
    });

    test('缺字段时给默认值不抛异常', () {
      final plan = PlaybackPlan.fromJson(const <String, Object?>{});
      expect(plan.proxyUrl, isEmpty);
      expect(plan.encrypted, isFalse);
      expect(plan.duration, Duration.zero);
      expect(plan.variants, isEmpty);
    });
  });
}
