import 'package:drama_app/data/repositories/fake_catalog_repository.dart';
import 'package:drama_app/domain/models/episode.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rust `episodeGroups` op 的返回样例（末组不满一组，正是边界场景）。
Map<String, Object?> _groupsJson(int total, {int groupSize = 50}) {
  final episodes = <Object?>[
    for (var i = 1; i <= total; i++)
      <String, Object?>{'index': i, 'vid': 'v$i', 'title': '第$i集'},
  ];
  final groups = <Object?>[];
  for (var start = 0; start < total; start += groupSize) {
    final end = (start + groupSize).clamp(start + 1, total);
    groups.add(<String, Object?>{
      'index': groups.length,
      'start': start + 1,
      'end': end,
      'label': '${start + 1}-$end',
      'episodes': episodes.sublist(start, end),
    });
  }
  return <String, Object?>{
    'groupSize': groupSize,
    'total': total,
    'groupCount': groups.length,
    'groups': groups,
  };
}

void main() {
  group('EpisodeGroups.fromJson', () {
    test('完整解析：组大小/总数/每组剧集', () {
      // 170 集：前三组满 50，末组 20 —— 正是「末组不满」的边界。
      final groups = EpisodeGroups.fromJson(_groupsJson(170));
      expect(groups.groupSize, 50);
      expect(groups.total, 170);
      expect(groups.groups, hasLength(4));
      // 每组自带本组剧集，Dart 无需再切片。
      expect(groups.groups[0].episodes, hasLength(50));
      expect(groups.groups[3].episodes, hasLength(20));
      expect(groups.groups[3].episodes.first.index, 151);
      expect(groups.groups[3].episodes.last.index, 170);
    });

    test('标签与起止由 Rust 给，Dart 原样渲染', () {
      final groups = EpisodeGroups.fromJson(_groupsJson(170));
      expect(groups.groups.map((g) => g.label).toList(), <String>[
        '1-50',
        '51-100',
        '101-150',
        '151-170',
      ]);
      expect(groups.groups[0].start, 1);
      expect(groups.groups[0].end, 50);
      expect(groups.groups[2].start, 101);
      expect(groups.groups[2].end, 150);
    });

    test('少于一组：1 组；空列表：0 组（不是 1 个空组）', () {
      final short = EpisodeGroups.fromJson(_groupsJson(7));
      expect(short.groups, hasLength(1));
      expect(short.groups[0].label, '1-7');

      final empty = EpisodeGroups.fromJson(<String, Object?>{
        'groupSize': 50,
        'total': 0,
        'groupCount': 0,
        'groups': const <Object?>[],
      });
      expect(empty.groups, isEmpty);
      expect(empty.total, 0);
    });

    test('字段缺失不抛异常（防御上游契约漂移）', () {
      final groups = EpisodeGroups.fromJson(const <String, Object?>{});
      expect(groups.groups, isEmpty);
      expect(groups.total, 0);
    });
  });

  group('Episode.fromJson 与真源解析口径一致', () {
    // `HongguoCatalogRepository._episode` 是另一处解析同一批 JSON 的代码，
    // 两边字段名/默认值必须一致，否则「详情页能看时长、播放页看不到」。
    test('durationSeconds 解析为 Duration，缺失为 null', () {
      final withDuration = Episode.fromJson(<String, Object?>{
        'index': 3,
        'durationSeconds': 144.2,
        'vid': 'v3',
        'locked': true,
      });
      expect(withDuration.duration, const Duration(milliseconds: 144200));
      expect(withDuration.vid, 'v3');
      expect(withDuration.locked, isTrue);

      final without = Episode.fromJson(const <String, Object?>{'index': 4});
      expect(without.duration, isNull);
      expect(without.locked, isFalse);
    });

    test('标题缺省「第 N 集」', () {
      final episode = Episode.fromJson(const <String, Object?>{'index': 12});
      expect(episode.title, '第 12 集');
    });
  });

  group('FakeCatalogRepository.episodeGroups（mock 同口径）', () {
    test('mock 也按组返回，组大小默认 50', () async {
      final repo = FakeCatalogRepository();
      final groups = await repo.episodeGroups(seriesId: 'd001');
      expect(groups.groupSize, 50);
      expect(groups.total, greaterThan(0));
      // mock 的剧目集数 ≥ 60，必然多组——播放页翻页逻辑在 mock 下也能验证。
      expect(groups.groups.length, greaterThan(1));
      expect(groups.groups[0].label, '1-50');
    });

    test('不存在的剧 → 0 组而不是抛异常', () async {
      final repo = FakeCatalogRepository();
      final groups = await repo.episodeGroups(seriesId: 'nope');
      expect(groups.groups, isEmpty);
      expect(groups.total, 0);
    });
  });
}
