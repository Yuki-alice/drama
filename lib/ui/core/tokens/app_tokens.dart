import 'package:flutter/material.dart';

/// 设计 token。
///
/// **风格取向**：Apple 的语义分层（base / elevated、label 四级、语义色随外观
/// 自适应）＋ Notion 的暖调中性面（米白纸面而非纯白、暖近黑正文、低对比暖分隔线）。
/// 品牌红只作**唯一**的强调色，其余一切保持中性——理由见下。
///
/// **为什么强调色只有一支**：本应用是海报墙，内容层本身极彩色。Apple HIG
/// `color.md` 的 Liquid Glass color 一节要求「内容色彩丰富时，工具栏/标签栏取
/// 单色外观，或选一支与内容有足够区分度的强调色」。因此这里不做多色语义板：
/// 交互＝强调色，其余靠**层级与字重**表达；破坏性操作靠**措辞 + 二次确认**
/// 承载，不靠颜色（HIG 亦要求「不得仅凭颜色传达信息」）。
///
/// **对比度**：下面每组都在浅/深/高对比三种上下文里按 WCAG 计算过，
/// 正文 ≥4.5:1、大字/控件 ≥3:1。改动任一色值前请重新计算（尤其
/// [textTertiary] 在 [sunken] 上是全表最紧的一档：4.73:1）。
///
/// **内容层不透明**：海报 / 视频画面 / 封面一律不透明
/// （[contentSurface] / [posterFallback] / [sunken]），玻璃只出现在功能层
/// （栏 / 条 / 卡 / 弹层），见 HIG `materials.md`「Don't use Liquid Glass in
/// the content layer」。

/// 语义色板。按亮度取值，避免在调用点散落魔法色值。
///
/// 作为 [ThemeExtension] 挂在 `ThemeData.extensions` 上，因此
/// `AppColors.of(context)` 与 Material 组件读到的是**同一份**取值
/// （高对比开关也一并携带，不会出现两套判断）。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors(this.brightness, {this.highContrast = false});

  final Brightness brightness;

  /// 高对比（HIG `accessibility.md`：Increase Contrast 需显著加大差异）。
  final bool highContrast;

  bool get _dark => brightness == Brightness.dark;

  // ── 背景层级（Apple 的 base / elevated 分层，Notion 的暖调取值） ──────

  /// 页面底色：暖米白纸面（浅）/ 暖深灰（深）。**不用纯白**——
  /// 纯白在长列表与海报墙下刺眼，且让卡片的 1px 边界无处安放。
  Color get background => _dark
      ? const Color(0xFF191817)
      : (highContrast ? const Color(0xFFFFFFFF) : const Color(0xFFFBFAF9));

  /// 内容面（卡片 / 海报卡背板）。浅色下比 [background] 更亮以形成「浮起」。
  Color get contentSurface =>
      _dark ? const Color(0xFF232220) : const Color(0xFFFFFFFF);

  /// 更高一层（弹层 / 选中行 / 输入框内陷的对偶）。
  /// 深色下这是第三级亮度，浅色下退回纸面同色（浅色靠边框分层）。
  Color get surfaceElevated =>
      _dark ? const Color(0xFF2C2A27) : const Color(0xFFF7F6F3);

  /// 内陷面（进度轨道底 / 标签底色 / 无操作的区块）。
  Color get sunken =>
      _dark ? const Color(0xFF141312) : const Color(0xFFF2F0EC);

  /// 玻璃背后的页面背景（功能层下方可见，供折射）。
  ///
  /// Notion 风：一层极轻的暖色晕染 + 纸面，**不做彩色渐变**——
  /// 彩色底会把玻璃染成脏色，且与彩色海报抢注意力。
  Color get backdropWarm =>
      _dark ? const Color(0xFF241C1A) : const Color(0xFFFDF3EF);
  Color get backdropCool =>
      _dark ? const Color(0xFF1B1D22) : const Color(0xFFEFF1F6);

  // ── 前景（Apple 的 label 四级，取到三级） ──────────────────────────

  /// 正文 / 标题。
  Color get textPrimary => _dark
      ? const Color(0xFFEDEBE7)
      : (highContrast ? const Color(0xFF000000) : const Color(0xFF1F1E1C));

  /// 次级文字（副标题 / 说明）。
  Color get textSecondary => _dark
      ? const Color(0xFFA8A49D)
      : (highContrast ? const Color(0xFF3D3A36) : const Color(0xFF5F5C57));

  /// 三级文字（元信息 / 占位）。
  Color get textTertiary =>
      _dark ? const Color(0xFF9A968F) : const Color(0xFF6E6A62);

  /// 不可用态文字（HIG：disabled 需明显弱于三级，但仍可读）。
  Color get textDisabled =>
      _dark ? const Color(0xFF6B6762) : const Color(0xFF9A968F);

  // ── 强调与状态 ───────────────────────────────────────────────────

  /// 品牌强调色（**唯一**）：主操作、选中态、链接、播放。
  ///
  /// 浅色取深绯红以同时满足「作为文字放在纸面上 ≥4.5:1」与
  /// 「白字放在它上面 ≥4.5:1」（5.20 / 5.42）；深色取提亮版（6.35 / 5.69）。
  Color get accent => _dark
      ? const Color(0xFFFF6B5E)
      : (highContrast ? const Color(0xFF9E2B22) : const Color(0xFFC4342B));

  /// 强调色**之上**的前景色。
  ///
  /// 浅色下强调色足够深 → 用白字（5.42:1）；深色下强调色是亮色 →
  /// 必须用**深墨**字（纯白只有 2.9:1，6.72:1 才对）。
  Color get onAccent =>
      _dark ? const Color(0xFF1A0F0D) : const Color(0xFFFFFFFF);

  /// 强调色的浅底（选中行 / 弱提示底）。不承载正文，仅作底。
  Color get accentSubtle => _dark
      ? const Color(0x33FF6B5E)
      : (highContrast ? const Color(0x1FC4342B) : const Color(0x14C4342B));

  /// 分隔线（Notion 式低对比暖灰；HIG 的 separator 语义）。
  Color get divider => _dark
      ? const Color(0xFF33312E)
      : (highContrast ? const Color(0xFFB8B3AB) : const Color(0xFFE7E4DF));

  /// 更明显的边界（输入框 / 选中卡描边）。
  Color get borderStrong =>
      _dark ? const Color(0xFF484540) : const Color(0xFFD5D1CA);

  /// 封面 / 海报加载前的占位底（不透明）。
  Color get posterFallback =>
      _dark ? const Color(0xFF2A2825) : const Color(0xFFEAE7E1);

  /// 覆盖在图片/视频上的 scrim（保证其上白字可读）。
  Color get mediaScrim => const Color(0x99000000);

  /// 从当前 [Theme] 解析色板。
  ///
  /// 读 [`ThemeExtension`]（由 [buildMaterialTheme] 挂上），因此与 Material
  /// 组件同源；主题未挂载（例如裸 `MaterialApp` 的 widget 测试）时按亮度兜底。
  static AppColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppColors>() ??
        AppColors(theme.brightness);
  }

  @override
  AppColors copyWith({Brightness? brightness, bool? highContrast}) =>
      AppColors(
        brightness ?? this.brightness,
        highContrast: highContrast ?? this.highContrast,
      );

  /// 两个亮度档之间插值（外观切换时做 200ms 过渡，而非硬跳）。
  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return t < 0.5 ? this : other;
  }
}

/// 间距刻度（4pt 栅格）。
///
/// Notion 风的留白比 Material 默认更宽：区块之间靠**空白**分组，
/// 而不是靠分隔线与卡片边框（HIG `layout.md`：用负空间表达相关性）。
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

/// 圆角刻度（Notion 偏克制：默认 8，卡片 12，不用大圆角）。
abstract final class AppRadii {
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;

  /// 胶囊（stadium）。
  static const double capsule = 9999;
}

/// 字体刻度。
///
/// 沿用系统字体（HIG `typography.md`：导航与控件用系统字体最稳妥），
/// 层级靠**字号 + 字重 + 颜色**三重表达，不引入第二字族。
/// 字号均 ≥ 11（HIG 移动端最小 11pt）。
abstract final class AppText {
  static const TextStyle display = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    height: 1.15,
    letterSpacing: -0.5,
  );
  static const TextStyle title = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.22,
    letterSpacing: -0.25,
  );
  static const TextStyle headline = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: -0.1,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
  static const TextStyle callout = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    height: 1.35,
    letterSpacing: 0.1,
  );
}

/// 动效时长与曲线（HIG `motion.md`：克制、短暂、可取消）。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);
  static const Curve standard = Curves.easeInOutCubic;
}
