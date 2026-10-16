import 'package:drama_app/ui/core/tokens/app_tokens.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 色板的**对比度契约**回归。
///
/// `app_tokens.dart` 的类注释里列了一张 WCAG 实算表，并据此定了四条用色纪律
/// （哪一档可以承载正文、哪一档只能装饰、绿色什么时候要加深）。注释里的数字
/// 一旦和实际色值漂移，后来的人就会照着过期的表做决定——所以把表本身变成测试。
///
/// 这不是「所有文字都 4.5:1」的天真断言：色板允许「图形级绿」（浅色端
/// 3.20:1）与「装饰灰」（浅色端 3.23:1）两档低于 4.5:1 的存在——它们的使用
/// 场景已被注释声明，测试要保证的是**注释说的和色值做的一致**。
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
      final r = contrast(c.textTertiary, c.background);
      expect(r, lessThan(4.5));
      expect(r, greaterThan(3.0)); // 3.23——比旧色板更清楚，但仍只配装饰
    });
    test('标志绿在浅色底上只作图形（过 3:1、不到 4.5）', () {
      final r = contrast(c.accent, c.background);
      expect(r, greaterThan(3.0));
      expect(r, lessThan(4.5));
    });
    test('accentDeep 承载绿色小字，过 4.5:1', () {
      expect(contrast(c.accentDeep, c.background), greaterThan(4.5));
    });
    test('白字不进绿底做小号（锁死在「图形与大号字」档）', () {
      final r = contrast(c.onAccent, c.accent);
      expect(r, greaterThan(3.0));
      expect(r, lessThan(4.5));
    });
    test('反白配墨底过线（重型填充的用法）', () {
      expect(contrast(c.onInk, c.textPrimary), greaterThan(15));
    });
  });

  group('实算表与注释一致（深色）', () {
    final c = AppColors(Brightness.dark);
    test('label 与 graphite 在画布上过线', () {
      expect(contrast(c.textPrimary, c.background), greaterThan(4.5));
      expect(contrast(c.textSecondary, c.background), greaterThan(4.5));
    });
    test('silver 深色端也过线（深色没有浅色端的对比度天花板）', () {
      expect(contrast(c.textTertiary, c.background), greaterThan(4.5));
    });
    test('标志绿在深色画布上可直接承载小字', () {
      expect(contrast(c.accent, c.background), greaterThan(4.5));
    });
    test('accentDeep 深色端过线', () {
      expect(contrast(c.accentDeep, c.background), greaterThan(4.5));
    });
    test('反白配亮面过线', () {
      expect(contrast(c.onInk, c.textPrimary), greaterThan(15));
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
