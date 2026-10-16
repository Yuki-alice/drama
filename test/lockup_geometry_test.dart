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
/// 实测数据：`AppText.numeral`（30pt 等宽）约 29pt/字符，
/// 所以 1 位 = 29、2 位 = 58、3 位 = 87。名次列固定 42pt，
/// **三位数必然溢出**——榜单超过 99 条就会压到标题。
Drama _drama(String id, String title, int eps) => Drama(
  id: id,
  title: title,
  categoryId: 'c',
  categoryName: '都市',
  episodeCount: eps,
  status: DramaStatus.ongoing,
  tags: const <String>['逆袭'],
);

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(320, 700)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildMaterialTheme(Brightness.light),
      home: Scaffold(body: ListView(children: <Widget>[child])),
    ),
  );
  await tester.pumpAndSettle();
}

/// 一个 widget 的**实际绘制矩形**（把祖先施加的缩放算进去）。
///
/// `tester.getRect` 会把 `getTransformTo(null)` 算进来，所以 `FittedBox`
/// 的缩放是可见的；直接读 child 的 `size` 则拿不到。
Rect _paintedRect(WidgetTester tester, Finder finder) => tester.getRect(finder);

void main() {
  group('RankRow 名次列', () {
    for (final rank in <int>[1, 9, 10, 99, 100, 999]) {
      testWidgets('rank=$rank 的名次不超出 42pt 列宽', (tester) async {
        await _pump(
          tester,
          RankRow(
            drama: _drama('x', '很长的剧名测试溢出情况', 128),
            rank: rank,
            onTap: () {},
          ),
        );
        expect(tester.takeException(), isNull);

        // 关键：在**紧约束的 42pt 列**里，超宽文字不会溢出、也不会报错，
        // 而是**折行**——实测 `128` 在 42pt 宽下从 30pt 高变成 90pt 高
        // （三个字各占一行），行高翻三倍且读作竖排的「1 2 8」。
        // 所以断言的正确对象是**绘制高度**（行数），不是宽度。
        final text = find.text('$rank');
        expect(text, findsOneWidget);
        final rect = _paintedRect(tester, text);
        expect(
          rect.height,
          lessThanOrEqualTo(34.0),
          reason: 'rank=$rank 的绘制高度 ${rect.height.toStringAsFixed(1)}pt '
              '说明名次在 42pt 列里折行了（单行应为 30pt）',
        );
        expect(
          rect.width,
          lessThanOrEqualTo(42.0 + 0.5),
          reason: 'rank=$rank 的绘制宽度 ${rect.width.toStringAsFixed(1)}pt '
              '超出列宽',
        );
      });
    }

    testWidgets('名次列与封面不重叠', (tester) async {
      await _pump(
        tester,
        RankRow(drama: _drama('x', '剧名', 128), rank: 128, onTap: () {}),
      );
      final rankRect = tester.getRect(find.text('128'));
      final coverRect = tester.getRect(find.byType(RankRow));
      expect(
        rankRect.right,
        lessThanOrEqualTo(coverRect.left + 60),
        reason: '名次画到了行外',
      );
    });
  });

  group('其余 lockup 在大数值下不溢出', () {
    testWidgets('LibraryRow 三位集数', (tester) async {
      await _pump(
        tester,
        LibraryRow(
          title: '很长的剧名测试溢出情况',
          seed: 'x',
          watchedEpisode: 128,
          totalEpisode: 320,
          progress: .4,
          statusLine: '看到第 128 集 / 共 320 集',
          updatedLabel: '还有未看的',
          onTap: () {},
          onPlay: () {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('HeroLockup 超长标题与集数', (tester) async {
      await _pump(
        tester,
        HeroLockup(
          drama: _drama('x', '超长剧名一二三四五六七八九十一二三四五六七八九十', 999),
          onTap: () {},
          height: 300,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('ContinueLockup 长标题 + 三位集数', (tester) async {
      await _pump(
        tester,
        ContinueLockup(
          drama: _drama('x', '超长剧名一二三四五六七八九十', 96),
          onTap: () {},
          progress: .3,
          progressLabel: '看到第 128 集 / 共 320 集',
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('PosterLockup 三位集数角标', (tester) async {
      await _pump(
        tester,
        PosterLockup(
          drama: _drama('x', '超长剧名一二三四五六七八九十', 999),
          onTap: () {},
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
