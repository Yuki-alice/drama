import 'package:flutter/material.dart';

/// 设计 token —— **无彩色界面 + 封面取色**。
///
/// 界面色板只有黑 / 白 / 两级灰 / 发丝线 / 浅雾：**没有任何强调色**。
/// 颜色的唯一来源是封面——详情页与播放器的氛围色从封面主色提取
/// （见 `cover_palette.dart`），界面本体永远不带色相。
///
/// 为什么去掉上一版的标志绿 `#10A37F`：三轮视觉重做都在改色板，而不满意感
/// 没有消失。色板自 `docs/DESIGN_CONSTITUTION.md` 起冻结为无彩色，
/// 版式承载层级，颜色只由内容（封面）提供。
///
/// **三种颜色角色的纪律**：
///
/// - **墨（[textPrimary]）——正文与唯一的重型填充**：填充时配 [onInk]
///   （浅色黑底白字 / 深色亮底近黑字）。主操作是墨色胶囊，没有彩色按钮；
/// - **石墨（[textSecondary]）——次级文字与一切需要读的元信息**；
/// - **银灰（[textTertiary]）——装饰性元信息**（浅色端不到 4.5:1，见下表）。
///
/// **状态与进度用灰度与字重表达**，不使用彩色：选中=墨色填充 / 加粗，
/// 进度=墨色（画面之上用白），未选中=石墨。
///
/// 玻璃只出现在功能层（Tab 栏 / 顶栏控件 / 搜索 / 侧栏 / 播放器控件）；
/// 内容层（海报 / 画面）保持不透明。
///
/// **对比度**（WCAG，实算值，改动任一色值前请重算）：
///
/// | 前景 | 底 | 值 |
/// |---|---|---|
/// | ink `#0F0F0F` | 纸白 `#FFFFFF` | 19.2:1 |
/// | ink `#0F0F0F` | 浅雾 `#F7F7F8` | 17.9:1 |
/// | graphite `#6E6E80` | 纸白 `#FFFFFF` | 4.99:1 |
/// | graphite `#6E6E80` | 浅雾 `#F7F7F8` | 4.66:1 |
/// | silver `#8F8F8F` | 纸白 `#FFFFFF` | **3.24:1**（装饰级） |
/// | silver `#8F8F8F` | 浅雾 `#F7F7F8` | **3.02:1**（装饰级） |
/// | 反白 `#FFFFFF` | 墨底 `#0F0F0F` | 19.2:1 |
/// | ink `#ECECEC` | 炭底 `#1C1C1E` | 14.4:1 |
/// | ink `#ECECEC` | 浅雾 `#171717` | 15.2:1 |
/// | graphite `#B4B4B4` | 炭底 `#1C1C1E` | 8.21:1 |
/// | graphite `#B4B4B4` | 列表卡 `#232325` | 7.57:1 |
/// | silver `#8E8E8E` | 炭底 `#1C1C1E` | 5.19:1 |
/// | 近黑 `#101010` | 亮面 `#ECECEC` | 16.1:1 |
///
/// 三条使用纪律（都来自上表）：
///
/// 1. **[textTertiary] 浅色端不到 4.5:1**（3.24）——只能承载装饰性文字、
///    已被别处重复表达过的信息；**深色端 5.19 达标**，两端不对称是正常现象。
///    凡用户真的需要读到的（集数、时长、更新时间、状态）一律用
///    [textSecondary]。
/// 2. **发丝线（[divider]）只用于分隔**，不得作为唯一的状态信号；
///    选中态必须同时有填充或字重变化。
/// 3. **界面不得出现色相**——需要「强调」时加字重、加填充、加面积，
///    不得引入颜色。需要颜色时那是封面的事。
///
/// 作为 [ThemeExtension] 挂在 `ThemeData.extensions` 上：`AppColors.of(context)`
/// 与 Material 组件读到的是**同一份**取值，高对比开关也一并携带。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors(this.brightness, {this.highContrast = false});

  final Brightness brightness;

  /// 高对比（HIG `accessibility.md`：Increase Contrast 需显著加大差异）。
  final bool highContrast;

  bool get _dark => brightness == Brightness.dark;

  // ── 底面（canvas / 面 / 雾） ─────────────────────────────────────

  /// 页面底色：浅色纯白；深色炭底 `#1C1C1E`（播放器场景另用纯黑）。
  Color get background =>
      _dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF);

  /// 沉浸式媒体底（播放器整屏）。固定纯黑，不随外观变化。
  Color get mediaBackground => const Color(0xFF000000);

  /// **列表卡面**（我的页的分组卡）：比画布深一档的浅雾圆角卡。
  ///
  /// 浅色 `#F7F7F8`、深色 `#232325`——「我的」页的分组块即此档。
  Color get contentSurface =>
      _dark ? const Color(0xFF232325) : const Color(0xFFF7F7F8);

  /// 更高一层（图标方格 / 弹层 / 抽屉）。
  ///
  /// 浅色纯白（比 [contentSurface] 亮，形成「格子在卡上浮起」），
  /// 深色 `#3A3A3C`。
  Color get surfaceElevated =>
      _dark ? const Color(0xFF3A3A3C) : const Color(0xFFFFFFFF);

  /// 内陷面「浅雾」：输入槽 / 凹陷面 / 头像底 / 进度轨道底 / 圆钮底。
  ///
  /// 浅色 `#F7F7F8`；深色 `#171717`（比画布更深——凹陷用「更深」表达）。
  Color get sunken => _dark ? const Color(0xFF171717) : const Color(0xFFF7F7F8);

  /// 选中 / 悬停的**中性**填充（侧栏选中行 / 列表行按下）。
  ///
  /// 无彩色色板下没有「选中色」可用，选中靠这块浅雾底 + 字重加粗表达。
  Color get selectionFill =>
      _dark ? const Color(0xFF2C2C2E) : const Color(0xFFF0F0F2);

  // ── 前景（ink / graphite / silver 三级） ────────────────────────

  /// 墨黑：正文、标题、**唯一的重型填充**（主操作 / 选中格，配 [onInk]）。
  Color get textPrimary => _dark
      ? const Color(0xFFECECEC)
      : (highContrast ? const Color(0xFF000000) : const Color(0xFF0F0F0F));

  /// 石墨：次级文字、未选中图标、以及**一切需要读的元信息**。
  ///
  /// 纸白 4.99:1、浅雾 4.66:1、深色炭底 8.21:1——三个底都过线，可承载正文。
  Color get textSecondary => _dark
      ? const Color(0xFFB4B4B4)
      : (highContrast ? const Color(0xFF3F3F4A) : const Color(0xFF6E6E80));

  /// 银灰：三级文字 / 装饰性元信息。**浅色端不足 4.5:1**（3.24），
  /// 深色端 5.19 达标——浅色端勿承载关键信息（见类注释的对比度表）。
  Color get textTertiary =>
      _dark ? const Color(0xFF8E8E8E) : const Color(0xFF8F8F8F);

  /// 不可用态（HIG：disabled 需明显弱于三级，但仍可辨）。
  Color get textDisabled =>
      _dark ? const Color(0xFF565656) : const Color(0xFFC9C9C9);

  /// 墨色重型填充（[textPrimary] 实心块：主按钮 / 选中格）之上的前景。
  ///
  /// 浅色墨底配白、深色亮底配近黑——与 [textPrimary] 成对使用。
  Color get onInk => _dark ? const Color(0xFF101010) : const Color(0xFFFFFFFF);

  /// 发丝线（分隔线 / 描边 / 发丝进度轨道）。
  Color get divider => _dark
      ? const Color(0xFF38383A)
      : (highContrast ? const Color(0xFFB0B0B0) : const Color(0xFFE5E5E5));

  /// 更明显的边界（输入框 / 选中卡描边 / 玻璃镜片描边）。
  ///
  /// 与 [divider] 一样**响应高对比**：边界的可辨识度是「Increase Contrast」
  /// 的主要诉求之一。
  Color get borderStrong => _dark
      ? (highContrast ? const Color(0xFF6E6E6E) : const Color(0xFF4F4F4F))
      : (highContrast ? const Color(0xFF8A8A8A) : const Color(0xFFCFCFCF));

  /// 封面 / 海报加载前的占位底（不透明）。
  Color get posterFallback =>
      _dark ? const Color(0xFF2A2A2A) : const Color(0xFFF0F0F0);

  // ── 画面之上（播放器 / 出血 Hero） ──────────────────────────────

  /// 覆盖在图片/视频上的 scrim（保证其上白字可读）。
  Color get mediaScrim => const Color(0x99000000);

  /// 画面之上的前景（播放器控制层永远坐在视频上，不读 [textPrimary]）。
  Color get onMedia => const Color(0xFFFFFFFF);

  /// 画面之上的弱化前景（集号、时间戳）。
  Color get onMediaSecondary => const Color(0xCCFFFFFF);

  /// 画面之上的三级前景（次要标的、提示语）。
  Color get onMediaTertiary => const Color(0x8FFFFFFF);

  /// 画面之上的发丝线底轨（进度条未走完的一段）。
  Color get hairlineTrack => const Color(0x40FFFFFF);

  /// 从当前 [Theme] 解析色板；主题未挂扩展时按亮度兜底。
  static AppColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppColors>() ?? AppColors(theme.brightness);
  }

  @override
  AppColors copyWith({Brightness? brightness, bool? highContrast}) => AppColors(
    brightness ?? this.brightness,
    highContrast: highContrast ?? this.highContrast,
  );

  /// 两个亮度档之间**逐字段插值**。
  ///
  /// Material 在 `AnimatedTheme` 里以 200ms 调用它，玻璃与内容随之连续
  /// 迁移而不是跳变。高对比是**开关**不是连续量：过半即取目标侧。
  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    if (t <= 0) return this;
    if (t >= 1) return other;
    return AppColors(
      t < 0.5 ? brightness : other.brightness,
      highContrast: t < 0.5 ? highContrast : other.highContrast,
    );
  }
}

/// 间距刻度（4pt 栅格）。
///
/// 区块之间靠**空白**分组，而不是靠分隔线与卡片边框
/// （HIG `layout.md`：用负空间表达相关性）。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// 页面左右边距（compact 档 / 手机）。
  ///
  /// **档位相关的数字只住在 `breakpoints.dart`**（gutter 三档、侧栏两档、
  /// 网格上限、列数公式），这里只留与档位无关的刻度——两处各写一份必然漂移。
  static const double gutter = 16;

  /// 列表类内容的最大宽度（「一行一件事」：榜单 / 追剧）。超出即居中留白。
  static const double listMaxWidth = 760;

  /// 浮起玻璃侧栏的外缩（左 / 上 / 下）——侧栏是一片浮起的玻璃，不贴屏幕边。
  /// 占位（含与内容之间的间距）见 `Breakpoints.railPlaceholder`。
  static const double railInset = 12;

  /// 触控目标下限（HIG `accessibility.md`：移动端默认 44×44 pt）。
  static const double minTapTarget = 44;

  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: gutter);
}

/// 圆角刻度（连续曲率）。
///
/// 曲线一律走 [shape]（`RoundedSuperellipseBorder`），玻璃面用包内建的
/// `LiquidRoundedSuperellipse`——两者底层是同一个曲率模型。
abstract final class AppRadii {
  static const double xs = 4;

  /// 缩略图（榜单行 / 追剧行的小封面）。
  static const double thumbnail = 10;

  static const double sm = 8;
  static const double md = 12;

  /// 内容卡（封面卡 / 选集格 / 分组卡）。
  static const double lg = 14;

  /// 大内容卡（Hero / 搜索槽…）。
  static const double xl = 18;

  /// 浮起玻璃片（侧栏）。
  static const double rail = 26;

  /// 最大一档内容圆角。
  static const double xxl = 22;

  /// 弹层（sheet / dialog / 抽屉）。
  static const double sheet = 28;

  /// 胶囊（stadium）。
  static const double capsule = 9999;

  /// 内容层的连续曲率边框。
  static ShapeBorder shape(double radius) =>
      RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

  /// 内容层的连续曲率裁切（封面 / 图块用）。
  static Widget clip({
    required double radius,
    required Widget child,
    Clip clipBehavior = Clip.antiAlias,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    clipBehavior: clipBehavior,
    child: child,
  );
}

/// 字体刻度。
///
/// 沿用系统字体（HIG `typography.md`：导航与控件用系统字体最稳妥），
/// 层级靠**字号 + 字重 + 颜色**三重表达，不引入第二字族作为界面字体。
/// 唯一的例外是 [mono]：数字与元信息（集号、热度、时间码、倍速、序号、
/// `EP 60`、`1080P`）走等宽，让纵向数字天然对齐、读数不跳动。
///
/// 字号均 ≥ 11（HIG 移动端最小 11pt）。
abstract final class AppText {
  static const TextStyle display = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    height: 1.15,
    letterSpacing: -0.5,
  );

  /// 页面固定顶栏标题（19px；桌面档放大到 22，见 `FixedTopBar`）。
  static const TextStyle barTitle = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -0.4,
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

  /// 等宽字族候选。
  ///
  /// 按平台可用性排序：Apple 平台命中 SF Mono / Menlo，Android 命中
  /// Roboto Mono，其余落到通用 `monospace`。不打包字体文件。
  static const String monoFamily = 'SF Mono';
  static const List<String> monoFallback = <String>[
    'Menlo',
    'JetBrains Mono',
    'Roboto Mono',
    'DejaVu Sans Mono',
    'monospace',
  ];

  /// 等宽数字样式基座（集号 / 时间码 / 倍速 / 清晰度）。
  ///
  /// `tabularFigures` 让同一段文字换数字时宽度不跳。
  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.35,
    letterSpacing: 0.2,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 榜单大号码（「数字即视觉」的一档：27px 等宽粗体）。
  static const TextStyle numeral = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 27,
    fontWeight: FontWeight.w700,
    height: 1.0,
    letterSpacing: -1.5,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 大号等宽数字（「我的」页统计值：22px）。
  static const TextStyle stat = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.6,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}

/// 动效时长与曲线（HIG `motion.md`：克制、短暂、可取消）。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);

  /// 页面背景随内容主视觉迁移的时长。刻意比控件动效慢一个量级——
  /// 背景是「氛围」，快了会像故障闪色。
  static const Duration backdrop = Duration(milliseconds: 600);

  static const Curve standard = Curves.easeInOutCubic;

  /// 落位曲线（进场 / 按起）：起步快、收尾慢。
  static const Curve settle = Curves.easeOutCubic;

  /// 播放器控件自动收起的空闲时长。
  static const Duration chromeIdle = Duration(milliseconds: 3500);
}
