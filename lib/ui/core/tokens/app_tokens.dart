import 'package:flutter/material.dart';

/// 设计 token —— 「ChatGPT 双色 · 玻璃」：OpenAI 灰阶 + 一支标志绿。
///
/// **为什么引入绿色**：上一版是纯中性黑白（零彩色强调）——克制但无辨识度。
/// 本版整体对齐 OpenAI / ChatGPT 的产品色板：灰阶全套取 ChatGPT 的色号
/// （浅色端 `#FFFFFF / #F7F7F8 / #E5E5E5`；深色端 `#212121 / #2F2F2F / #171717`），
/// 并引入标志绿 `#10A37F` 作为全站**唯一彩色**。绿色的分工沿用 ChatGPT 的
/// 实际用法——**只表达状态与进程**：进度、加载、开关、焦点、选中标记、徽章、
/// 链接。海报墙的理由仍然成立：绿色只落在小面积的功能元素上，不与剧照抢
/// 注意力；主操作仍是墨色胶囊（与现行 ChatGPT 的黑色主按钮同构），
/// 重型填充（主按钮 / 选中格 / 反色块）继续用墨与白。
///
/// **三种颜色角色的纪律**：
///
/// - **墨（[textPrimary]）——正文与重型填充**：填充时配 [onInk]
///   （浅色黑底白字 / 深色亮底近黑字）；
/// - **绿（[accent] / [accentDeep]）——状态与进程**：图形级绿用 [accent]；
///   凡承载小号文字的绿（链接、徽章、选中胶囊文字）一律用 [accentDeep]；
/// - **灰（[textSecondary] / [textTertiary]）——承载文字的两级灰**。
///
/// 玻璃只出现在功能层（Tab 栏 / 顶栏控件 / 搜索 / 侧栏 / 播放器控件）；
/// 破坏性操作靠**措辞 + 二次确认**承载，不引入第三支颜色。
///
/// **对比度**（WCAG，实算值，改动任一色值前请重算）：
///
/// | 前景 | 底 | 值 |
/// |---|---|---|
/// | ink `#0F0F0F` | 纸白 `#FFFFFF` | 19.2:1 |
/// | ink `#0F0F0F` | 浅雾 `#F7F7F8` | 17.9:1 |
/// | graphite `#6E6E80` | 纸白 `#FFFFFF` | 4.99:1 |
/// | graphite `#6E6E80` | 浅雾 `#F7F7F8` | 4.66:1 |
/// | silver `#8F8F8F` | 纸白 `#FFFFFF` | **3.23:1** |
/// | green `#10A37F` | 纸白 `#FFFFFF` | **3.20:1** |
/// | greenDeep `#0B7A61` | 纸白 `#FFFFFF` | 5.29:1 |
/// | 反白 `#FFFFFF` | 绿 `#10A37F` | **3.20:1** |
/// | 反白 `#FFFFFF` | 墨底 `#0F0F0F` | 19.2:1 |
/// | label `#ECECEC` | canvas `#212121` | 13.6:1 |
/// | graphite `#B4B4B4` | canvas `#212121` | 7.77:1 |
/// | silver `#8E8E8E` | canvas `#212121` | 4.91:1 |
/// | green `#10A37F` | canvas `#212121` | 5.04:1 |
/// | greenDeep `#19C37D` | canvas `#212121` | 7.01:1 |
/// | 墨反 `#101010` | 亮面 `#ECECEC` | 16.1:1 |
///
/// 四条使用纪律（都来自上表）：
///
/// 1. **[textTertiary] 浅色端不到 4.5:1**（3.23）——只能承载装饰性
///    文字、已被别处重复表达过的信息；**深色端 4.91 达标**，两端不对称
///    是正常现象。凡用户真的需要读到的（集数、时长、更新时间、状态）
///    一律用 [textSecondary]。
/// 2. **绿色在浅色底上只作图形**（3.20）——进度线、开关、图标、描边；
///    要「绿色的小字」（链接 / 徽章 / 选中文字）一律换 [accentDeep]（5.29）。
/// 3. **白字不进绿底做小号**（3.20）——绿色填充上只放大号字与图形。
/// 4. 发丝线（[divider]）**只用于分隔**，不得作为唯一的状态信号；
///    选中态必须同时有填充或字重变化。
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

  /// 页面底色：浅色纯白；深色取 ChatGPT 画布 `#212121`（播放器场景另用纯黑）。
  ///
  /// 深色取炭灰而不是纯黑：这是 ChatGPT 深色的本色——纯黑与纯白一样极端，
  /// 长列表面板全黑会让玻璃的边界无处安放；`#212121 / #2F2F2F / #171717`
  /// 给出画布、面、凹陷三级明度台阶。
  Color get background =>
      _dark ? const Color(0xFF212121) : const Color(0xFFFFFFFF);

  /// 沉浸式媒体底（播放器整屏）。固定纯黑，不随外观变化。
  Color get mediaBackground => const Color(0xFF000000);

  /// 内容面（卡片 / 抽屉 / 海报卡背板）。
  ///
  /// 浅色下与画布同为纯白——分层靠**发丝线**而不是靠灰阶差；
  /// 深色下比画布亮一档（`#2F2F2F`）以形成「浮起」。
  Color get contentSurface =>
      _dark ? const Color(0xFF2F2F2F) : const Color(0xFFFFFFFF);

  /// 更高一层（弹层 / 抽屉 / 选中行）。详情页的白色抽屉即此档。
  Color get surfaceElevated =>
      _dark ? const Color(0xFF3A3A3A) : const Color(0xFFFFFFFF);

  /// 内陷面「浅雾」：输入底 / 凹陷面 / 头像底 / 进度轨道底。
  ///
  /// 浅色 `#F7F7F8`（ChatGPT 的面灰）；深色 `#171717` 比画布**更深**
  /// ——与 ChatGPT 深色侧栏同向：凹陷用「更深」而不是「更亮」表达。
  Color get sunken => _dark ? const Color(0xFF171717) : const Color(0xFFF7F7F8);

  // ── 前景（ink / graphite / silver 三级） ────────────────────────

  /// 墨黑：正文、标题、**重型填充**（主操作 / 选中格 / 反色块，配 [onInk]）。
  Color get textPrimary => _dark
      ? const Color(0xFFECECEC)
      : (highContrast ? const Color(0xFF000000) : const Color(0xFF0F0F0F));

  /// 石墨：次级文字、未选中图标、以及**一切需要读的元信息**。
  ///
  /// 纸白 4.99:1、浅雾 4.66:1、深色画布 7.77:1——三个底都过线，
  /// 可以承载正文。
  Color get textSecondary => _dark
      ? const Color(0xFFB4B4B4)
      : (highContrast ? const Color(0xFF3F3F4A) : const Color(0xFF6E6E80));

  /// 银灰：三级文字 / 装饰性元信息。**浅色端不足 4.5:1**（3.23），
  /// 深色端 4.91 达标——浅色端勿承载关键信息（见类注释的对比度表）。
  Color get textTertiary =>
      _dark ? const Color(0xFF8E8E8E) : const Color(0xFF8F8F8F);

  /// 不可用态（HIG：disabled 需明显弱于三级，但仍可辨）。
  Color get textDisabled =>
      _dark ? const Color(0xFF565656) : const Color(0xFFC9C9C9);

  // ── 标志绿（状态与进程） ─────────────────────────────────────────

  /// 标志绿（ChatGPT `#10A37F`）——**全站唯一彩色**，只表达状态与进程。
  ///
  /// 分工：进度线 / 加载 / 开关 / 焦点 / 选中标记 / 描边 / 图标 / 品牌块。
  /// 纪律见类注释：浅色底上只作图形（3.20:1），绿色小字一律换 [accentDeep]；
  /// 它**不做**主操作填充——主操作是墨色胶囊（ChatGPT 现行做法）。
  /// 深浅两端同值：深色画布上它是 5.04:1，可直接承载小字。
  Color get accent => const Color(0xFF10A37F);

  /// 可承载小字的绿（浅色端加深、深色端提亮）。
  ///
  /// 凡「绿色的小字」——链接、徽章文字、选中胶囊文字——一律用它：
  /// 浅色 `#0B7A61`（5.29:1）、深色 `#19C37D`（7.01:1），两端都过 4.5:1。
  Color get accentDeep =>
      _dark ? const Color(0xFF19C37D) : const Color(0xFF0B7A61);

  /// [accent] 之上的前景。白字在绿上只有 3.20:1——**只放大号字与图形**
  /// （图标、勾、播放三角、品牌块），不要放小号正文。
  Color get onAccent => const Color(0xFFFFFFFF);

  /// 墨色重型填充（[textPrimary] 实心块：主按钮 / 选中格）之上的前景。
  ///
  /// 浅色墨底配白、深色亮底配近黑——与 [textPrimary] 成对使用；
  /// 不要与 [onAccent] 混用：那是绿底之上的那一个。
  Color get onInk => _dark ? const Color(0xFF101010) : const Color(0xFFFFFFFF);

  /// 绿色浅底（悬停 / 选中行 / 弱提示底 / 选中胶囊底）。不承载正文，仅作底。
  ///
  /// 12%（浅）/ 20%（深）是本色板上限：再重就会和「真正的绿色状态」
  /// （进度 / 开关）混淆，用户分不清哪个是活的。
  Color get accentSubtle => _dark
      ? const Color(0x3310A37F)
      : (highContrast ? const Color(0x2E10A37F) : const Color(0x1F10A37F));

  /// 发丝线（分隔线 / 描边）。
  Color get divider => _dark
      ? const Color(0xFF3D3D3D)
      : (highContrast ? const Color(0xFFB0B0B0) : const Color(0xFFE5E5E5));

  /// 更明显的边界（输入框 / 选中卡描边 / 玻璃镜片描边）。
  ///
  /// 与 [divider] 一样**响应高对比**：边界的可辨识度是「Increase Contrast」
  /// 的主要诉求之一，两者若只有一支响应，高对比下会出现「分隔线很清楚、
  /// 但选中框看不见」的割裂。
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
  /// 早先的实现是 `t < 0.5 ? this : other`（硬切），与「外观切换做过渡」的
  /// 承诺相矛盾，切换时会闪。这里改为真插值：Material 在 `AnimatedTheme`
  /// 里以 200ms 调用它，玻璃与内容随之连续迁移而不是跳变。
  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    if (t <= 0) return this;
    if (t >= 1) return other;
    // 高对比是**开关**不是连续量：过半即取目标侧，否则会出现
    // 「半高对比」这种既非此也非彼的中间态，对比度两头不达标。
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

  /// 页面左右边距（compact）。
  static const double gutter = 16;

  /// 大屏内容最大宽度（防拉伸）。
  static const double maxContentWidth = 960;

  /// 宽屏（侧栏 + 内容）内容区上限。
  static const double maxWideContentWidth = 1200;

  /// 侧栏宽度（平板横屏 / 桌面）。
  static const double sideRailWidth = 232;

  /// 触控目标下限（HIG `accessibility.md`：移动端默认 44×44 pt）。
  ///
  /// 所有自绘可点区都必须达到它——不得为了视觉紧凑把可点区缩到 36。
  static const double minTapTarget = 44;

  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: gutter);
  static const EdgeInsets card = EdgeInsets.all(lg);
}

/// 圆角刻度（连续曲率）。
///
/// 曲线一律走 [shape]（`RoundedSuperellipseBorder`），玻璃面用包内建的
/// `LiquidRoundedSuperellipse`——两者底层是同一个曲率模型，因此海报卡
/// 紧贴在玻璃胶囊旁边时不会「一边圆得突然、一边圆得生硬」。
abstract final class AppRadii {
  static const double xs = 4;

  /// 缩略图（榜单行 / 播放胶囊里的小封面）。
  static const double thumbnail = 10;

  static const double sm = 8;
  static const double md = 12;

  /// 内容卡（海报卡 / 选集格 / 分组块）。
  static const double lg = 14;

  /// 大内容卡（Hero / 货架卡 / bento 大格）。
  static const double xl = 18;

  /// 最大一档内容圆角（全宽 Hero / 大图块）。
  static const double xxl = 22;

  /// 弹层（sheet / dialog / 抽屉）。
  static const double sheet = 28;

  /// 胶囊（stadium）。
  static const double capsule = 9999;

  /// 内容层的连续曲率边框。
  static ShapeBorder shape(double radius) => RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(radius),
      );

  /// 内容层的连续曲率裁切（封面 / 图块用）。
  static Widget clip({
    required double radius,
    required Widget child,
    Clip clipBehavior = Clip.antiAlias,
  }) =>
      ClipRRect(
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
  /// Roboto Mono，其余落到通用 `monospace`。不打包字体文件——原型与主工程
  /// 都跑系统字体，多带一个字体文件只为几个数字不划算。
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
  /// `tabularFigures` 让同一段文字换数字时宽度不跳，配合等宽字族
  /// 可以做到榜单序号与时间码纵向严格对齐。
  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.35,
    letterSpacing: 0.2,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 榜单大号码（「数字即视觉」的一档）。
  static const TextStyle numeral = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    height: 1.0,
    letterSpacing: -1.0,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 大号等宽数字（「我的」页统计值）。
  static const TextStyle stat = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.5,
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
