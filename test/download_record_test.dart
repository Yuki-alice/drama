import 'package:drama_app/data/repositories/download_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadRecord.fromJson', () {
    test('完整记录解析与进度计算', () {
      final record = DownloadRecord.fromJson(<String, Object?>{
        'id': '1:2',
        'seriesId': '1',
        'title': 'T',
        'cover': '',
        'episode': 2,
        'vid': '9',
        'quality': 720,
        'total': 100,
        'done': 25,
        'state': 'downloading',
        'error': '',
      });
      expect(record.id, '1:2');
      expect(record.progress, 0.25);
      expect(record.state, 'downloading');
    });

    test('缺字段时给默认值不抛异常', () {
      final record = DownloadRecord.fromJson(const <String, Object?>{});
      expect(record.progress, 0.0);
      expect(record.episode, 0);
    });
  });
}
