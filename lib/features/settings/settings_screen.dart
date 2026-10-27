import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import 'package:duanju_app/core/app_platform.dart';
import 'package:duanju_app/app/app_layout.dart';
import 'package:duanju_app/app/app_screen.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/diary_service.dart';
import 'package:duanju_app/core/download_preferences.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/data/media/background_downloads.dart';
import 'package:duanju_app/features/lan/lan_controller_provider.dart';
import 'package:duanju_app/features/lan/lan_screen.dart';
import 'package:duanju_app/features/settings/resource_settings_screen.dart';
import 'package:duanju_app/features/sources/sources_screen.dart';
import 'package:duanju_app/widgets/settings_widgets.dart';
import 'package:duanju_app/widgets/widgets.dart';

String storageSize(int bytes) {
  if (bytes < 0) return '暂不可用';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class _SettingsCategory {
  const _SettingsCategory({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
    required this.build,
  });

  final String id;
  final String label;
  final String description;
  final IconData icon;
  final WidgetBuilder build;
}

class _SettingsGroup {
  const _SettingsGroup({required this.title, required this.categories});

  final String title;
  final List<_SettingsCategory> categories;
}

/// 设置：Kazumi 式目录 + 分栏。宽屏左目录右内容，窄屏点分类进入独立页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialCategory,
  });
  final AppRepository repository;
  final LocalStore store;
  final String? initialCategory;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _selected = _resolveCategory(widget.initialCategory);

  List<_SettingsGroup> get _groups => [
    _SettingsGroup(
      title: '播放',
      categories: [
        _SettingsCategory(
          id: 'playback',
          label: '播放偏好',
          description: '倍速、画质、连播与弹幕',
          icon: Icons.display_settings_rounded,
          build: (_) => _PlaybackPane(store: widget.store),
        ),
      ],
    ),
    _SettingsGroup(
      title: '资源',
      categories: [
        _SettingsCategory(
          id: 'rules',
          label: '规则管理',
          description: '站源规则的启用、更新与检测',
          icon: Icons.extension_rounded,
          build: (_) =>
              SourcesScreen(repository: widget.repository, store: widget.store),
        ),
        _SettingsCategory(
          id: 'download',
          label: '下载偏好',
          description: '默认画质与 VIP 集选择',
          icon: Icons.downloading_rounded,
          build: (_) => DownloadPreferencesScreen(store: widget.store),
        ),
        _SettingsCategory(
          id: 'storage',
          label: '下载目录与空间',
          description: '存储用量与迁移已下载文件',
          icon: Icons.storage_rounded,
          build: (_) =>
              StorageScreen(repository: widget.repository, store: widget.store),
        ),
      ],
    ),
    _SettingsGroup(
      title: '应用',
      categories: [
        _SettingsCategory(
          id: 'appearance',
          label: '外观设置',
          description: '主题、深浅色与内容显示',
          icon: Icons.palette_rounded,
          build: (_) => _AppearancePane(store: widget.store),
        ),
        _SettingsCategory(
          id: 'network',
          label: '网络与资源',
          description: '代理、请求并发与下载并发',
          icon: Icons.language_rounded,
          build: (_) => ResourceSettingsScreen(
            repository: widget.repository,
            store: widget.store,
          ),
        ),
        _SettingsCategory(
          id: 'lan',
          label: '设备互联',
          description: '局域网追剧同步与推送播放',
          icon: Icons.devices_rounded,
          build: (_) => const _LanPane(),
        ),
      ],
    ),
    _SettingsGroup(
      title: '其他',
      categories: [
        _SettingsCategory(
          id: 'diary',
          label: '播放日记',
          description: '运行与播放器事件日志',
          icon: Icons.receipt_long_rounded,
          build: (_) => const _DiaryPane(),
        ),
        _SettingsCategory(
          id: 'backup',
          label: '备份与恢复',
          description: '导出或恢复本机配置数据',
          icon: Icons.backup_outlined,
          build: (_) =>
              _BackupPane(repository: widget.repository, store: widget.store),
        ),
        _SettingsCategory(
          id: 'about',
          label: '关于',
          description: '版本与运行说明',
          icon: Icons.info_outline_rounded,
          build: (_) => const _AboutPane(),
        ),
      ],
    ),
  ];

  List<_SettingsCategory> get _all => [
    for (final group in _groups) ...group.categories,
  ];

  String _resolveCategory(String? id) {
    final all = [for (final group in _groups) ...group.categories];
    return all.any((category) => category.id == id) ? id! : all.first.id;
  }

  void _open(_SettingsCategory category, {required bool wide}) {
    if (wide) {
      setState(() => _selected = category.id);
      return;
    }
    Navigator.push(context, MaterialPageRoute<void>(builder: category.build));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 600;
    final groups = _groups;
    final selected = _all.firstWhere(
      (category) => category.id == _selected,
      orElse: () => _all.first,
    );
    return AppScreen(
      title: '设置',
      body: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: wide ? 280 : 0,
              child: Offstage(
                offstage: !wide,
                child: _SettingsMenu(
                  groups: groups,
                  selectedId: selected.id,
                  wide: true,
                  onOpen: (category) => _open(category, wide: true),
                ),
              ),
            ),
            Expanded(
              child: wide
                  ? SettingsPaneScope(
                      embedded: true,
                      showBackButton: false,
                      onBack: () {},
                      child: KeyedSubtree(
                        key: ValueKey(selected.id),
                        child: Builder(builder: selected.build),
                      ),
                    )
                  : _SettingsMenu(
                      groups: groups,
                      selectedId: null,
                      wide: false,
                      onOpen: (category) => _open(category, wide: false),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({
    required this.groups,
    required this.wide,
    required this.onOpen,
    this.selectedId,
  });

  final List<_SettingsGroup> groups;
  final bool wide;
  final String? selectedId;
  final ValueChanged<_SettingsCategory> onOpen;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView(
        padding: wide
            ? const EdgeInsets.fromLTRB(4, 8, 8, 12)
            : const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final group in groups)
            if (wide) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
                child: SectionHeader(title: Text(group.title)),
              ),
              for (final category in group.categories)
                SettingsRailDestination(
                  icon: category.icon,
                  label: category.label,
                  selected: selectedId == category.id,
                  onTap: () => onOpen(category),
                ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: ContentSection.group(
                  title: group.title,
                  children: [
                    for (final category in group.categories)
                      SettingsCategoryTile(
                        icon: category.icon,
                        title: category.label,
                        description: category.description,
                        onTap: () => onOpen(category),
                      ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}

/// 单个设置页骨架：分组卡片列表。
class _PaneScaffold extends StatelessWidget {
  const _PaneScaffold({required this.title, required this.sections});

  final String title;
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: title,
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        for (final section in sections)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: section,
              ),
            ),
          ),
      ],
    ),
  );
}

class _AppearancePane extends StatelessWidget {
  const _AppearancePane({required this.store});
  final LocalStore store;

  static const _modes = ['system', 'light', 'dark'];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      return _PaneScaffold(
        title: '外观设置',
        sections: [
          ContentSection.group(
            title: '主题',
            description: '播放器始终保持深色，不受这里影响。',
            children: [
              for (final mode in _modes)
                ListTile(
                  key: ValueKey('theme-$mode'),
                  onTap: () =>
                      saveUserChange(context, () => store.setThemeMode(mode)),
                  title: Text(AppTheme.label(mode)),
                  subtitle: Text(switch (mode) {
                    'system' => '跟随设备的浅色/深色设置',
                    'light' => '始终使用浅色',
                    _ => '始终使用深色',
                  }),
                  trailing: Icon(
                    store.themeMode == mode
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: store.themeMode == mode
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          ContentSection.group(
            title: '内容显示',
            children: [
              SwitchListTile(
                key: const ValueKey('hide-vip-setting'),
                value: store.hideVip,
                title: const Text('隐藏 VIP 试看集'),
                subtitle: const Text('仅在支持 VIP 标记的站源生效，可随时关闭。'),
                onChanged: (value) =>
                    saveUserChange(context, () => store.setHideVip(value)),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _PlaybackPane extends StatelessWidget {
  const _PlaybackPane({required this.store});
  final LocalStore store;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final preferences = store.playbackPreferences;
      Future<void> save(PlaybackPreferences next) =>
          saveUserChange(context, () => store.setPlaybackPreferences(next));
      return _PaneScaffold(
        title: '播放偏好',
        sections: [
          ContentSection.group(
            title: '默认播放',
            description: '每次进入播放器时沿用这里的设置，播放中仍可随时调整。',
            children: [
              ListTile(
                title: const Text('默认倍速'),
                subtitle: Text('${preferences.speed}x'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final speed = await showDialog<double>(
                    context: context,
                    builder: (context) => SimpleDialog(
                      title: const Text('默认倍速'),
                      children: [
                        for (final value in const [
                          0.5,
                          0.75,
                          1.0,
                          1.25,
                          1.5,
                          2.0,
                        ])
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(context, value),
                            child: Text('$value x'),
                          ),
                      ],
                    ),
                  );
                  if (speed != null) {
                    await save(preferences.copyWith(speed: speed));
                  }
                },
              ),
              ListTile(
                title: const Text('默认画质'),
                subtitle: Text(
                  preferences.quality == 0
                      ? '自动 · 优先高清'
                      : '${preferences.quality}P',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final quality = await showDialog<int>(
                    context: context,
                    builder: (context) => SimpleDialog(
                      title: const Text('默认画质'),
                      children: [
                        for (final value in DownloadPreferences.qualities)
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(context, value),
                            child: Text(value == 0 ? '自动 · 优先高清' : '$value P'),
                          ),
                      ],
                    ),
                  );
                  if (quality != null) {
                    await save(preferences.copyWith(quality: quality));
                  }
                },
              ),
            ],
          ),
          ContentSection.group(
            title: '行为',
            children: [
              SwitchListTile(
                value: preferences.autoAdvance,
                title: const Text('播完自动下一集'),
                onChanged: (value) =>
                    save(preferences.copyWith(autoAdvance: value)),
              ),
              SwitchListTile(
                value: preferences.danmaku,
                title: const Text('默认开启弹幕'),
                subtitle: const Text('只有红果站源提供弹幕数据。'),
                onChanged: (value) =>
                    save(preferences.copyWith(danmaku: value)),
              ),
              SwitchListTile(
                value: preferences.preload,
                title: const Text('预加载下一集'),
                subtitle: const Text('提前建立连接，切换分集更快。'),
                onChanged: (value) =>
                    save(preferences.copyWith(preload: value)),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _LanPane extends StatelessWidget {
  const _LanPane();

  @override
  Widget build(BuildContext context) {
    final controller = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(lanControllerProvider);
    return LanSyncScreen(controller: controller);
  }
}

class _DiaryPane extends StatefulWidget {
  const _DiaryPane();

  @override
  State<_DiaryPane> createState() => _DiaryPaneState();
}

class _DiaryPaneState extends State<_DiaryPane> {
  @override
  void initState() {
    super.initState();
    unawaited(DiaryService.refreshNativeLogs());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SettingsDetailScaffold(
      title: '播放日记',
      actions: [
        TextButton(
          onPressed: () => DiaryService.copyToClipboard(context),
          child: const Text('复制'),
        ),
        TextButton(
          onPressed: () => setState(DiaryService.clear),
          child: const Text('清空'),
        ),
        const SizedBox(width: 8),
      ],
      body: ValueListenableBuilder<int>(
        valueListenable: DiaryService.revision,
        builder: (context, _, _) {
          final entries = DiaryService.entries;
          if (entries.isEmpty) {
            return const StatusPanel(
              title: '暂无日记',
              message: '播放或加载站源内容后这里会记录详细事件。',
              icon: Icons.receipt_long_rounded,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            itemCount: entries.length,
            separatorBuilder: (_, _) =>
                Divider(height: 1, color: colors.outlineVariant),
            itemBuilder: (context, index) => SelectableText(
              entries[index],
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        },
      ),
    );
  }
}

class _BackupPane extends StatefulWidget {
  const _BackupPane({required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;

  @override
  State<_BackupPane> createState() => _BackupPaneState();
}

class _BackupPaneState extends State<_BackupPane> {
  bool _busy = false;
  String? _message;

  Future<void> _backup(bool restore) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!restore) {
        final content = await widget.store.exportBackup();
        final saved = await FilePicker.saveFile(
          fileName:
              '$appSlug-backup-'
              '${DateTime.now().toIso8601String().substring(0, 10)}.json',
          bytes: Uint8List.fromList(utf8.encode(content)),
          mimeType: 'application/json',
        );
        if (saved != null && mounted) setState(() => _message = '备份已保存');
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
        final data = widget.store.validateBackup(content);
        if (!mounted) return;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('恢复备份？'),
            content: Text(
              '包含 ${(data['profiles'] as List).length} 个用户。'
              '将替换本机的用户、追剧、观看记录和偏好设置；已下载视频保留。'
              '恢复后使用备份内的管理员密码登录。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('恢复'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        await widget.store.importBackup(content);
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => _PaneScaffold(
      title: '备份与恢复',
      sections: [
        ContentSection.group(
          title: '配置备份',
          description: '包含本地用户、追剧、历史和设置，不含视频文件。',
          children: [
            ListTile(
              enabled: !_busy,
              leading: const Icon(Icons.backup_outlined),
              title: const Text('导出配置备份'),
              onTap: () => _backup(false),
            ),
            ListTile(
              enabled: !_busy,
              leading: const Icon(Icons.restore),
              title: const Text('恢复配置备份'),
              subtitle: const Text('替换本机数据，请谨慎操作'),
              onTap: () => _backup(true),
            ),
          ],
        ),
        ContentSection.group(
          title: '下载导出',
          children: [
            SwitchListTile(
              value: widget.store.autoExport,
              title: const Text('下载完成后自动导出 Emby'),
              subtitle: const Text(
                '在下载目录的 exports 中生成视频和海报 URL 元数据，'
                '可将该目录加入 Emby 媒体库。',
              ),
              onChanged: _busy
                  ? null
                  : (value) async {
                      try {
                        if (value) {
                          await BackgroundDownloads.ensureStarted();
                        }
                        await widget.store.setAutoExport(value);
                      } catch (error) {
                        if (mounted) {
                          setState(() => _message = error.toString());
                        }
                      }
                    },
            ),
            SwitchListTile(
              value: widget.store.exportPosters,
              title: const Text('同时导出海报文件'),
              subtitle: const Text(
                '默认只写海报 URL；'
                '源站海报需要解密或外部读取失败时可开启。',
              ),
              onChanged: _busy
                  ? null
                  : (value) => saveUserChange(
                      context,
                      () => widget.store.setExportPosters(value),
                    ),
            ),
          ],
        ),
        if (_busy || _message != null)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(_message!),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _AboutPane extends StatelessWidget {
  const _AboutPane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _PaneScaffold(
      title: '关于',
      sections: [
        ContentSection.group(
          title: appName,
          description: 'v${AppLayout.versionOf(context)}',
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_fill_rounded),
              title: const Text('独立运行'),
              subtitle: const Text('打开即可浏览和播放，观看记录与追剧收藏保存在当前设备。'),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('站源规则'),
              subtitle: const Text('仅红果内置，其他站源需在规则管理中手动安装。'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/sources'),
            ),
            ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: const Text('隐私'),
              subtitle: const Text('不上传观看数据；网络请求只用于取回你选择的站源内容。'),
            ),
          ],
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${theme.platform} · $appSlug',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 下载目录与空间。
class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final info = await widget.repository.storage();
      if (mounted) {
        setState(() {
          _info = info;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _move() async {
    String? parent;
    if (isAndroidPlatform || isIOSPlatform) {
      final support = await getApplicationSupportDirectory();
      final directories = <String, String>{support.path: '应用内部存储'};
      if (isAndroidPlatform) {
        final external = await getExternalStorageDirectories() ?? [];
        for (var i = 0; i < external.length; i++) {
          directories[external[i].path] = i == 0
              ? '设备共享存储（应用目录）'
              : 'SD 卡 ${i + 1}（应用目录）';
        }
      } else {
        final documents = await getApplicationDocumentsDirectory();
        directories[documents.path] = '文件 App 可见目录';
      }
      if (!mounted) return;
      parent = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择下载位置'),
          children: [
            for (final entry in directories.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
      );
    } else {
      parent = await FilePicker.getDirectoryPath(dialogTitle: '选择下载保存位置');
    }
    if (parent == null || !mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('迁移已下载内容？'),
        content: Text(
          '将视频、合并成品及导出内容迁移到：\n$parent\n\n下载会先暂停，复制成功后清理旧目录。'
          '请保证目标有足够空间，并在完成后继续下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('迁移'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.moveDownloads(parent);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: '下载目录与空间',
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_info != null) ...[
              Text(
                '已使用 ${storageSize((_info!['bytes'] as num?)?.toInt() ?? 0)}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                '剩余 '
                '${storageSize((_info!['free'] as num?)?.toInt() ?? -1)} · '
                '${_info!['files'] ?? 0} 个文件',
              ),
              const SizedBox(height: 24),
              const Text('当前下载目录'),
              const SizedBox(height: 8),
              SelectableText(_info!['directory'] as String? ?? ''),
              TextButton.icon(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: _info!['directory'] as String? ?? ''),
                ),
                icon: const Icon(Icons.copy),
                label: const Text('复制路径'),
              ),
              const SizedBox(height: 20),
              const Text(
                '在下载页删除不需要的分集，在本地媒体页删除合并成品或 Emby 导出，'
                '可释放空间。',
              ),
            ],
            if (_busy || (_info == null && _error == null))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: LinearProgressIndicator(),
              ),
            if (_busy) const Text('正在迁移，请保持应用运行…'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_error!),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _move,
              icon: const Icon(Icons.drive_file_move_outline),
              label: const Text('更改并迁移目录'),
            ),
            TextButton(
              onPressed: _busy ? null : _refresh,
              child: const Text('刷新用量'),
            ),
          ],
        ),
      ),
    ),
  );
}
