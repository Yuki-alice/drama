import 'package:drama_app/ui/core/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes', () {
    test('零与负数都读作 0 B', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-1), '0 B');
    });

    test('字节量不留小数', () {
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('跨单位按 1024 进位并保留一位', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(12 * 1024 * 1024), '12.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('极大值不越界到单位表之外', () {
      expect(formatBytes(1024 * 1024 * 1024 * 1024 * 1024), endsWith(' TB'));
    });
  });

  group('formatSpeed', () {
    test('正速率带 /s 后缀', () {
      expect(formatSpeed(2 * 1024 * 1024), '2.0 MB/s');
    });

    test('无速率返回空串，便于调用方省略', () {
      expect(formatSpeed(0), isEmpty);
      expect(formatSpeed(-5), isEmpty);
    });
  });
}
