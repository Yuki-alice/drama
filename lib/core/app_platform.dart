import 'dart:io';

import 'package:flutter/foundation.dart';

/// 桌面平台判断（真实运行环境）。
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 移动平台判断（遵循 Flutter 的目标平台，便于测试覆盖）。
bool get isMobilePlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

bool get isAndroidPlatform => Platform.isAndroid;
bool get isIOSPlatform => Platform.isIOS;
bool get isWindowsPlatform => Platform.isWindows;
bool get isMacOSPlatform => Platform.isMacOS;
bool get isLinuxPlatform => Platform.isLinux;
