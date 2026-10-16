import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 内容层封面（**必须不透明**）。
///
/// 三级回落，任何一级都不让布局塌掉、也不让整页报错：
/// 1. 有 [cover]（本机代理地址）→ 网络图，按显示宽度解码后淡入；
/// 2. 加载中 / 失败 / 无 cover → [seed] 派生的确定性渐变 + 标题；
/// 3. 渐变始终在位（垫在网络图**下面**），因此不会出现白闪或空洞。
///
/// **为什么用 `Image.network` 而不是手写 `ui.Image` 缓存**：
/// Flutter 的 `ImageCache` 已经负责解码缓存、按 `cacheWidth` 缩放、以及
/// **图像句柄的所有权与释放**（`ImageStream` 每次向 listener 交付
/// `image.clone()`，并由 `RenderImage` 释放自己那份）。我曾手写一层
/// 「缓存 `ui.Image` 并交给多个 `RawImage`」的实现，结果多个格子共享同一个
/// 句柄、谁先被回收谁就把图 dispose 掉，运行时报
/// `Bad state: Cannot clone a disposed image`（实机截图复现）。
/// 交给框架后这类生命周期问题不存在。
class DramaCover extends StatelessWidget {
  const DramaCover({
    super.key,
    required this.seed,
    this.cover = '',
    this.title,
    this.aspectRatio = 3 / 4,
    this.radius = AppRadii.lg,
    this.showTitleOverlay = true,
    this.fill = false,
  });

  /// 渐变种子（通常传 `Drama.coverSeed`）。
  final String seed;

  /// 封面地址（本机代理 URL）；空串走渐变。
  final String cover;

  /// 渐变态显示在封面上的标题。
  final String? title;

  final double aspectRatio;
  final double radius;

  /// 是否在渐变态叠加标题（小尺寸缩略图通常不需要）。
  final bool showTitleOverlay;

  /// `true` = 填满父级约束（**不**强制 [aspectRatio]）。
  ///
  /// 用于外层已定好格子形状的场景（如网格 `Expanded`）：此时再套一层
  /// `AspectRatio` 会因约束冲突而留白（letterbox），由外层统一控制比例更稳。
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 渐变垫底：网络图未就绪时它是可见内容，就绪后被盖住。
          _GradientPoster(
            seed: seed,
            showTitle: showTitleOverlay,
            title: title,
            radius: radius,
          ),
          if (cover.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) {
                // 按**物理像素**解码：640×960 的封面原始 RGBA 是 2.4MiB，
                // 一屏十几张就是几十 MiB。交给框架按实际显示宽度解码可省一个量级。
                final dpr = MediaQuery.devicePixelRatioOf(context);
                final targetWidth =
                    (constraints.maxWidth * dpr).round().clamp(1, 4096);
                return _NetworkCover(url: cover, cacheWidth: targetWidth);
              },
            ),
        ],
      ),
    );

    // fill=false（默认）时由封面自己决定形状（3:4 等）；
    // fill=true 时完全服从父级约束（网格已定好格子形状）。
    return fill
        ? SizedBox.expand(child: content)
        : AspectRatio(aspectRatio: aspectRatio, child: content);
  }
}

/// 网络封面：淡入 + 失败静默回落渐变。
///
/// 失败时**不显示任何错误 UI**：渐变已由父级垫底，报错反而打断浏览
/// （封面是增强项，不是关键路径）。
class _NetworkCover extends StatelessWidget {
  const _NetworkCover({required this.url, required this.cacheWidth});

  final String url;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      // 按显示宽度解码，显著降低内存（见 DramaCover 的类注释）。
      cacheWidth: cacheWidth,
      // 重试避免闪烁；同一 URL 复用缓存条目。
      gaplessPlayback: true,
      // 失败/加载中都只画透明层，让下层的渐变透出来。
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: AppMotion.normal,
          curve: AppMotion.standard,
          child: child,
        );
      },
    );
  }
}

// ── 封面 Hero：列表卡片 ⇄ 详情页海报的共享元素转场 ──────────────────

/// 封面 Hero 的标签。
///
/// 组成 = 源 + 源内 id——跨源同 id 是不同剧，标签必须能区分；
/// 列表卡片与详情页海报两端引用**同一个**标签，飞行才会发生。
String coverHeroTag({required String source, required String id}) =>
    'cover:$source:$id';

/// 把封面包进共享元素转场（Kazumi 的做法）。
///
/// - `transitionOnUserGestures: true`：iOS 边缘右滑返回也走转场；
/// - 自定义 shuttle（见 [_coverFlightShuttle]）：飞行途中沿用出发端的
///   渲染树，并在出发/落点上下文里补上 `Material` 与 InheritedTheme，
///   否则飞出原树后文字样式与主题会漂移。
///
/// **标签在同一路由内必须唯一**：同一剧目不要在一个页面里出现两份
/// （例如既进信息流又在别处重复渲染），否则飞行扫描会断言失败。
class CoverHero extends StatelessWidget {
  const CoverHero({
    super.key,
    required this.source,
    required this.id,
    required this.child,
  });

  final String source;
  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 空标签 = 调用方还没拿到身份（如追剧行为空 id 的兜底渲染）：
    // 直接放行，避免所有兜底行共用空标签互相串场。
    if (id.isEmpty || source.isEmpty) return child;
    return Hero(
      tag: coverHeroTag(source: source, id: id),
      transitionOnUserGestures: true,
      flightShuttleBuilder: _coverFlightShuttle,
      child: child,
    );
  }
}

/// 飞行载体：push 取出发端、pop 取落点端的渲染树（Kazumi 同款）。
Widget _coverFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final push = flightDirection == HeroFlightDirection.push;
  final sourceContext = push ? fromHeroContext : toHeroContext;
  final hero = (push ? fromHeroContext.widget : toHeroContext.widget) as Hero;
  return InheritedTheme.captureAll(
    sourceContext,
    Material(type: MaterialType.transparency, child: hero.child),
  );
}

/// 确定性渐变占位（同一 seed 每次颜色一致）。
class _GradientPoster extends StatelessWidget {
  const _GradientPoster({
    required this.seed,
    required this.showTitle,
    this.title,
    this.radius = AppRadii.lg,
  });

  final String seed;
  final bool showTitle;
  final String? title;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 用 hashCode 取色相，保证同一剧目每次渲染颜色一致。
    final hue = seed.hashCode.abs() % 360;
    // 「墨·玻璃」：界面本体零装饰色，所以占位图**不是**彩色海报，
    // 而是一块低饱和的中性灰，只保留一点点色相用来区分相邻剧目
    // （这是信息，不是装饰）。真正决定观感的是上面那层真封面。
    final top = HSLColor.fromAHSL(
      1,
      hue.toDouble(),
      colors.highContrast ? 0.0 : 0.10,
      colors.brightness == Brightness.dark ? 0.20 : 0.94,
    ).toColor();
    final bottom = HSLColor.fromAHSL(
      1,
      ((hue + 28) % 360).toDouble(),
      colors.highContrast ? 0.0 : 0.13,
      colors.brightness == Brightness.dark ? 0.13 : 0.87,
    ).toColor();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[top, bottom],
        ),
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (showTitle)
            // 底部 scrim：保证标题在任何渐变底色上都可读。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x00000000), Color(0x8A000000)],
                ),
              ),
            ),
          if (showTitle && title != null)
            Positioned(
              left: AppSpacing.sm,
              right: AppSpacing.sm,
              bottom: AppSpacing.sm,
              child: Text(
                title!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.callout.copyWith(
                  color: const Color(0xFFFFFFFF),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
