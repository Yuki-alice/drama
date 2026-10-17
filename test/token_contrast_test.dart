import 'dart:math' as math;

import 'package:drama_app/ui/core/tokens/app_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 色板的**对比度契约**回归（无彩色版）。
///
/// `app_tokens.dart` 的类注释里列了一张 WCAG 实算表，并据此定了三条用色纪律
/// （哪一档可以承载正文、哪一档只能装饰）。注释里的数字一旦和实际色值漂移，
/// 后来的人就会照着过期的表做决定——所以把表本身变成测试。
///
/// 这不是「所有文字都 4.5:1」的天真断言：色板允许「装饰灰」（浅色端 3.24:1）
/// 这一档低于 4.5:1 的存在——它的使用场景已被注释声明，测试要保证的是
/// **注释说的和色值做的一致**。
///
/// 另外把「界面色板不得有色相」这条纪律也变成断言：色板里没有强调色，
/// 颜色只由内容（封面）提供。
double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

double contrast(Color fg, Color bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

/// HSV 饱和度（0 = 严格灰阶）。
double _saturation(Color c) => HSVColor.fromColor(c).saturation;

void main() {
  group('实算表与注释一致（浅色）', () {
    final c = AppColors(Brightness.light);

    test('ink 在纸白与浅雾上都远超 4.5:1', () {
      expect(contrast(c.textPrimary, c.background), greaterThan(15));
      expect(contrast(c.textPrimary, c.sunken), greaterThan(15));
    });

    test('graphite 在纸白与浅雾上都过 4.5:1', () {
      expect(contrast(c.textSecondary, c.background), greaterThan(4.5));
      expect(contrast(c.textSecondary, c.sunken), greaterThan(4.5));
    });

    test('silver 明确不达标（浅色端只能装饰）', () {
      final onCanvas = contrast(c.textTertiary, c.background);
      expect(onCanvas, lessThan(4.5));
      expect(onCanvas, greaterThan(3.0)); // 3.24
      // 浅雾上比纸白更差（3.02）——同样是装饰级，不能承载关键信息。
      expect(contrast(c.textTertiary, c.sunken), greaterThan(3.0));
      expect(contrast(c.textTertiary, c.sunken), lessThan(4.5));
    });

    test('反白配墨底过线（唯一的重型填充）', () {
      expect(contrast(c.onInk, c.textPrimary), greaterThan(15));
    });
  });

  group('实算表与注释一致（深色）', () {
    final c = AppColors(Brightness.dark);

    test('墨与石墨在炭底与浅雾上都过线', () {
      expect(contrast(c.textPrimary, c.background), greaterThan(4.5));
      expect(contrast(c.textPrimary, c.sunken), greaterThan(15));
      expect(contrast(c.textSecondary, c.background), greaterThan(4.5));
      expect(contrast(c.textSecondary, c.sunken), greaterThan(4.5));
    });

    test('石墨在列表卡面（#232325）上过线', () {
      expect(contrast(c.textSecondary, c.contentSurface), greaterThan(4.5));
    });

    test('silver 深色端也过线（深色没有浅色端的对比度天花板）', () {
      expect(contrast(c.textTertiary, c.background), greaterThan(4.5));
      expect(contrast(c.textTertiary, c.sunken), greaterThan(4.5));
    });

    test('近黑配亮面过线', () {
      expect(contrast(c.onInk, c.textPrimary), greaterThan(15));
    });
  });

  group('界面色板不得有色相（颜色只由封面提供）', () {
    for (final brightness in Brightness.values) {
      test('${brightness.name}：所有界面色饱和度极低', () {
        final c = AppColors(brightness);
        final surfaces = <String, Color>{
          'background': c.background,
          'sunken': c.sunken,
          'contentSurface': c.contentSurface,
          'surfaceElevated': c.surfaceElevated,
          'selectionFill': c.selectionFill,
          'divider': c.divider,
          'borderStrong': c.borderStrong,
          'textPrimary': c.textPrimary,
          'textSecondary': c.textSecondary,
          'textTertiary': c.textTertiary,
        };
        surfaces.forEach((name, color) {
          // 0.16 是上限：石墨取 ChatGPT 的 #6E6E80（0.14），其余全部 ≤ 0.07。
          // 超过这个界限就意味着界面开始「带色」，那是封面该做的事。
          expect(
            _saturation(color),
            lessThanOrEqualTo(0.16),
            reason: '$name 饱和度 ${_saturation(color)} 超上限',
          );
        });
      });
    }

    test('画布与重型填充是严格灰阶（R == G == B）', () {
      final light = AppColors(Brightness.light);
      final dark = AppColors(Brightness.dark);
      expect(_saturation(light.background), 0);
      expect(_saturation(light.textPrimary), 0);
      expect(_saturation(light.sunken), lessThanOrEqualTo(0.02));
      expect(_saturation(dark.textPrimary), 0);
      expect(_saturation(dark.sunken), 0);
    });
  });

  group('高对比档确实拉大了差异', () {
    test('高对比同时加强正文与边界', () {
      final normal = AppColors(Brightness.light);
      final hc = AppColors(Brightness.light, highContrast: true);
      // 高对比档不承诺 tertiary 达标（那会破坏层级），但边界要更明显。
      expect(
        contrast(hc.borderStrong, hc.background),
        greaterThan(contrast(normal.borderStrong, normal.background)),
      );
      expect(
        contrast(hc.textPrimary, hc.background),
        greaterThanOrEqualTo(contrast(normal.textPrimary, normal.background)),
      );
    });
  });

  group('lerp 是真插值而不是硬切', () {
    test('亮度按 t 过半切换，但不会返回「半高对比」的中间态', () {
      final light = AppColors(Brightness.light);
      final dark = AppColors(Brightness.dark, highContrast: true);
      // t=0.4 应仍在浅色侧；t=0.6 应已到深色侧。
      expect((light.lerp(dark, 0.4)).brightness, Brightness.light);
      expect((light.lerp(dark, 0.6)).brightness, Brightness.dark);
      // 高对比是开关：要么全开要么全关，不出现「半开」。
      expect((light.lerp(dark, 0.4)).highContrast, isFalse);
      expect((light.lerp(dark, 0.6)).highContrast, isTrue);
      // 端点必须原样返回（否则主题切换的起止帧会跳）。
      expect((light.lerp(dark, 0.0)).brightness, Brightness.light);
      expect((light.lerp(dark, 1.0)).brightness, Brightness.dark);
    });
  });
}
