import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RustCoreException.fromEnvelope', () {
    test('解析标准错误信封', () {
      final exception = RustCoreException.fromEnvelope(<String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'UNSUPPORTED',
          'msg': 'unknown op: foo',
          'retry': true,
        },
      });

      expect(exception.code, 'UNSUPPORTED');
      expect(exception.msg, 'unknown op: foo');
      expect(exception.retry, isTrue);
    });

    test('缺失 error 字段时回退为 UNKNOWN', () {
      final exception = RustCoreException.fromEnvelope(<String, Object?>{
        'ok': false,
      });

      expect(exception.code, 'UNKNOWN');
      expect(exception.retry, isFalse);
    });
  });
}
