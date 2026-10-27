import 'package:duanju_app/features/player/picture_in_picture_controller.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 记录每次可见性回调，用于断言暂停时序。
  ({PictureInPictureController controller, List<bool> calls}) build() {
    final calls = <bool>[];
    final controller = PictureInPictureController(
      onVisibilityChanged: ({required bool delayHiddenPause}) =>
          calls.add(delayHiddenPause),
      exitGrace: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);
    return (controller: controller, calls: calls);
  }

  test('默认状态不可用，也不可见', () {
    final (:controller, :calls) = build();
    expect(controller.supported, isFalse);
    expect(controller.active, isFalse);
    expect(controller.visible, isFalse);
    expect(controller.canUse, isFalse, reason: '平台未上报支持时不显示入口');
  });

  test('active 为真时自动清掉 requested', () {
    final (:controller, calls: calls) = build();
    controller.updateStatus(supported: true, requested: true);
    expect(controller.requested, isTrue);
    expect(controller.visible, isTrue);
    calls.clear();

    controller.updateStatus(active: true);
    expect(controller.active, isTrue);
    expect(controller.requested, isFalse, reason: '已生效就不该再标记待确认');
    expect(controller.visible, isTrue);
  });

  test('退出后延迟回调标记 delayHiddenPause', () async {
    final (:controller, calls: calls) = build();
    controller.updateStatus(supported: true, active: true);
    calls.clear();

    // 系统上报退出：先立刻回调一次"不要立即暂停"，再在 grace 后复查。
    controller.updateStatus(active: false, delayHiddenPause: true);
    expect(calls.first, isTrue);
    expect(controller.visible, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls.last, isTrue, reason: '延迟复查仍应带上延迟标记');
  });

  test('进入画中画期间不触发暂停', () {
    final (:controller, calls: calls) = build();
    controller.updateStatus(supported: true, active: true);
    calls.clear();

    // 期间的状态刷新（例如旋转）应保持"不暂停"。
    controller.updateStatus(supported: true);
    expect(calls, everyElement(isFalse));
  });

  test('状态未变化时仍然回调，让屏幕重新评估可见性', () {
    final (:controller, calls: calls) = build();
    controller.updateStatus(supported: true, active: true);
    final before = calls.length;

    controller.updateStatus(supported: true, active: true);
    expect(
      calls.length,
      greaterThan(before),
      reason: '前后台切换时状态可能没变，但可见性需要重新计算',
    );
  });
}
