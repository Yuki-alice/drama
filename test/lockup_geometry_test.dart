import 'package:drama_app/domain/models/drama.dart';
import 'package:drama_app/ui/core/theme/app_theme.dart';
import 'package:drama_app/ui/core/widgets/lockups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内容层版式的**几何**约束回归。
///
/// 为什么不用 `takeException()`：`SizedBox` 里的文字超宽时既不会抛异常、
/// 也不会报 RenderFlex overflow——它只是静默画出边界，压到旁边的元素上。
/// 必须直接量渲染尺寸才能测出这类缺陷。
///
/// 实测数据：`AppText.numeral`（27pt 等宽）单行约 27pt 高，
/// 名次列固定 36pt，三位数（榜单可到 100+）靠 `FittedBox` 等比缩下来——
/// 直接排会折行成竖排的「1 2 8」，行高翻三倍。
Drama _drama(String id, String title, int eps) => Drama(
  id: id,
  title: title,
  categoryId: 'c',
  categoryName: '都市',
  episodeCount: eps,
  status: DramaStatus.ongoing,
  tags: const <String>['逆袭'],
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(320, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildMaterialTheme(Brightness.light),
      home: Scaffold(body: ListView(children: <Widget>[child])),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('RankRow 名次列', () {
    for (final rank in <int>[1, 9, 10, 99, 100, 999]) {
      testWidgets('rank=$rank 的名次不折行、不超出 36pt 列宽', (tester) async {
        await _pump(
          tester,
          RankRow(
            drama: _drama('x', '很长的剧名测试溢出情况', 128),
            rank: rank,
            onTap: () {},
          ),
        );
        expect(tester.takeException(), isNull);

        // 断言的正确对象是**绘制高度**（行数）：紧约束下超宽文字不报错，
        // 而是折行——`128` 折成三行会让行高翻三倍。
        final text = find.text('$rank');
        expect(text, findsOneWidget);
        final rect = tester.getRect(text);
        expect(
          rect.height,
          lessThanOrEqualTo(34.0),
          reason:
              'rank=$rank 的绘制高度 ${rect.height.toStringAsFixed(1)}pt '
              '说明名次在 36pt 列里折行了（单行应约 27pt）',
        );
        expect(
          rect.width,
          lessThanOrEqualTo(36.0 + 0.5),
          reason: 'rank=$rank 的绘制宽度 ${rect.width.toStringAsFixed(1)}pt 超出列宽',
        );
      });
    }
  });

  group('其余内容件在大数值下不溢出', () {
    testWidgets('FollowRow 三位集数 + 超长剧名', (tester) async {
      await _pump(
        tester,
        FollowRow(
          title: '很长的剧名测试溢出情况一二三四五六七八九十',
          seed: 'x',
          statusLine: '看到 128 集 · 更新至 320 集',
          progress: .4,
          actionLabel: '继续看',
          onTap: () {},
          onPlay: () {},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.text('继续看')).width,
        lessThan(120),
        reason: '右侧胶囊被长剧名挤到换行',
      );
    });

    testWidgets('DramaPosterCard 三位集数 + 超长标题（3:4 不裁切）', (tester) async {
      const width = 140.0;
      await _pump(
        tester,
        DramaPosterCard(
          drama: _drama('x', '超长剧名一二三四五六七八九十一二三四五六七八九十', 999),
          onTap: () {},
        ),
        // 视口宽度即卡片宽度（ListView 的交叉轴是紧约束，SizedBox 会被忽略）。
        size: const Size(width, 400),
      );
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(DramaPosterCard));
      expect(rect.width, closeTo(width, 0.5));
      // 3:4 → 高 = 宽 / 0.75。
      expect(rect.height, closeTo(width / (3 / 4), 0.5));
    });

    testWidgets('DramaPosterCard 续播胶囊不超出封面', (tester) async {
      await _pump(
        tester,
        DramaPosterCard(
          drama: _drama('x', '剧名', 82),
          watchedEpisode: 34,
          progress: .41,
          onTap: () {},
        ),
        size: const Size(140, 400),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('继续看 34'), findsOneWidget);
    });
  });
}
