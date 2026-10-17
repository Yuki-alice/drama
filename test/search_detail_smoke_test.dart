import 'package:drama_app/domain/models/drama.dart';
import 'package:drama_app/ui/features/detail/views/detail_view.dart';
import 'package:drama_app/ui/features/search/views/search_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 搜索页 / 详情页重做后的**渲染冒烟**：两页此前没有任何 widget 测试，
/// 而它们刚经过整页重写（Kazumi 布局 + 海报模糊 + Hero）。这里锁死
/// 「窄屏 / 宽屏都能无异常渲染 + 滚动 + 输入提交全链路」。
///
/// 仓库走 FakeCatalogRepository（`rustCoreProvider` 为 null），不联网。
Drama _drama(String id) => Drama(
  id: id,
  source: 'hongguo',
  title: '命运石之门',
  categoryId: 'real-drama',
  categoryName: '真人短剧',
  episodeCount: 24,
  status: DramaStatus.finished,
  summary:
      '故事发生在「CHAOS;HEAD」的「涩谷崩坏」事件一年半之后的世界，'
      '而舞台则从涩谷转移到了秋叶原。主角冈部伦太郎是一位深度中二病的大学生，'
      '时常幻想自己身肩重任，并自称「狂气的疯狂科学家·凤凰院凶真」。'
      '不过他说到底其作为不过就是在名为「未来道具研究所」中与两个伙伴'
      '开发着奇奇怪怪的东西。',
  tags: const <String>['科幻', '悬疑'],
);

/// 视口 = 逻辑像素（`setSurfaceSize` 不改 `MediaQuery.size`，而两页按它定宽）。
void _useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('详情页冒烟（海报模糊背景 + 截图版式）', () {
    for (final size in const <Size>[Size(390, 844), Size(1100, 800)]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 渲染 + 滚动无异常', (
        tester,
      ) async {
        _useViewport(tester, size);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: DetailView(id: 'd001', initial: _drama('d001')),
            ),
          ),
        );
        // 首帧：卡片数据在，先渲染海报头（Hero 落点）。
        await tester.pump();
        expect(tester.takeException(), isNull);
        // 数据到达后：选集 / 简介 / 题材落位。
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        // 滚动一屏：模糊背景与固定顶栏不得报错。
        await tester.drag(find.byType(ListView).first, const Offset(0, -500));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('搜索页冒烟（筛选优先，无热门趋势）', () {
    testWidgets('引导态 → 输入联想 → 提交结果全链路无异常', (tester) async {
      _useViewport(tester, const Size(390, 844));

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: SearchView())),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      // 输入：走防抖 → 联想态（未提交）。
      await tester.enterText(find.byType(EditableText), '命运');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      // 点「搜索「命运」」行：提交 → 结果态（网格或空态）。
      await tester.tap(find.text('搜索「命运」'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });

    testWidgets('1100×720 宽屏渲染无异常', (tester) async {
      _useViewport(tester, const Size(1100, 720));

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: SearchView())),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });
}
