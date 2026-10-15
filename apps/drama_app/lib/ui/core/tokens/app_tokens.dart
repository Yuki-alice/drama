import 'package:flutter/material.dart';

/// 设计 token（ARCH §4.1）。
///
/// 纪律一「内容层不透明」：海报墙 / 视频画面 / 封面一律用不透明色
/// （[AppColors.contentSurface] / [AppColors.posterFallback]），玻璃只出现在
/// 功能层（栏 / 条 / 卡 / 弹层）。

/// 语义色板。按亮度取值，避免在调用点散落魔法色值。
@immutable
class AppColors {
  const AppColors(this.brightness);

  final Brightness brightness;

  bool get _dark => brightness == Brightness.dark;

  /// 页面底色（玻璃背后的主背景，由 [AppBackdrop] 加渐变）。
  Color get background =>
      _dark ? const Color(0xFF0B0B10) : const Color(0xFFF3F4F8);

  /// 背景渐变的两端（为玻璃提供可折射的色彩）。
  Color get backdropWarm =>
      _dark ? const Color(0xFF2A1220) : const Color(0xFFFFE3DE);
  Color get backdropCool =>
      _dark ? const Color(0xFF101724) : const Color(0xFFE2ECFF);

  /// 内容层底色（不透明）。
  Color get contentSurface =>
      _dark ? const Color(0xFF15151C) : const Color(0xFFFFFFFF);

  /// 正文色。
  Color get textPrimary =>
      _dark ? const Color(0xFFF5F5F7) : const Color(0xFF14141A);

  /// 次级文字。
  Color get textSecondary =>
      _dark ? const Color(0xB8EBEBF5) : const Color(0x99000000);

  /// 三级文字 / 占位。
  Color get textTertiary =>
      _dark ? const Color(0x7AEBEBF5) : const Color(0x61000000);

  /// 品牌强调色（播放 / 追剧 / 选中态）。
  Color get accent => _dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);

  /// 强调色上的前景色。
  Color get onAccent => const Color(0xFFFFFFFF);

  /// 分隔线。
  Color get divider =>
      _dark ? const Color(0x24FFFFFF) : const Color(0x1F000000);

  /// 封面占位底色。
  Color get posterFallback =>
      _dark ? const Color(0xFF23232E) : const Color(0xFFE3E5EC);

  /// 从当前 [Theme] 解析色板。
  static AppColors of(BuildContext context) =>
      AppColors(Theme.of(context).brightness);
}

/// 间距刻度（4pt 栅格）。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// 页面左右边距。
  static const double gutter = 16;

  /// 大屏内容最大宽度（防拉伸），见 [ContentWidthConstraint]。
  static const double maxContentWidth = 960;

  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: gutter);
  static const EdgeInsets card = EdgeInsets.all(lg);
}

/// 圆角刻度。
abstract final class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;

  /// 胶囊（stadium）。
  static const double capsule = 9999;
}

/// 字体刻度。
abstract final class AppText {
  static const TextStyle display = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.15,
    letterSpacing: -0.6,
  );
  static const TextStyle title = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -0.3,
  );
  static const TextStyle headline = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );
  static const TextStyle callout = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0.2,
  );
}

/// 动效时长与曲线。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve standard = Curves.easeInOutCubic;
}
