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

    // ── 清晰度多档切换 ──────────────────────────────────────────────
    //
    // 档位表由 Rust 随 `play` / `playQuality` 响应下发，Dart 只负责解析与
    // 展示。这里锁住两件事：档位表解析完整、以及 `qualityText` 的口径
    // （优先用 Rust 标签，缺失才回落）。

    Map<String, Object?> planJsonWithOptions() => <String, Object?>{
      'proxyUrl': 'http://127.0.0.1:9/play/abc/video.mp4',
      'url': 'https://cdn.example/x.mp4',
      'vid': '123',
      'encrypted': true,
      'quality': 720,
      'durationSecs': 62.5,
      'qualityOptions': <Object?>[
        <String, Object?>{'height': 1440, 'label': '2K'},
        <String, Object?>{'height': 1080, 'label': '1080P'},
        <String, Object?>{'height': 720, 'label': '720P'},
      ],
    };

    test('解析 Rust 下发的档位表', () {
      final plan = PlaybackPlan.fromJson(planJsonWithOptions());
      expect(plan.qualityOptions, hasLength(3));
      // Rust 给的是降序表，这里保持原序（渲染顺序就是优先级顺序）。
      expect(
        plan.qualityOptions.map((o) => o.height).toList(),
        <int>[1440, 1080, 720],
      );
      expect(plan.qualityOptions.map((o) => o.label).toList(), <String>[
        '2K',
        '1080P',
        '720P',
      ]);
    });

    test('qualityText 优先用 Rust 标签，缺失才回落', () {
      final plan = PlaybackPlan.fromJson(planJsonWithOptions());
      expect(plan.qualityText, '720P');
      // 换到 1080：标签来自档位表，不是自己拼的。
      final switched = PlaybackPlan(
        proxyUrl: plan.proxyUrl,
        url: plan.url,
        vid: plan.vid,
        encrypted: plan.encrypted,
        quality: 1080,
        duration: plan.duration,
        qualityOptions: plan.qualityOptions,
      );
      expect(switched.qualityText, '1080P');
      // 源未上报清晰度（0）→ 「默认」而不是刺眼的 0P。
      final unknown = PlaybackPlan(
        proxyUrl: plan.proxyUrl,
        url: plan.url,
        vid: plan.vid,
        encrypted: false,
        quality: 0,
        duration: plan.duration,
      );
      expect(unknown.qualityText, '默认');
      // 有高度但档位表没这一档（源换了口径）→ 回落 `{h}P`。
      final odd = PlaybackPlan(
        proxyUrl: plan.proxyUrl,
        url: plan.url,
        vid: plan.vid,
        encrypted: false,
        quality: 540,
        duration: plan.duration,
      );
      expect(odd.qualityText, '540P');
    });

    test('没有档位表时换档能力为空（UI 据此隐藏菜单）', () {
      final plan = PlaybackPlan.fromJson(<String, Object?>{
        'proxyUrl': 'http://127.0.0.1:9/play/abc/video.mp4',
        'vid': '123',
        'quality': 360,
      });
      expect(plan.qualityOptions, isEmpty);
    });
  });
}
