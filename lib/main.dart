import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'data/repositories/catalog_providers.dart';
import 'data/services/rust_core.dart';
import 'ui/core/theme/appearance_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // media_kit 必须在**任何** Player/VideoController 之前初始化，否则构造播放器时
  // 直接抛 `MediaKit.ensureInitialized() must be called before using any API from
  // package:media_kit`，播放页整页变红。此前漏了这一步，播放链路在运行时必崩。
  MediaKit.ensureInitialized();

  // shader 预编译是纯异步磁盘 I/O，不阻塞首帧且失败不抛异常；
  // shader 未就绪时 premium 面会渲染空白（首帧白闪来源）→ 首帧 UI 不依赖 premium 面。
  await LiquidGlassWidgets.initialize();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await _configureDesktopWindow();
  }

  final preferences = await SharedPreferences.getInstance();

  // W2：启动 Rust 核心（免签轨①的数据来源）。启动失败不阻断启动——
  // `rustCoreProvider` 保持 null，目录仓库自动回退到 mock（见 catalog_providers.dart）。
  //
  // 缓存存储不再在 Dart 侧初始化：目录缓存（TTL / 回退 / 熔断 / 分页水位 /
  // 封面端口自愈）已下沉到 Rust `cache.rs`，由 `init` 的 `dataDir` 落盘。
  RustCoreHolder? rustCoreHolder;
  try {
    final core = await RustCore.spawn();
    // 设备身份初始化（签名用稳定身份；失败则用进程内临时身份，不阻断）。
    try {
      final support = await getApplicationDocumentsDirectory();
      await core.call(
        'init',
        params: <String, Object?>{'dataDir': support.path},
      );
    } catch (error) {
      debugPrint('Rust 核心 init 失败，将用临时设备身份：$error');
    }
    rustCoreHolder = RustCoreHolder(core);
  } catch (error) {
    debugPrint('[W2] Rust 核心启动失败，将回退 mock 数据：$error');
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        if (rustCoreHolder != null)
          rustCoreProvider.overrideWithValue(rustCoreHolder),
      ],
      child: const DramaApp(),
    ),
  );
}

/// 桌面端窗口尺寸（Windows 为 MVP 目标平台之一）。
Future<void> _configureDesktopWindow() async {
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(420, 640),
    center: true,
    title: '红果短剧',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
