import 'package:drama_app/domain/models/drama.dart';
import 'package:drama_app/ui/core/tokens/app_tokens.dart';
import 'package:drama_app/ui/core/theme/app_theme.dart';
import 'package:drama_app/ui/core/widgets/app_nav_bar.dart';
import 'package:drama_app/ui/core/widgets/lockups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内容出血到玻璃栏之下时，**最后一行不得被栏永久遮住**。
///
/// 这类缺陷只在「滚到底」时才暴露，手测极易漏掉：栏是半透明的，
/// 被遮住的最后一行看起来「像是还没滚完」，用户会反复上滑。
///
/// 做法：复刻导航页的真实结构（`extendBody` 语义 = 滚动视图与栏叠放），
/// 滚到最底，断言最后一个卡片的底边在栏的顶边**之上**。
Drama _drama(int i) => Drama(
  id: 'd$i',
  title: '剧目 $i',
  categoryId: 'c',
  categoryName: '都市',
  episodeCount: 24,
  status: DramaStatus.ongoing,
);

void main() {
  testWidgets('海报网格滚到底时最后一行在 Tab 栏之上', (tester) async {
    const barHeight = 104.0; // GlassTabBar.bottom: barHeight 64 + verticalPadding*2
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final items = <Drama>[for (var i = 0; i < 12; i++) _drama(i)];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Builder(
          builder: (context) => Stack(
            children: <Widget>[
              // 页面：滚动视图 + 正确的尾部净空。
              Positioned.fill(
                child: CustomScrollView(
                  slivers: <Widget>[
                    SliverPadding(
                      padding: AppSpacing.pageH,
                      sliver: SliverGrid(
                        gridDelegate: PosterGrid.delegate(),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => PosterLockup(
                            drama: items[index],
                            fill: true,
                            onTap: () {},
                          ),
                          childCount: items.length,
                        ),
                      ),
                    ),
                    const SliverNavBarBottomInset(extra: 0),
                  ],
                ),
              ),
              // 栏（不透明方块占位，只关心几何）。
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: barHeight,
                child: ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 滚到底。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    final lastCard = find.byWidgetPredicate(
      (w) => w is PosterLockup && w.drama.id == 'd11',
    );
    expect(lastCard, findsOneWidget, reason: '最后一个卡片没渲染出来');

    final cardRect = tester.getRect(lastCard);
    final barTop = 844 - barHeight;
    expect(
      cardRect.bottom,
      lessThanOrEqualTo(barTop + 0.5),
      reason: '最后一个卡片底边 ${cardRect.bottom} 落在 Tab 栏顶边 $barTop '
          '之下（被遮住 ${(cardRect.bottom - barTop).toStringAsFixed(1)}pt）',
    );
  });

  testWidgets('净空不足时该断言会失败（证明测试有效）', (tester) async {
    const barHeight = 104.0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final items = <Drama>[for (var i = 0; i < 12; i++) _drama(i)];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Stack(
          children: <Widget>[
            Positioned.fill(
              child: CustomScrollView(
                slivers: <Widget>[
                  SliverPadding(
                    padding: AppSpacing.pageH,
                    sliver: SliverGrid(
                      gridDelegate: PosterGrid.delegate(),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => PosterLockup(
                          drama: items[index],
                          fill: true,
                          onTap: () {},
                        ),
                        childCount: items.length,
                      ),
                    ),
                  ),
                  // 故意只留 32pt（旧版的写法）。
                  const SliverToBoxAdapter(
                    child: SizedBox(height: AppSpacing.xxl),
                  ),
                ],
              ),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: barHeight,
              child: ColoredBox(color: Colors.black),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    final lastCard = find.byWidgetPredicate(
      (w) => w is PosterLockup && w.drama.id == 'd11',
    );
    final cardRect = tester.getRect(lastCard);
    final barTop = 844 - barHeight;
    expect(
      cardRect.bottom,
      greaterThan(barTop),
      reason: '这个反例本该被遮住——若没被遮，说明测试的几何假设不成立',
    );
  });
}
