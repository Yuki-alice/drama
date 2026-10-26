import 'package:flutter/widgets.dart';

/// 全局断点体系：compact < 600（手机竖屏）、medium 600–839、expanded >= 840。
/// 与 Animeko 的 NavigationSuite 判定一致：非 compact 使用侧栏导航。
enum AppWindowType { compact, medium, expanded }

extension AppWindowTypeX on AppWindowType {
  bool get isCompact => this == AppWindowType.compact;
  bool get isExpanded => this == AppWindowType.expanded;

  /// 非紧凑宽度使用 NavigationRail，紧凑宽度使用底部 NavigationBar。
  bool get useNavigationRail => !isCompact;

  /// 海报网格列数：3 → 4 → 5，超宽再增。
  int gridColumns(double width) => switch (this) {
    AppWindowType.compact => 3,
    AppWindowType.medium => width >= 1000 ? 5 : 4,
    AppWindowType.expanded => width >= 1500 ? 6 : 5,
  };

  /// 页面横向留白。
  double get pagePadding => switch (this) {
    AppWindowType.compact => 16,
    AppWindowType.medium => 24,
    AppWindowType.expanded => 32,
  };
}

AppWindowType windowTypeOf(double width) {
  if (width < 600) return AppWindowType.compact;
  if (width < 840) return AppWindowType.medium;
  return AppWindowType.expanded;
}

/// 直接以当前窗口宽度取断点，避免各屏重复拼装 MediaQuery。
AppWindowType windowTypeOfContext(BuildContext context) =>
    windowTypeOf(MediaQuery.sizeOf(context).width);
