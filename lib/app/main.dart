import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/app/app_layout.dart';
import 'package:duanju_app/app/app_orientation.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/downloads/media_library.dart';
import 'package:duanju_app/features/lan/lan_controller.dart';
import 'package:duanju_app/features/player/video_enhancement_assets.dart';
import 'package:duanju_app/app/router.dart';
import 'package:duanju_app/core/providers.dart';
import 'package:duanju_app/core/diary_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
  }
  MediaKit.ensureInitialized();
  VideoEnhancementAssets.registerLicenses();
  final device = await AppDevice.detect();
  final rendering = Platform.isAndroid
      ? ', 渲染: ${await AppDevice.compatibleRendering() ? 'skia' : 'impeller'}'
      : '';
  DiaryService.add(
    '[App] 应用启动，版本: ${device.version}, '
    '平台: ${Platform.operatingSystem}$rendering',
  );
  final preferences = await SharedPreferences.getInstance();
  runApp(AppBootstrap(device: device, preferences: preferences));
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({
    super.key,
    this.device = const AppDevice(),
    required this.preferences,
  });
  final AppDevice device;
  final SharedPreferences preferences;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  late final LocalStore store;
  late final ProviderContainer container;
  late AppDevice device = widget.device;

  @override
  void dispose() {
    container.dispose();
    WidgetsBinding.instance.removeObserver(this);
    LanController.current?.dispose();
    LanController.current = null;
    MediaLibrary.current?.dispose();
    MediaLibrary.current = null;
    store.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store = LocalStore(widget.preferences);
    // 一次性注入启动依赖：Riverpod 3 的 updateOverrides 只能更新已存在的
    // override，启动阶段新增 override 会抛 null check。
    container = ProviderContainer(
      overrides: [
        bootstrapRetryProvider.overrideWithValue(_initialize),
        repositoryProvider.overrideWithValue(repository),
        storeProvider.overrideWith((_) => store),
      ],
    );
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshDevice());
    }
    if (!Platform.isIOS) return;
    final library = MediaLibrary.current;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (library != null) {
        library.suspended = true;
        unawaited(library.cancel());
      }
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    } else if (state == AppLifecycleState.resumed) {
      if (library != null) library.suspended = false;
    }
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: device);
    if (!mounted || device.version == detected.version) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _loadInstalledSources() async {
    try {
      SourceSite.setInstalledExtensions(await repository.installedExtensions());
    } catch (error) {
      DiaryService.add('[App] 已安装扩展清单读取失败: $error');
    }
  }

  Future<void> _initialize() async {
    container.read(bootstrapErrorProvider.notifier).state = null;
    container.read(appReadyProvider.notifier).state = false;
    try {
      await _refreshDevice();
      await repository.initialize();
      await _loadInstalledSources();
      if (!mounted) return;
      repository.access = store;
      MediaLibrary.attach(repository, store);
      LanController.current?.dispose();
      final link = LanController(
        repository,
        store,
        kind: Platform.isWindows || Platform.isMacOS || Platform.isLinux
            ? 'computer'
            : 'phone',
      );
      LanController.current = link;
      link.openPlayback = (request) async {
        if (request.cancelled ||
            !mounted ||
            store.locked ||
            !link.receiving ||
            !store.allowsSource(request.detail.drama.source)) {
          throw StateError('当前用户不能接收播放');
        }
        await link.playbackHost?.stop();
        if (request.cancelled || !mounted || !link.receiving) {
          throw StateError('播放接收已取消');
        }
        router.go(
          '/player',
          extra: PlayerRouteArgs(
            detail: request.detail,
            initialIndex: request.index,
            initialPosition: request.position,
          ),
        );
      };
      container.read(appReadyProvider.notifier).state = true;
    } catch (failure) {
      container.read(appReadyProvider.notifier).state = false;
      container.read(bootstrapErrorProvider.notifier).state = failure
          .toString();
    }
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: container,
    child: DuanjuApp(version: device.version),
  );
}

class DuanjuApp extends ConsumerWidget {
  const DuanjuApp({super.key, this.version = appVersion});
  final String version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只订阅主题模式：其余 store 变更（历史/追剧等）不再触发根级重建，
    // 各屏自行 watch storeProvider；启动/恢复由路由 `/` 的 provider 决定。
    return _application(ref);
  }

  Widget _application(WidgetRef ref) => MaterialApp.router(
    routerConfig: router,
    title: appName,
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: AppTheme.mode(ref.watch(themeModeProvider)),
    builder: (context, child) {
      final theme = Theme.of(context);
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(theme.brightness),
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: AppOrientationScope(
            child: AppLayout(
              version: version,
              child: FocusTraversalGroup(child: child!),
            ),
          ),
        ),
      );
    },
  );
}

/// 本地配置损坏时的恢复界面：导出原始数据、从备份恢复或重新读取。
class ConfigRecoveryScreen extends StatefulWidget {
  const ConfigRecoveryScreen({super.key, required this.store});
  final LocalStore store;
  @override
  State<ConfigRecoveryScreen> createState() => _ConfigRecoveryScreenState();
}

class _ConfigRecoveryScreenState extends State<ConfigRecoveryScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (failure) {
      setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recover({bool export = false, bool reload = false}) async =>
      _run(() async {
        if (reload) {
          await widget.store.reload();
        } else if (export) {
          await FilePicker.saveFile(
            fileName: '$appSlug-recovery.json',
            bytes: Uint8List.fromList(
              utf8.encode(widget.store.exportRecoveryData()),
            ),
            mimeType: 'application/json',
          );
        } else {
          final file = await FilePicker.pickFile(
            type: FileType.custom,
            allowedExtensions: ['json'],
          );
          if (file == null || !mounted) return;
          final size = await file.length();
          if (size == null || size > 8 * 1024 * 1024) {
            throw const FormatException('备份文件过大或无法读取');
          }
          final content = utf8.decode(await file.readAsBytes());
          await widget.store.recoverBackup(content);
        }
      });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('需要恢复本地配置')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.store.configurationError ?? '本地配置已锁定',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              '将使用这份备份替换损坏的配置、追剧、观看记录和偏好。'
              '建议先导出原始配置；已下载视频保留。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(
                  onPressed: _busy ? null : () => _recover(),
                  child: const Text('从备份恢复'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _recover(export: true),
                  child: const Text('导出原始配置'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _recover(reload: true),
                  child: const Text('重新读取配置'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Color(0xFFB3261E))),
            ],
          ],
        ),
      ),
    ),
  );
}
