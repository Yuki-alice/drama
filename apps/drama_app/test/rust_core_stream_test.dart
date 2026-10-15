import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// ARCH §3.2 取消协议的**会话划分**单测（离线、无网络）。
///
/// 这里固定的是「并发读不得互相取消」这条不变量：首页启动会并发打
/// `catalog / recommend / ranking`，若它们共用一个 `session`，
/// Rust 侧序列仲裁会把先发的判为「迟到」返回 `CANCELED` → 首页随机空白。
void main() {
  // ARCH §3.2 文档化的 session 字符集（不含 `_`，故从严按此断言）。
  final sessionPattern = RegExp(r'^[0-9a-zA-Z\-_:.]{1,128}$');

  group('逻辑流（session）划分', () {
    test('首页并发读各自独立 session —— 不会互相取消', () {
      final streams = <String>{
        logicalStreamFor('catalog', <String, Object?>{
          'category': 'recommend',
          'page': 0,
        }),
        logicalStreamFor('recommend', null),
        logicalStreamFor('ranking', <String, Object?>{'board': 'hot'}),
        logicalStreamFor('catalog', <String, Object?>{
          'category': 'real-drama',
          'page': 0,
        }),
      };
      expect(streams.length, 4, reason: '并发读必须落在 4 条不同逻辑流上：$streams');
    });

    test('同一逻辑流的重复请求共用 session（此时才允许互相取代）', () {
      expect(
        logicalStreamFor('catalog', <String, Object?>{
          'category': 'urban',
          'page': 0,
        }),
        logicalStreamFor('catalog', <String, Object?>{
          'category': 'urban',
          'page': 1,
        }),
      );
    });

    test('不同榜单板 = 不同 session', () {
      expect(
        logicalStreamFor('ranking', <String, Object?>{'board': 'hot'}),
        isNot(logicalStreamFor('ranking', <String, Object?>{'board': 'rising'})),
      );
    });

    test('中文关键词：session 合法（字符集/长度）且不同关键词不撞名', () {
      final a = logicalStreamFor('search', <String, Object?>{'keyword': '总裁'});
      final b = logicalStreamFor('search', <String, Object?>{
        'keyword': '总裁的替嫁新娘',
      });
      final c = logicalStreamFor('suggest', <String, Object?>{'keyword': '总裁'});

      expect(sessionPattern.hasMatch(a), isTrue, reason: a);
      expect(sessionPattern.hasMatch(b), isTrue, reason: b);
      expect(a, isNot(b));
      expect(a, isNot(c));
    });

    test('detail 用剧集 id；无参 op 也产出合法 session', () {
      final detail = logicalStreamFor('detail', <String, Object?>{
        'id': '7503745441910017049',
      });
      expect(sessionPattern.hasMatch(detail), isTrue, reason: detail);
      for (final op in <String>['ping', 'version', 'preload', 'cancelRead']) {
        final session = logicalStreamFor(op, null);
        expect(sessionPattern.hasMatch(session), isTrue, reason: session);
      }
    });

    test('极长关键词仍 ≤128 字符且合法', () {
      final session = logicalStreamFor('search', <String, Object?>{
        'keyword': '总' * 300,
      });
      expect(session.length <= 128, isTrue, reason: 'len=${session.length}');
      expect(sessionPattern.hasMatch(session), isTrue, reason: session);
    });

    test('缺参数的 catalog 不产出空 session', () {
      final session = logicalStreamFor('catalog', null);
      expect(session.isEmpty, isFalse);
      expect(sessionPattern.hasMatch(session), isTrue, reason: session);
    });
  });

  group('RustCoreException.isSuperseded', () {
    test('CANCELED 视为「已被取代」，其余不是', () {
      expect(const RustCoreException('CANCELED', 'x', false).isSuperseded, isTrue);
      expect(const RustCoreException('TIMEOUT', 'x', true).isSuperseded, isFalse);
      expect(
        const RustCoreException('source_blocked', 'x', false).isSuperseded,
        isFalse,
      );
    });
  });
}
