import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 内容层封面（**必须不透明**）。
///
/// 三级回落，任何一级都不让布局塌掉、也不让整页报错：
/// 1. 有 [cover]（本机代理地址）→ 网络图，带淡入；解码按显示宽度缩放；
/// 2. 加载中 / 失败 / 无 cover → [seed] 派生的确定性渐变 + 标题；
/// 3. 渐变始终在位（垫在网络图**下面**），因此不会出现白闪或空洞。
///
/// **为什么不用 `cached_network_image`**：它要拖进 sqflite 等 15 个依赖，
/// 与本项目「零使用的包不进 pubspec」的瘦身原则冲突。封面本身已在 Rust 侧
/// 落磁盘缓存（`{dataDir}/covers`），Dart 侧只需**进程内**内存缓存，
/// 见 [_CoverMemoryCache]。
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
    final borderRadius = BorderRadius.circular(radius);

    final content = ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 渐变垫底：网络图未就绪时它是可见内容，就绪后被盖住。
            _GradientPoster(
              seed: seed,
              showTitle: showTitleOverlay,
              title: title,
            ),
            if (cover.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) {
                  // 按**物理像素**解码：640×960 的封面原始 RGBA 是 2.4MiB，
                  // 一屏十几张就是几十 MiB。按实际显示宽度解码可省一个数量级。
                  final dpr = MediaQuery.devicePixelRatioOf(context);
                  final targetWidth =
                      (constraints.maxWidth * dpr).round().clamp(1, 4096);
                  return _NetworkCover(
                    url: cover,
                    cacheWidth: targetWidth,
                    fadeIn: true,
                  );
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

/// 进程内封面内存缓存（键 = url + 解码宽度）。
///
/// 只缓存**已解码**的 `ui.Image`，因此滚动海报墙时不会反复解码；
/// 磁盘缓存由 Rust 负责，这里不需要再做一层。
///
/// 外观（明暗）切换时调 [clear]：渐变占位的取色随亮度变化，
/// 但已解码的位图与亮度无关，故不必重取；这里清空主要是为了在
/// 高对比切换等场景下丢弃旧条目、避免长期占用。
class CoverImageCache {
  static final Map<String, ui.Image> _images = <String, ui.Image>{};
  static const int _maxEntries = 120;

  static ui.Image? get(String key) => _images[key];

  static void put(String key, ui.Image image) {
    if (_images.length >= _maxEntries) {
      // 简单淘汰：清掉最早的一半（封面复用率高，LRU 的收益不值复杂度）。
      final keys = _images.keys.take(_maxEntries ~/ 2).toList(growable: false);
      for (final k in keys) {
        _images.remove(k)?.dispose();
      }
    }
    _images[key] = image;
  }

  /// 彻底释放内存缓存（外观切换 / 测试时调用）。
  static void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }
}

/// 网络封面：解析 → 解码（按宽度）→ 缓存 → 淡入。
class _NetworkCover extends StatefulWidget {
  const _NetworkCover({
    required this.url,
    required this.cacheWidth,
    this.fadeIn = true,
  });

  final String url;
  final int cacheWidth;
  final bool fadeIn;

  @override
  State<_NetworkCover> createState() => _NetworkCoverState();
}

class _NetworkCoverState extends State<_NetworkCover> {
  ui.Image? _image;

  String get _cacheKey => '${widget.url}@${widget.cacheWidth}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _NetworkCover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.cacheWidth != widget.cacheWidth) {
      _image = null;
      _load();
    }
  }

  Future<void> _load() async {
    final cached = CoverImageCache.get(_cacheKey);
    if (cached != null) {
      if (mounted) setState(() => _image = cached);
      return;
    }
    try {
      final provider = NetworkImage(widget.url);
      final stream = provider.resolve(
        ImageConfiguration(
          size: Size(widget.cacheWidth.toDouble(), 0),
          devicePixelRatio: 1,
        ),
      );
      final completer = _loadCompleter(stream);
      final image = await completer;
      if (image == null) return;
      CoverImageCache.put(_cacheKey, image);
      if (mounted) setState(() => _image = image);
    } catch (_) {
      // 失败一律静默回落渐变（封面是增强项，不该冒泡成页面错误）。
      // 渐变由父级垫底，这里什么都不做即可——不留空洞、不改布局。
    }
  }

  /// 把 `ImageStream` 收敛成一个 `Future<ui.Image?>`（失败/销毁都返回 null）。
  static Future<ui.Image?> _loadCompleter(ImageStream stream) {
    final completer = Completer<ui.Image?>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      // 渐变已由父级垫底；失败时也保持渐变，不留空洞。
      return const SizedBox.shrink();
    }
    final painter = RawImage(
      image: image,
      fit: BoxFit.cover,
      // 关闭滤镜采样：海报缩放时略锐，符合 Notion/Apple 的克制观感。
      filterQuality: FilterQuality.medium,
    );
    if (!widget.fadeIn) return painter;
    return AnimatedOpacity(
      opacity: 1,
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      child: painter,
    );
  }
}

/// 确定性渐变占位（同一 seed 每次颜色一致）。
class _GradientPoster extends StatelessWidget {
  const _GradientPoster({
    required this.seed,
    required this.showTitle,
    this.title,
  });

  final String seed;
  final bool showTitle;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 用 hashCode 取色相，保证同一剧目每次渲染颜色一致。
    final hue = seed.hashCode.abs() % 360;
    // Notion 风：低饱和、低对比的暖灰蓝调，避免五彩斑斓抢内容。
    // 色相仍随剧目变化（可区分），但饱和度压到 0.18~0.28、亮度贴近纸面。
    final top = HSLColor.fromAHSL(
      1,
      hue.toDouble(),
      colors.highContrast ? 0.0 : 0.22,
      colors.brightness == Brightness.dark ? 0.22 : 0.90,
    ).toColor();
    final bottom = HSLColor.fromAHSL(
      1,
      ((hue + 28) % 360).toDouble(),
      colors.highContrast ? 0.0 : 0.26,
      colors.brightness == Brightness.dark ? 0.16 : 0.83,
    ).toColor();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[top, bottom],
        ),
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(AppRadii.lg),
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
