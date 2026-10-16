import 'package:drama_app/data/repositories/playback_repository.dart';
import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假核心：记录调用过的 op，并按 [replies] 给出响应。
class _FakeCore implements CoreCaller {
  _FakeCore(this.replies);

  /// op → 信封（缺失的 op 默认 `UNSUPPORTED`）。
  final Map<String, Map<String, Object?>> replies;

  /// 抛异常的 op（模拟 Rust 核心不可用）。
  final Set<String> throwing = <String>{};

  final List<String> ops = <String>[];

  /// 每次调用的 `(op, params)`（用于断言换档参数口径）。
  final List<(String, Map<String, Object?>?)> calls =
      <(String, Map<String, Object?>?)>[];

  @override
  Future<Map<String, Object?>> call(
    String op, {
    String? source,
    Map<String, Object?>? params,
    Duration? timeout,
  }) async {
    ops.add(op);
    calls.add((op, params));
    if (throwing.contains(op)) throw StateError('核心不可用');
    return replies[op] ??
        <String, Object?>{
          'ok': false,
          'error': <String, Object?>{'code': 'UNSUPPORTED', 'msg': op, 'retry': false},
        };
  }
}

Map<String, Object?> _localPlanJson({String proxy = 'http://127.0.0.1:1/f'}) =>
    <String, Object?>{
      'ok': true,
      'data': <String, Object?>{
        'proxyUrl': proxy,
        'url': 'D:/dl/1/v/video.mp4',
        'vid': 'v',
        'episode': 2,
        'quality': 720,
        'encrypted': false,
        'durationSecs': 0,
        'variants': const <Object?>[],
        'offline': true,
      },
    };

Map<String, Object?> _onlinePlanJson() => <String, Object?>{
  'ok': true,
  'data': <String, Object?>{
    'proxyUrl': 'http://127.0.0.1:1/live',
    'url': 'https://cdn.example/2.mp4',
    'vid': 'v',
    'episode': 2,
    'quality': 1080,
    'encrypted': true,
    'durationSecs': 61.5,
    'variants': const <Object?>[],
  },
};

void main() {
  group('离线优先取流', () {
    test('本地已下载：直接用本地计划，不再发在线 play', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playLocal': _localPlanJson(),
      });
      final plan = await PlaybackRepository(core).resolve(
        seriesId: '1',
        episode: 2,
      );

      expect(core.ops, <String>['playLocal']);
      expect(plan.offline, isTrue);
      expect(plan.proxyUrl, 'http://127.0.0.1:1/f');
      // 本地出流不受在线清晰度偏好影响。
      expect(plan.quality, 720);
    });

    test('本地没有（NOT_FOUND）→ 回落在线 play', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playLocal': <String, Object?>{
          'ok': false,
          'error': <String, Object?>{
            'code': 'NOT_FOUND',
            'msg': 'no local file',
            'retry': false,
          },
        },
        'play': _onlinePlanJson(),
      });
      final plan = await PlaybackRepository(core).resolve(
        seriesId: '1',
        episode: 2,
        quality: 1080,
      );

      expect(core.ops, <String>['playLocal', 'play']);
      expect(plan.offline, isFalse);
      expect(plan.encrypted, isTrue);
      expect(plan.duration, const Duration(milliseconds: 61500));
    });

    test('本地探测抛异常 → 静默回落，不影响起播', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'play': _onlinePlanJson(),
      })..throwing.add('playLocal');
      final plan = await PlaybackRepository(core).resolve(
        seriesId: '1',
        episode: 2,
      );

      expect(core.ops, <String>['playLocal', 'play']);
      expect(plan.proxyUrl, 'http://127.0.0.1:1/live');
    });

    test('本地计划缺 proxyUrl → 视为没有本地文件，回落在线', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playLocal': _localPlanJson(proxy: ''),
        'play': _onlinePlanJson(),
      });
      final plan = await PlaybackRepository(core).resolve(
        seriesId: '1',
        episode: 2,
      );

      expect(core.ops, <String>['playLocal', 'play']);
      expect(plan.offline, isFalse);
    });

    test('本地和在线都没有 → 抛出在线的错误', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{});
      await expectLater(
        PlaybackRepository(core).resolve(seriesId: '1', episode: 2),
        throwsA(isA<RustCoreException>()),
      );
      expect(core.ops, <String>['playLocal', 'play']);
    });

    test('预取命中本地：直接返回本地地址，不签名联网', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playLocal': _localPlanJson(),
      });
      final url = await PlaybackRepository(core).preload(
        seriesId: '1',
        episode: 3,
      );
      expect(url, 'http://127.0.0.1:1/f');
      expect(core.ops, <String>['playLocal']);
    });

    test('预取未命中本地也不异常：返回 null 或在线地址', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{});
      final url = await PlaybackRepository(core).preload(
        seriesId: '1',
        episode: 3,
      );
      expect(url, isNull);
      expect(core.ops, <String>['playLocal', 'preload']);
    });
  });

  group('播放中换档', () {
    // 契约：换档走**独立**的 `playQuality` op（Rust 侧复用已解析候选线路，
    // 零签名零网络），绝不改成「重新走一遍 play」——那会因缓存键不同而
    // 整条签名链重跑，用户点一下要等一轮网络。
    test('switchQuality 发 playQuality，并把新档位带回给 UI', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playQuality': <String, Object?>{
          'ok': true,
          'data': <String, Object?>{
            'proxyUrl': 'http://127.0.0.1:1/live-1080',
            'url': 'https://cdn.example/1080.mp4',
            'vid': 'v',
            'quality': 1080,
            'encrypted': true,
            'durationSecs': 61.5,
            'qualityOptions': <Object?>[
              <String, Object?>{'height': 1440, 'label': '2K'},
              <String, Object?>{'height': 1080, 'label': '1080P'},
              <String, Object?>{'height': 720, 'label': '720P'},
            ],
          },
        },
      });
      final plan = await PlaybackRepository(core).switchQuality(
        seriesId: '1',
        vid: 'v',
        quality: 1080,
      );

      expect(core.ops, <String>['playQuality']);
      // 参数口径：`{id, vid, quality}`，与 Rust 侧契约一致。
      expect(core.calls.single.$2, <String, Object?>{
        'id': '1',
        'vid': 'v',
        'quality': 1080,
      });
      expect(plan.proxyUrl, 'http://127.0.0.1:1/live-1080');
      expect(plan.quality, 1080);
      expect(plan.qualityText, '1080P');
      // 档位表随换档响应一起回来，菜单不用另发一次请求。
      expect(plan.qualityOptions, hasLength(3));
    });

    test('switchQuality 的 quality<=0 时不塞 quality 参数（要最高）', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playQuality': <String, Object?>{
          'ok': true,
          'data': <String, Object?>{
            'proxyUrl': 'http://127.0.0.1:1/live',
            'vid': 'v',
            'quality': 1440,
          },
        },
      });
      await PlaybackRepository(core).switchQuality(
        seriesId: '1',
        vid: 'v',
        quality: 0,
      );
      expect(core.ops, <String>['playQuality']);
      // `quality: 0` = 要最高 → 不带 quality 参数（Rust 侧 `unwrap_or(0)` 同义）。
      expect(core.calls.single.$2, <String, Object?>{'id': '1', 'vid': 'v'});
    });

    test('switchQuality 失败 → 抛 RustCoreException（UI 显示错误码）', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playQuality': <String, Object?>{
          'ok': false,
          'error': <String, Object?>{
            'code': 'NOT_FOUND',
            'msg': 'variant expired',
            'retry': true,
          },
        },
      });
      await expectLater(
        PlaybackRepository(core).switchQuality(
          seriesId: '1',
          vid: 'v',
          quality: 720,
        ),
        throwsA(isA<RustCoreException>()),
      );
    });
  });
}
