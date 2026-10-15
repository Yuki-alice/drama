import 'package:drama_app/ui/features/library/view_models/library_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造条目：`total = 0` 表示总集数未知。
LibraryItem item({
  String id = 'd',
  int watched = 1,
  int total = 0,
  Duration position = Duration.zero,
}) => LibraryItem(
  id: id,
  title: id,
  watchedEpisode: watched,
  totalEpisode: total,
  position: position,
);

void main() {
  group('LibraryItem 分档判定', () {
    test('加追未开看（第1集 + 位置0）算「想看」', () {
      final i = item(watched: 1, total: 80, position: Duration.zero);
      expect(i.isPlanned, isTrue);
      expect(i.isWatching, isFalse);
      expect(i.isFinished, isFalse);
    });

    test('有播放位置即算「在看」', () {
      final i = item(
        watched: 1,
        total: 80,
        position: const Duration(seconds: 30),
      );
      expect(i.isPlanned, isFalse);
      expect(i.isWatching, isTrue);
      expect(i.isFinished, isFalse);
    });

    test('看到最后一集算「已看」', () {
      final i = item(
        watched: 80,
        total: 80,
        position: const Duration(seconds: 5),
      );
      expect(i.isFinished, isTrue);
      expect(i.isWatching, isFalse);
      expect(i.hasUnwatched, isFalse);
    });

    test('超出总集数也算「已看」（不出现负的未看数）', () {
      final i = item(
        watched: 99,
        total: 80,
        position: const Duration(seconds: 5),
      );
      expect(i.isFinished, isTrue);
      expect(i.hasUnwatched, isFalse);
    });

    test('总集数未知时不臆断「有更新」', () {
      final i = item(watched: 5, total: 0);
      expect(i.hasUnwatched, isFalse);
      expect(i.progress, 0);
    });
  });

  group('progress 计算', () {
    test('总集数未知时为 0（不做除零）', () {
      expect(item(watched: 3, total: 0).progress, 0);
    });

    test('正常比例', () {
      expect(item(watched: 20, total: 80).progress, closeTo(0.25, 1e-9));
    });

    test('超过总集数时钳制在 1.0', () {
      expect(item(watched: 99, total: 80).progress, 1.0);
    });
  });

  group('filterByTab', () {
    late List<LibraryItem> items;

    setUp(() {
      items = <LibraryItem>[
        // 想看：加追未开看。
        item(id: 'planned', watched: 1, total: 80),
        // 在看：有位置、未看完。
        item(
          id: 'watching',
          watched: 3,
          total: 80,
          position: const Duration(seconds: 30),
        ),
        // 已看：看到最后一集。
        item(
          id: 'finished',
          watched: 80,
          total: 80,
          position: const Duration(seconds: 10),
        ),
        // 总集数未知：不算「想看」（位置非 0），也不算「已看」。
        item(
          id: 'unknown',
          watched: 5,
          total: 0,
          position: const Duration(seconds: 20),
        ),
      ];
    });

    List<String> idsFor(int tab) =>
        filterByTab(items, tab).map((e) => e.id).toList();

    test('档 0 只想看', () => expect(idsFor(0), <String>['planned']));
    test('档 1 只有在看', () => expect(idsFor(1), <String>['watching', 'unknown']));
    test('档 2 只有已看', () => expect(idsFor(2), <String>['finished']));
    // 有未看集数 = 总集数已知且 watched < total（planned 与 watching 都满足）。
    test(
      '档 3 只有未看完',
      () => expect(idsFor(3), <String>['planned', 'watching']),
    );

    test('四个档位结果不相同（修复「四档渲染同一列表」）', () {
      final tab0 = idsFor(0).toSet();
      final tab1 = idsFor(1).toSet();
      final tab2 = idsFor(2).toSet();
      final tab3 = idsFor(3).toSet();
      // 至少在部分档位上互不相同——若全等说明分档没生效。
      expect(
        <Set<String>>{tab0, tab1, tab2, tab3}.length,
        greaterThan(1),
      );
    });

    test('未知档位返回全部（防御性）', () {
      expect(filterByTab(items, 99), hasLength(items.length));
    });

    test('空列表任何档位都为空', () {
      for (var tab = 0; tab < 4; tab++) {
        expect(filterByTab(const <LibraryItem>[], tab), isEmpty);
      }
    });
  });
}
