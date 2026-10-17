import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../tokens/app_tokens.dart';

// 功能层玻璃与内容层的统一出口。
//
// **玻璃不嵌套**：玻璃面内不得再放玻璃控件——玻璃套玻璃是静默降质
// （`avoidsRefraction` → 振动填充，无 blur），不报错，最难发现。
// 需要动作时把动作摆在玻璃面**之外**，或整条都用玻璃控件。
//
// **玻璃只在有东西可折射的地方出现**（设计宪法第三节的位置表）：
// 底部 Tab 条 / 浮起侧栏 / 固定顶栏 / 详情与播放器浮在画面上的圆钮。
// 停在纯色上的东西一律用 [AppRoundButton]（浅雾底）或浅雾底槽。

/// 玻璃圆的视觉直径（详情 / 播放器顶栏的圆钮）。
const double kGlassRoundVisual = 34;

/// 浅雾圆钮的视觉直径（固定顶栏右侧的动作钮）。
const double kPlainRoundVisual = 32;

/// 功能层玻璃面：**GlassContainer 的统一出口**。
///
/// - 正常：独立 own-layer 的液态玻璃（不依赖祖先 `LiquidGlassLayer`）；
///   「独立层」是必须的——栏 / 条可能被放进任意子树。
/// - 降档：高对比或减弱动效（系统「降低透明度 / 减弱动态效果」语义）→
///   退化为 **mist 平面**：保留圆角、位置与那条发丝描边，只去掉模糊与折射。
///   玻璃**消失**会让栏看不见，那是缺陷，不是降级。
///
/// 玻璃参数取原型 `:root` 的 glass 令牌：
/// 浅色 `rgba(255,255,255,.70)` / 深色 `rgba(40,40,42,.62)`，模糊 22–26，
/// 描边 浅 `rgba(255,255,255,.70)` / 深 `rgba(255,255,255,.14)`。
class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    super.key,
    required this.child,
    this.radius = AppRadii.lg,
    this.width,
    this.height,
    this.padding,
    this.blur = 22,
    this.thickness = 12,
    this.quality = GlassQuality.standard,
  });

  final Widget child;
  final double radius;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final double thickness;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final dark = colors.brightness == Brightness.dark;
    final flat =
        colors.highContrast ||
        MediaQuery.highContrastOf(context) ||
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

    final radiusBorder = BorderRadius.circular(radius);
    final paddedChild = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    Widget surface;
    if (flat) {
      // 「降低透明度」：玻璃退化为不透明浅雾平面（保留形态与描边）。
      surface = DecoratedBox(
        decoration: BoxDecoration(
          color: colors.sunken,
          borderRadius: radiusBorder,
          border: Border.all(color: colors.divider, width: .5),
        ),
        child: paddedChild,
      );
    } else {
      // **定尺（给了 width/height）时必须让玻璃铺满盒子**：`Stack` 默认按
      // `topStart` 摆放未定位子项，子项若比盒子小（典型：圆钮的 child 只是一个
      // `Icon`），玻璃片会缩到图标大小并贴在左上角——渲染出来是「圆圈里一个
      // 错位的小片 + 图标偏到角落」，而发丝描边（`Positioned.fill`）仍按 34 画，
      // 于是看起来像「圆圈没套住图标」。1 倍截图看不出来，3 倍放大一眼可见。
      surface = Stack(
        fit: (width != null && height != null)
            ? StackFit.expand
            : StackFit.loose,
        children: <Widget>[
          GlassContainer(
            useOwnLayer: true,
            quality: quality,
            clipBehavior: Clip.antiAlias,
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            settings: LiquidGlassSettings(
              // 原型 glass-fill：浅 白 70% / 深 rgba(40,40,42,.62)。
              glassColor: dark
                  ? const Color(0x9E28282A)
                  : const Color(0xB3FFFFFF),
              thickness: thickness,
              // 包的 blur 是 Gaussian sigma，与 CSS 的 px 模糊半径不同量纲。
              blur: blur / 4,
              saturation: 1.8,
              chromaticAberration: .02,
              lightIntensity: dark ? .5 : 1.0,
            ),
            child: paddedChild,
          ),
          // 发丝描边：原型 glass-line，浅 rgba(255,255,255,.70)/深 .14。
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radiusBorder,
                  border: Border.all(
                    color: dark
                        ? const Color(0x24FFFFFF)
                        : const Color(0xB3FFFFFF),
                    width: .5,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return width == null && height == null
        ? surface
        : SizedBox(width: width, height: height, child: surface);
  }
}

/// 圆钮的视觉锚点：**34 的圆盘落在 44×44 命中区的哪个角**。
///
/// 命中区必须撑到 44（HIG），但圆盘只有 34——两者差 10，圆盘居中时圆盘的边缘
/// 就比页面 gutter（16）内缩 5，于是「顶栏按钮」与「其下内容」的左/右边缘对不齐。
/// 让圆盘贴住命中区相应的角，圆盘边缘才能落在 gutter 上：
/// - [topLeft]：贴左上（左端按钮，给顶栏/详情页的返回钮用）；
/// - [topRight]：贴右上（右端按钮，最后一个动作钮用）；
/// - [center]：居中（默认；四周留白对称，用于不希望贴边的场合）。
///
/// 注意：锚点只挪视觉，不动命中区——命中区始终是 44×44 的整块。
enum VisualAnchor { center, topLeft, topRight }

Alignment _alignmentOf(VisualAnchor anchor) => switch (anchor) {
  VisualAnchor.center => Alignment.center,
  VisualAnchor.topLeft => Alignment.topLeft,
  VisualAnchor.topRight => Alignment.topRight,
};

/// **浮在画面上**的玻璃圆钮（详情页 / 播放器的顶栏动作）。
///
/// 视觉直径 [kGlassRoundVisual]（34），命中区撑到 [AppSpacing.minTapTarget]
/// （44）——视觉紧凑不得换来点不中；[anchor] 决定圆盘在命中区里的位置，
/// 见 [VisualAnchor]。
class AppGlassRoundButton extends StatelessWidget {
  const AppGlassRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.visual = kGlassRoundVisual,
    this.iconSize = 17,
    this.tint,
    this.anchor = VisualAnchor.center,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? semanticLabel;
  final double visual;
  final double iconSize;

  /// 图标颜色；画面之上传 [AppColors.onMedia]。
  final Color? tint;

  final VisualAnchor anchor;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final color = tint ?? colors.textPrimary;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        width: AppSpacing.minTapTarget,
        height: AppSpacing.minTapTarget,
        child: Align(
          alignment: _alignmentOf(anchor),
          child: SizedBox(
            width: visual,
            height: visual,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPressed,
              child: AppGlassSurface(
                radius: visual / 2,
                width: visual,
                height: visual,
                // 小圆盘用更薄的镜片：大条的 thickness 会在 34 的盘上糊成一圈。
                thickness: 8,
                child: Icon(icon, size: iconSize, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **停在纯色上**的圆钮（四个 Tab 页固定顶栏的右侧动作）。
///
/// 用**浅雾底而不是玻璃**：玻璃压在纯色上只会发灰（设计宪法第三节）。
class AppPlainRoundButton extends StatelessWidget {
  const AppPlainRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.visual = kPlainRoundVisual,
    this.iconSize = 16,
    this.tint,
    this.showBadge = false,
    this.anchor = VisualAnchor.center,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? semanticLabel;
  final double visual;
  final double iconSize;
  final Color? tint;

  /// 右上角的墨色小点（筛选生效时的 Badge）。
  final bool showBadge;

  /// 圆盘在 44×44 命中区里的位置（见 [VisualAnchor]）。
  final VisualAnchor anchor;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        width: AppSpacing.minTapTarget,
        height: AppSpacing.minTapTarget,
        child: Align(
          alignment: _alignmentOf(anchor),
          // Badge 与圆盘同属一个「视觉框」：跟着锚点一起走，
          // 否则圆盘贴边时小点会留在命中区的角上，与圆盘脱开。
          child: SizedBox(
            width: visual,
            height: visual,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onPressed,
                  child: Container(
                    width: visual,
                    height: visual,
                    decoration: BoxDecoration(
                      color: colors.sunken,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: iconSize,
                      color: tint ?? colors.textPrimary,
                    ),
                  ),
                ),
                if (showBadge)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: colors.textPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 小字分组标签（原型的 `.sec`：13px / 600 / 石墨，上 22 下 10）。
///
/// [paged] 为自带页面左右边距的变体，供**逐项自己控边距**的页面
/// （设置 / 关于 / 下载）使用；滚在外层已用 gutter 包住的列表里请用默认构造，
/// 否则会双重缩进。
///
/// [action] 为右侧的行内动作（「已完成 3/5」这类），无彩色色板下用墨色 + 字重
/// 表达可点，不靠颜色。
class SectionLabel extends StatelessWidget {
  const SectionLabel({
    super.key,
    required this.text,
    this.top = 22,
    this.paged = false,
    this.action,
    this.onAction,
  });

  final String text;
  final double top;
  final bool paged;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final side = paged ? AppSpacing.gutter : 0.0;
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 10, left: side, right: side),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: AppText.callout.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(
                action!,
                style: AppText.caption.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
