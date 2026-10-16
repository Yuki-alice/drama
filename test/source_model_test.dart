import 'package:drama_app/domain/models/source.dart';
import 'package:flutter_test/flutter_test.dart';

/// 源模型解析单测（离线；`version` 信封结构见契约文档 §2.1）。
void main() {
  group('SourceCaps.fromJson', () {
    test('缺字段按不支持处理（未知不拦路）', () {
      const caps = SourceCaps();
      expect(caps.search, isFalse);
      final parsed = SourceCaps.fromJson(const <String, Object?>{
        'search': true,
        'detail': true,
      });
      expect(parsed.search, isTrue);
      expect(parsed.detail, isTrue);
      expect(parsed.playback, isFalse);
    });
  });

  group('SourceInfo.fromJson', () {
    test('正常解析 id + caps', () {
      final info = SourceInfo.fromJson(<String, Object?>{
        'id': 'huangguoai',
        'caps': <String, Object?>{
          'search': true,
          'detail': true,
          'playback': true,
        },
      });
      expect(info.id, 'huangguoai');
      expect(info.isDefault, isFalse);
      expect(info.caps.search, isTrue);
      expect(info.caps.suggest, isFalse);
    });

    test('缺 caps 给空能力（调用方按无能力隐藏入口）', () {
      final info = SourceInfo.fromJson(<String, Object?>{'id': 'x'});
      expect(info.caps.search, isFalse);
    });

    test('主源判定', () {
      expect(
        const SourceInfo(id: 'hongguo', caps: SourceCaps()).isDefault,
        isTrue,
      );
    });
  });
}
