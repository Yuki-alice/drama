import 'package:drama_app/data/repositories/download_repository.dart';
import 'package:drama_app/data/repositories/playback_repository.dart';
import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假核心：记录每次调用的 op / params，按 [replies] 回信封。
class _FakeCore implements CoreCaller {
  _FakeCore(this.replies);

  final Map<String, Map<String, Object?>> replies;

  final List<String> ops = <String>[];
  final List<Map<String, Object?>?> params = <Map<String, Object?>?>[];

  @override
  Future<Map<String, Object?>> call(
    String op, {
    String? source,
    Map<String, Object?>? params,
    Duration? timeout,
  }) async {
    ops.add(op);
    this.params.add(params);
    return replies[op] ??
        <String, Object?>{
          'ok': false,
          'error': <String, Object?>{'code': 'BAD_REQUEST', 'msg': op, 'retry': false},
        };
  }
}

void main() {
  group('DownloadSettings.fromJson', () {
    test('带 dir 的完整解析', () {
      final settings = DownloadSettings.fromJson(<String, Object?>{
        'parallel': 4,
        'connections': 2,
        'dir': r'D:\drama\downloads',
      });
      expect(settings.parallel, 4);
      expect(settings.connections, 2);
      expect(settings.dir, r'D:\drama\downloads');
    });

    test('缺字段回落到保守默认值，不抛异常', () {
      final settings = DownloadSettings.fromJson(const <String, Object?>{});
      expect(settings.parallel, DownloadSettings.fallbackParallel);
      expect(settings.connections, DownloadSettings.fallbackConnections);
      expect(settings.dir, isEmpty);
    });
  });

  group('DownloadRepository', () {
    test('setConcurrency 透传 parallel 并返回实际生效值', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'downloadSetConcurrency': <String, Object?>{
          'ok': true,
          'data': <String, Object?>{'parallel': 3, 'connections': 4},
        },
      });
      final applied = await DownloadRepository(core).setConcurrency(3);

      expect(core.ops, <String>['downloadSetConcurrency']);
      expect(core.params.single, <String, Object?>{'parallel': 3});
      expect(applied.parallel, 3);
      expect(applied.connections, 4);
    });

    test('moveDownloads 返回搬迁条目与字节数', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'moveDownloads': <String, Object?>{
          'ok': true,
          'data': <String, Object?>{
            'dir': r'E:\new\dl',
            'moved': 7,
            'bytes': 1048576,
          },
        },
      });
      final result = await DownloadRepository(core).moveDownloads(r'E:\new\dl');

      expect(core.ops, <String>['moveDownloads']);
      expect(core.params.single, <String, Object?>{'dir': r'E:\new\dl'});
      expect(result.dir, r'E:\new\dl');
      expect(result.moved, 7);
      expect(result.bytes, 1048576);
    });

    test('moveDownloads 失败（目标冲突）→ 抛带错误码的异常', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{});
      await expectLater(
        DownloadRepository(core).moveDownloads(r'E:\dup'),
        throwsA(
          isA<RustCoreException>().having((e) => e.code, 'code', 'BAD_REQUEST'),
        ),
      );
    });

    test('localPlan 解出同构计划（offline 标记带上）', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playLocal': <String, Object?>{
          'ok': true,
          'data': <String, Object?>{
            'proxyUrl': 'http://127.0.0.1:9/f',
            'url': 'file',
            'vid': 'v',
            'episode': 1,
            'quality': 480,
            'encrypted': false,
            'durationSecs': 0,
            'variants': const <Object?>[],
            'offline': true,
          },
        },
      });
      final plan = await DownloadRepository(core).localPlan(
        seriesId: '9',
        episode: 1,
      );

      expect(core.ops, <String>['playLocal']);
      expect(core.params.single, <String, Object?>{'id': '9', 'episode': 1});
      expect(plan.offline, isTrue);
      expect(plan.proxyUrl, 'http://127.0.0.1:9/f');
    });

    test('localPlan 缺 proxyUrl → PARSE 异常（不静默给空地址）', () async {
      final core = _FakeCore(<String, Map<String, Object?>>{
        'playLocal': <String, Object?>{
          'ok': true,
          'data': const <String, Object?>{},
        },
      });
      await expectLater(
        DownloadRepository(core).localPlan(seriesId: '9', episode: 1),
        throwsA(
          isA<RustCoreException>().having((e) => e.code, 'code', 'PARSE'),
        ),
      );
    });
  });
}
