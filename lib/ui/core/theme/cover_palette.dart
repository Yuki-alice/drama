import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 从封面提取的**氛围色板**（详情页 / 播放器背景用）。
///
/// 界面色板是无彩色的，颜色的唯一来源是封面：本页/本播放器的背景 =
/// 封面色放大 + 模糊 + 径向氛围色，向下渐隐回界面底色。
/// [c1] 是亮侧、[c2] 是暗侧，两者同色系，用于生成 168° 线性渐变。
@immutable
class CoverPalette {
  const CoverPalette({required this.c1, required this.c2, this.hue = 0});

  /// 亮侧。
  final Color c1;

  /// 暗侧。
  final Color c2;

  /// 主色相（0–360，供调试 / 断言）。
  final double hue;

  /// 中性兜底色板（无封面、提取失败、或封面近似无彩时用）。
  static const CoverPalette neutral = CoverPalette(
    c1: Color(0xFF6E6E80),
    c2: Color(0xFF2B2B33),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoverPalette && c1 == other.c1 && c2 == other.c2;

  @override
  int get hashCode => Object.hash(c1, c2);
}

/// 由种子派生**确定性**色板（无封面时兜底）。
///
/// 同一部剧每次渲染取同一组色；色相取自 seed 的散列，低饱和——
/// 它只是「一块可区分的底」，绝不与真封面的观感抢戏。
CoverPalette paletteFromSeed(String seed) {
  if (seed.isEmpty) return CoverPalette.neutral;
  final hue = (seed.hashCode.abs() % 360).toDouble();
  return _paletteFromHue(hue, saturation: 0.34);
}

/// 由主色相构造亮 / 暗两侧（同色系）。
///
/// 亮侧取较高的明度、暗侧取较低的明度：原型 `cover-art` 的渐变即
/// `linear-gradient(168deg, c1, c2)`，亮侧在上、暗侧在下。
CoverPalette _paletteFromHue(double hue, {double saturation = 0.5}) {
  final c1 = HSLColor.fromAHSL(1, hue, saturation, 0.44).toColor();
  final c2 = HSLColor.fromAHSL(
    1,
    hue,
    math.min(1, saturation + 0.08),
    0.20,
  ).toColor();
  return CoverPalette(c1: c1, c2: c2, hue: hue);
}

/// 从封面图提取主色（Apple Music 做法）。
///
/// 步骤：把图缩到 32×32 → 按「饱和度 × 明度」加权做粗粒度量化聚类 →
/// 取权重最高的簇的色相 → 生成同色系亮/暗两侧。
///
/// 全灰度封面（加权为 0）或提取失败时回落 [paletteFromSeed]。
Future<CoverPalette> extractCoverPalette(
  ImageProvider provider, {
  required String seed,
}) async {
  try {
    final image = await _resolveImage(provider);
    final pixels = await _readSmallRgba(image, 32);
    final palette = _dominantPalette(pixels);
    return palette ?? paletteFromSeed(seed);
  } catch (_) {
    return paletteFromSeed(seed);
  }
}

Future<ui.Image> _resolveImage(ImageProvider provider) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) completer.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (error, stack) {
      if (!completer.isCompleted) completer.completeError(error);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// 把图缩到 [size]×[size] 后读出 RGBA 字节（32×32×4 = 4KiB，代价可忽略）。
Future<Uint8List> _readSmallRgba(ui.Image image, int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final dst = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
  final src = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );
  canvas.drawImageRect(
    image,
    src,
    dst,
    Paint()..filterQuality = FilterQuality.low,
  );
  final small = await recorder.endRecording().toImage(size, size);
  final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  if (data == null) throw StateError('封面像素读取失败');
  return data.buffer.asUint8List();
}

/// 粗粒度量化聚类：4bit/通道（4096 桶），按「饱和度 × 明度」加权取主簇。
CoverPalette? _dominantPalette(Uint8List rgba) {
  final weight = List<double>.filled(4096, 0);
  final count = List<int>.filled(4096, 0);
  var colorWeightSum = 0.0;

  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    final a = rgba[i + 3];
    if (a < 32) continue; // 透明像素（圆角外）不参与统计
    final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
    // 低饱和的灰白像素只贡献很少权重：主色应该来自有彩的部分。
    final w = hsl.saturation * (0.25 + hsl.lightness);
    final bucket = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    weight[bucket] += w;
    count[bucket] += 1;
    colorWeightSum += w;
  }

  if (weight.isEmpty) return null;

  // 有彩部分太少（近似无彩封面）→ 交给调用方回落种子色板。
  if (colorWeightSum < 4) return null;

  var best = 0;
  for (var i = 1; i < weight.length; i++) {
    if (weight[i] > weight[best]) best = i;
  }
  if (count[best] == 0) return null;

  final r = ((best >> 8) & 0xF) * 17;
  final g = ((best >> 4) & 0xF) * 17;
  final b = (best & 0xF) * 17;
  final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
  // 定量化会略微压暗饱和度，这里把它拉回一档，观感更接近原图。
  return _paletteFromHue(
    hsl.hue,
    saturation: (hsl.saturation * 1.15).clamp(0.35, 0.85),
  );
}

/// 氛围色板：按（封面 URL, 种子）缓存。
///
/// 无封面时立即返回种子色板；有封面时解码一次并缓存，失败也缓存兜底，
/// 避免每次重建都重试解码。
final coverPaletteProvider =
    FutureProvider.family<CoverPalette, ({String cover, String seed})>((
      ref,
      key,
    ) {
      if (key.cover.isEmpty) {
        return Future<CoverPalette>.value(paletteFromSeed(key.seed));
      }
      return extractCoverPalette(NetworkImage(key.cover), seed: key.seed);
    });
