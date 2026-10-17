import 'package:drama_app/domain/models/drama.dart';
import 'package:drama_app/ui/core/theme/app_theme.dart';
import 'package:drama_app/ui/core/widgets/app_nav_bar.dart';
import 'package:drama_app/ui/core/widgets/lockups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内容出血到浮起玻璃栏之下时，**最后一行不得被栏永久遮住**。
///
/// 这类缺陷只在「滚到底」时才暴露，手测极易漏掉：栏是半透明的，
/// 被遮住的最后一行看起来「像是还没滚完」，用户会反复上滑。
///
/// 做法：复刻导航页的真实结构（滚动视图铺满整屏、栏浮在其上），
/// 滚到最底，断言最后一个卡片的底边在栏的顶边**之上**。
Drama _drama(int i) => Drama(
  id: 'd$i',
  title: '剧目 $i',
  categoryId: 'c',
  categoryName: '都市',
  episodeCount: 24,
  status: DramaStatus.ongoing,
);

/// 浮起 Tab 条占掉的底边高度：距底 16 + 条高 60。
const double _kTabBarTopFromBottom = 16 + 60;

/// 把视口设成 390×844（**逻辑像素**）。
///
/// 注意：`binding.setSurfaceSize` 只改渲染面，**不改 `MediaQuery.size`**
/// （后者来自 View 的 physicalSize / dpr），而页面按 `MediaQuery` 判档位——
/// 两者必须一致，所以这里直接设 `tester.view`。
void _useCompactViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('海报网格滚到底时最后一行在浮起 Tab 条之上', (tester) async {
    const screenHeight = 844.0;
    _useCompactViewport(tester);

    // 30 部 → 10 行，内容远高于视口，才能真的滚到底。
    final items = <Drama>[for (var i = 0; i < 30; i++) _drama(i)];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Builder(
          builder: (context) => Stack(
            children: <Widget>[
              // 页面：滚动视图 + 正确的尾部净空（96 + 安全区）。
              Positioned.fill(
                child: CustomScrollView(
                  slivers: <Widget>[
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverGrid(
                        gridDelegate: FeedGrid.delegate(390 - 32),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => DramaPosterCard(
                            drama: items[index],
                            onTap: () {},
                          ),
                          childCount: items.length,
                        ),
                      ),
                    ),
                    const SliverNavBarBottomInset(),
                  ],
                ),
              ),
              // 栏（不透明方块占位，只关心几何）。
              const Positioned(
                left: AppBottomNavBar.sideInset,
                right: AppBottomNavBar.sideInset,
                bottom: AppBottomNavBar.bottomInset,
                height: AppBottomNavBar.height,
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
      (w) => w is DramaPosterCard && w.drama.id == 'd29',
    );
    expect(lastCard, findsOneWidget, reason: '最后一个卡片没渲染出来');

    final cardRect = tester.getRect(lastCard);
    final barTop = screenHeight - _kTabBarTopFromBottom;
    expect(
      cardRect.bottom,
      lessThanOrEqualTo(barTop + 0.5),
      reason:
          '最后一个卡片底边 ${cardRect.bottom} 落在 Tab 条顶边 $barTop '
          '之下（被遮住 ${(cardRect.bottom - barTop).toStringAsFixed(1)}pt）',
    );
  });

  testWidgets('净空不足时该断言会失败（证明测试有效）', (tester) async {
    const screenHeight = 844.0;
    _useCompactViewport(tester);

    // 30 部 → 10 行，内容远高于视口，才能真的滚到底。
    final items = <Drama>[for (var i = 0; i < 30; i++) _drama(i)];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Stack(
          children: <Widget>[
            Positioned.fill(
              child: CustomScrollView(
                slivers: <Widget>[
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverGrid(
                      gridDelegate: FeedGrid.delegate(390 - 32),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) =>
                            DramaPosterCard(drama: items[index], onTap: () {}),
                        childCount: items.length,
                      ),
                    ),
                  ),
                  // 故意只留 32pt（旧版的写法）——不足以让开浮起的栏。
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ),
            ),
            const Positioned(
              left: AppBottomNavBar.sideInset,
              right: AppBottomNavBar.sideInset,
              bottom: AppBottomNavBar.bottomInset,
              height: AppBottomNavBar.height,
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
      (w) => w is DramaPosterCard && w.drama.id == 'd29',
    );
    final cardRect = tester.getRect(lastCard);
    final barTop = screenHeight - _kTabBarTopFromBottom;
    expect(
      cardRect.bottom,
      greaterThan(barTop),
      reason: '这个反例本该被遮住——若没被遮，说明测试的几何假设不成立',
    );
  });
}
