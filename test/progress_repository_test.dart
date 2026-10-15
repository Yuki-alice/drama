import 'package:drama_app/data/repositories/progress_repository.dart';
import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _coverUrlRewriteGroup();

  group('FollowEntry.fromJson', () {
    test('完整字段解析（含 totalEpisode）', () {
      final entry = FollowEntry.fromJson(<String, Object?>{
        'id': 'd1',
        'title': '某剧',
        'cover': 'https://cdn/cover.jpg',
        'episode': 7,
        'positionSecs': 42,
        'durationSecs': 90,
        'totalEpisode': 80,
        'updatedAtMs': 1234,
      });
      expect(entry.id, 'd1');
      expect(entry.title, '某剧');
      expect(entry.episode, 7);
      expect(entry.position, const Duration(seconds: 42));
      expect(entry.duration, const Duration(seconds: 90));
      expect(entry.totalEpisode, 80);
    });

    test('缺 totalEpisode（旧 progress.json）回落为 0 且不抛异常', () {
      final entry = FollowEntry.fromJson(<String, Object?>{'id': 'old'});
      expect(entry.totalEpisode, 0);
      expect(entry.episode, 1);
      expect(entry.position, Duration.zero);
    });
  });

  group('HistoryEntry.fromJson', () {
    test('完整字段解析', () {
      final entry = HistoryEntry.fromJson(<String, Object?>{
        'id': 'd2',
        'episode': 3,
        'positionSecs': 12,
        'durationSecs': 0,
      });
      expect(entry.id, 'd2');
      expect(entry.episode, 3);
      expect(entry.position, const Duration(seconds: 12));
      expect(entry.duration, Duration.zero);
    });

    test('缺字段时给默认值不抛异常', () {
      final entry = HistoryEntry.fromJson(const <String, Object?>{});
      expect(entry.id, isEmpty);
      expect(entry.episode, 1);
      expect(entry.position, Duration.zero);
    });
  });

  group('ProgressActions 上报节流', () {
    test('首次上报不被节流', () {
      final actions = ProgressActions();
      expect(
        actions.shouldThrottle('d1', DateTime(2026, 1, 1, 12, 0, 0)),
        isFalse,
      );
    });

    test('窗口内同一部剧被节流，窗口外放行', () {
      final actions = ProgressActions();
      final start = DateTime(2026, 1, 1, 12, 0, 0);
      actions.markReported('d1', start);

      // 窗口内（5s 未到）→ 节流。
      expect(
        actions.shouldThrottle('d1', start.add(const Duration(seconds: 4))),
        isTrue,
      );
      // 恰好到达窗口边界 → 放行（差值不小于 window）。
      expect(
        actions.shouldThrottle('d1', start.add(reportWindow)),
        isFalse,
      );
      // 超过窗口 → 放行。
      expect(
        actions.shouldThrottle('d1', start.add(const Duration(seconds: 30))),
        isFalse,
      );
    });

    test('换一部剧不受上一部剧的节流影响', () {
      final actions = ProgressActions();
      final start = DateTime(2026, 1, 1, 12, 0, 0);
      actions.markReported('d1', start);
      expect(
        actions.shouldThrottle('d2', start.add(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('自定义窗口生效', () {
      final actions = ProgressActions();
      final start = DateTime(2026, 1, 1, 12, 0, 0);
      actions.markReported('d1', start);
      expect(
        actions.shouldThrottle(
          'd1',
          start.add(const Duration(seconds: 30)),
          window: const Duration(minutes: 1),
        ),
        isTrue,
      );
    });
  });

  group('op 名常量与 Rust 分发一致', () {
    test('追剧/历史 op 名固定（改名需两边同步）', () {
      expect(opFollowPut, 'followPut');
      expect(opFollowDel, 'followDel');
      expect(opFollowList, 'followList');
      expect(opHistoryPut, 'historyPut');
      expect(opHistoryGet, 'historyGet');
      expect(opHistoryClear, 'historyClear');
    });
  });
}

/// 封面 URL 端口改写：目录会落盘缓存，端口是实现细节，不该写死进缓存数据。
void _coverUrlRewriteGroup() {
  group('rewriteProxyPort', () {
    test('把缓存里的旧端口改写到本次会话端口', () {
      expect(
        rewriteProxyPort('http://127.0.0.1:59789/img/abc.def', 47800),
        'http://127.0.0.1:47800/img/abc.def',
      );
    });

    test('端口已一致时原样返回', () {
      const url = 'http://127.0.0.1:47800/img/abc.def';
      expect(rewriteProxyPort(url, 47800), url);
    });

    test('端口未知时不改写', () {
      const url = 'http://127.0.0.1:59789/img/abc.def';
      expect(rewriteProxyPort(url, null), url);
    });

    test('非本机地址不改写（只动我们自己的代理地址）', () {
      const remote = 'https://cdn.example.com/a.png';
      expect(rewriteProxyPort(remote, 47800), remote);
      expect(rewriteProxyPort('', 47800), '');
      expect(rewriteProxyPort('not a url', 47800), 'not a url');
    });

    test('媒体代理地址同样适用（/play/ 路径）', () {
      expect(
        rewriteProxyPort('http://127.0.0.1:59789/play/tok/video.mp4', 47800),
        'http://127.0.0.1:47800/play/tok/video.mp4',
      );
    });
  });
}
