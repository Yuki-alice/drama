import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `SharedPreferences` 实例。
///
/// 在 `main()` 中 `overrideWithValue` 注入（见 [bootstrap]）。任何在未注入时
/// 读取它的代码都属于接线错误，直接抛错比静默返回空值更容易发现。
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider 必须在 main() 中 override（见 lib/main.dart）。',
  ),
);

/// F-09 外观设置：浅色 / 深色 / 跟随系统 + 大字 + 高对比 + 减弱动效。
@immutable
class AppearanceSettings {
  const AppearanceSettings({
    this.themeMode = ThemeMode.system,
    this.textScale = 1.0,
    this.highContrast = false,
    this.reduceMotion = false,
  });

  final ThemeMode themeMode;

  /// 全局文字缩放（大字模式）；1.0 表示不改动。
  final double textScale;

  final bool highContrast;

  final bool reduceMotion;

  /// 大字是否开启——与高对比/减弱动效一起触发玻璃全站降 `minimal`。
  bool get largeText => textScale > 1.001;

  AppearanceSettings copyWith({
    ThemeMode? themeMode,
    double? textScale,
    bool? highContrast,
    bool? reduceMotion,
  }) => AppearanceSettings(
    themeMode: themeMode ?? this.themeMode,
    textScale: textScale ?? this.textScale,
    highContrast: highContrast ?? this.highContrast,
    reduceMotion: reduceMotion ?? this.reduceMotion,
  );
}

/// 外观设置控制器（同时是事实来源与持久化入口）。
class AppearanceController extends Notifier<AppearanceSettings> {
  static const _keyThemeMode = 'appearance.themeMode';
  static const _keyTextScale = 'appearance.textScale';
  static const _keyHighContrast = 'appearance.highContrast';
  static const _keyReduceMotion = 'appearance.reduceMotion';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  AppearanceSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return AppearanceSettings(
      themeMode: _decodeThemeMode(prefs.getString(_keyThemeMode)),
      textScale: prefs.getDouble(_keyTextScale) ?? 1.0,
      highContrast: prefs.getBool(_keyHighContrast) ?? false,
      reduceMotion: prefs.getBool(_keyReduceMotion) ?? false,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _prefs.setString(_keyThemeMode, mode.name);
  }

  Future<void> setTextScale(double scale) async {
    state = state.copyWith(textScale: scale);
    await _prefs.setDouble(_keyTextScale, scale);
  }

  Future<void> setHighContrast(bool enabled) async {
    state = state.copyWith(highContrast: enabled);
    await _prefs.setBool(_keyHighContrast, enabled);
  }

  Future<void> setReduceMotion(bool enabled) async {
    state = state.copyWith(reduceMotion: enabled);
    await _prefs.setBool(_keyReduceMotion, enabled);
  }

  static ThemeMode _decodeThemeMode(String? raw) => ThemeMode.values.firstWhere(
    (mode) => mode.name == raw,
    orElse: () => ThemeMode.system,
  );
}

final appearanceProvider =
    NotifierProvider<AppearanceController, AppearanceSettings>(
      AppearanceController.new,
    );
