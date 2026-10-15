import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'data/repositories/catalog_providers.dart';
import 'data/services/cache_store.dart';
import 'data/services/rust_core.dart';
import 'ui/core/theme/appearance_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ARCH §4：shader 预编译是纯异步磁盘 I/O，不阻塞首帧且失败不抛异常；
  // shader 未就绪时 premium 面会渲染空白（首帧白闪来源）→ 首帧 UI 不依赖 premium 面。
  await LiquidGlassWidgets.initialize();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await _configureDesktopWindow();
  }

  final preferences = await SharedPreferences.getInstance();

  // W2：启动缓存存储（先 load() 一次性载入磁盘快照，之后读路径同步可用）。
  final cacheStore = FileCacheStore();
  await cacheStore.load();

  // W2：启动 Rust 核心（免签轨①的数据来源）。启动失败不阻断启动——
  // `rustCoreProvider` 保持 null，目录仓库自动回退到 mock（见 catalog_providers.dart）。
  RustCoreHolder? rustCoreHolder;
  try {
    rustCoreHolder = RustCoreHolder(await RustCore.spawn());
  } catch (error) {
    debugPrint('[W2] Rust 核心启动失败，将回退 mock 数据：$error');
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        cacheStoreProvider.overrideWithValue(cacheStore),
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
