import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/download_repository.dart';
import '../../../../data/services/rust_core.dart';
import '../../../../router/routes.dart';
import '../../../core/format.dart';
import '../../../core/playback/playback_settings.dart';
import '../../../core/theme/appearance_controller.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/tokens/glass_tier.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/lockups.dart';

/// 设置页。
///
/// 二级页，`AppGlassScaffold` 包整页。玻璃不嵌套：外观分组的玻璃开关 / chips
/// 一律直接落在 body（纯色底），绝不塞进 `GlassSurfaceCard`
/// ——玻璃套玻璃会静默降质；分组标题用 `SectionHead.paged`，普通行用 `InkWell`。
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final controller = ref.read(appearanceProvider.notifier);
    final playback = ref.watch(playbackSettingsProvider);
    final colors = AppColors.of(context);
    // 下载设置来自 Rust（`downloadSetConcurrency` 持久化在下载目录）。
    final downloads = ref.watch(downloadSettingsProvider).value;

    return AppGlassScaffold(
      title: '设置',
      leading: GlassIconAction(
        icon: Icons.arrow_back_ios_new,
        semanticLabel: '返回',
        onPressed: () => context.pop(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
        children: <Widget>[
          // ── 外观（接到真实设置，持久化） ────────────────────────
          const SectionHead.paged(title: '外观'),
          _ChipField(
            label: '主题',
            options: const <String>['跟随系统', '浅色', '深色'],
            selectedIndex: _themeModeIndex(appearance.themeMode),
            onSelected: (index) => controller.setThemeMode(_themeModes[index]),
          ),
          _SwitchRow(
            label: '大字模式',
            value: appearance.largeText,
            onChanged: (value) => controller.setTextScale(value ? 1.3 : 1.0),
          ),
          _SwitchRow(
            label: '高对比',
            value: appearance.highContrast,
            onChanged: controller.setHighContrast,
          ),
          _SwitchRow(
            label: '减弱动效',
            value: appearance.reduceMotion,
            onChanged: controller.setReduceMotion,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.sm,
              AppSpacing.gutter,
              AppSpacing.sm,
            ),
            child: Text(
              '当前玻璃档位由设备能力自动决定：Windows / Linux 上限 '
              '${platformGlassCeiling().label} 档，其余平台交由系统自适应。',
              style: AppText.caption.copyWith(color: colors.textTertiary),
            ),
          ),

          // ── 播放（接到真实偏好，持久化；播放页读同一份） ────────
          const SectionHead.paged(title: '播放'),
          _ChipField(
            label: '默认清晰度',
            options: PlaybackSettings.labels,
            selectedIndex: playback.quality,
            onSelected: ref.read(playbackSettingsProvider.notifier).setQuality,
          ),
          _SwitchRow(
            label: '自动连播下一集',
            value: playback.autoPlayNext,
            onChanged:
                ref.read(playbackSettingsProvider.notifier).setAutoPlayNext,
          ),
          _SwitchRow(
            label: '进入播放页立即播放',
            value: playback.autoPlayOnOpen,
            onChanged:
                ref.read(playbackSettingsProvider.notifier).setAutoPlayOnOpen,
          ),

          // ── 下载（并发数接到 Rust 真实设置；目录可搬迁） ───────────
          const SectionHead.paged(title: '下载'),
          _ChipField(
            label: '同时下载任务数',
            options: _concurrencyOptions,
            selectedIndex: _concurrencySelectedIndex(downloads),
            onSelected: (index) => _setConcurrency(context, ref, index + 1),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              AppSpacing.sm,
            ),
            child: Text(
              '每任务 ${downloads?.connections ?? DownloadSettings.fallbackConnections} '
              '条连接并发（总连接预算 ${DownloadSettings.maxParallel}×'
              '${DownloadSettings.fallbackConnections} 由 Rust 按任务数分摊）；'
              '总带宽受源站与网络限制，并非并发越高越快。',
              style: AppText.caption.copyWith(color: colors.textTertiary),
            ),
          ),
          _TappableRow(
            label: '下载目录',
            value: _shortDir(downloads?.dir ?? ''),
            onTap: () => _editDownloadDir(context, ref, downloads?.dir ?? ''),
          ),

          // ── 存储 ───────────────────────────────────────────────
          const SectionHead.paged(title: '存储'),
          _TappableRow(
            label: '清除缓存',
            value: '目录缓存',
            onTap: () => _clearCache(context, ref),
          ),

          // ── 关于 ───────────────────────────────────────────────
          const SectionHead.paged(title: '关于'),
          _TappableRow(
            label: '关于本应用',
            onTap: () => context.push(AppRoutes.about),
          ),
        ],
      ),
    );
  }

  /// 清除目录缓存（走 Rust `cacheClear`）。
  ///
  /// 缓存现在完全由 Rust 持有（`rust/core/src/cache.rs`），清缓存就是让 Rust
  /// 清掉内存快照与落盘文件、并重置榜单熔断计数；Dart 侧只需失效受影响的
  /// provider。缓存只是加速手段，清除后下次进入页面会重新拉取。
  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final holder = ref.read(rustCoreProvider);
    if (holder == null) {
      // 核心不可用：如实说明未启用，不假装清除成功。
      await _showPlaceholderDialog(context, '清除缓存');
      return;
    }
    final envelope = await holder.core.call('cacheClear');
    ref.invalidate(catalogRepositoryProvider);
    if (!context.mounted) return;
    final cleared = envelope['ok'] == true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleared
              ? '目录缓存已清除，再进入页面会重新拉取'
              : '清除缓存失败：${RustCoreException.fromEnvelope(envelope).code}',
        ),
      ),
    );
  }
}

// ── 下载设置（并发数 / 目录搬迁：均为 Rust 真实能力） ──────────────────

/// 并发数 chip 选项（1~6，与 Rust `MAX_PARALLEL_LIMIT` 一致）。
final List<String> _concurrencyOptions = <String>[
  for (var i = 1; i <= DownloadSettings.maxParallel; i++) '$i',
];

/// 当前生效的并发数落在哪个 chip 上（未取到设置时用保守默认值）。
int _concurrencySelectedIndex(DownloadSettings? settings) {
  final parallel = settings?.parallel ?? DownloadSettings.fallbackParallel;
  final index = parallel - 1;
  return index.clamp(0, DownloadSettings.maxParallel - 1);
}

/// 调整并发数（走 Rust `downloadSetConcurrency`；失败显式告知）。
Future<void> _setConcurrency(
  BuildContext context,
  WidgetRef ref,
  int parallel,
) async {
  final applied = await applyDownloadConcurrency(ref, parallel);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        applied == null
            ? '并发数未生效（可选范围 1~${DownloadSettings.maxParallel}）'
            : '同时下载 ${applied.parallel} 个任务，每任务 ${applied.connections} 条连接',
      ),
    ),
  );
}

/// 搬迁下载目录：弹出输入框让用户填目标路径 → 调 Rust `moveDownloads`。
///
/// 没有引入目录选择器插件（依赖越少越好），因此这里**由用户输入绝对路径**；
/// 搬迁是先停机再复制，可能耗时，故先把「正在搬迁」如实告诉用户。
Future<void> _editDownloadDir(
  BuildContext context,
  WidgetRef ref,
  String current,
) async {
  final controller = TextEditingController(text: current);
  final target = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('搬迁下载目录'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('填入目标目录的绝对路径；已下载的分集会一并搬迁，'
              '目标下若已有同名文件则中止（不会覆盖已有数据）。'),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: '目标目录',
              hintText: '例如：D:\\drama\\downloads',
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('搬迁'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (target == null || target.isEmpty || !context.mounted) return;

  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('正在搬迁下载目录…')));
  final result = await moveDownloadDir(ref, target);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        result == null
            ? '搬迁失败：目标不可创建或已存在同名文件'
            : '已搬迁 ${result.moved} 项（${formatBytes(result.bytes)}）到 ${result.dir}',
      ),
    ),
  );
}

/// 目录串过长时取尾部（用户关心的是「在哪」，不是完整前缀）。
String _shortDir(String dir) {
  if (dir.isEmpty) return '未初始化';
  if (dir.length <= 24) return dir;
  return '…${dir.substring(dir.length - 24)}';
}

const List<ThemeMode> _themeModes = <ThemeMode>[
  ThemeMode.system,
  ThemeMode.light,
  ThemeMode.dark,
];

int _themeModeIndex(ThemeMode mode) => switch (mode) {
      ThemeMode.system => 0,
      ThemeMode.light => 1,
      ThemeMode.dark => 2,
    };

// ── 行 / 字段组件（普通控件，非玻璃，故可安全放入 body） ───────────────

/// 「标签 + 玻璃开关」行。开关用 own-layer，独立于祖先玻璃层。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.gutter,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: AppText.body.copyWith(color: colors.textPrimary),
            ),
          ),
          GlassSwitch(
            value: value,
            onChanged: onChanged,
            useOwnLayer: true,
            quality: GlassQuality.standard,
            activeColor: colors.accent,
            semanticLabel: label,
          ),
        ],
      ),
    );
  }
}

/// 「标签 + 一排描边胶囊」字段（主题 / 清晰度 / 并发数共用）。
class _ChipField extends StatelessWidget {
  const _ChipField({
    required this.label,
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
  });

  final String label;
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.gutter,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: AppText.body.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              // 单选云统一用内容层描边胶囊：与首页分类、搜索标签同一套
              // 选中语言（墨色浅底 + 墨色加粗字），不再混用玻璃 chip——
              // 半透明墨底在浅色下会发灰，与「选中 = 墨色」的规则打架。
              for (var index = 0; index < options.length; index++)
                OutlinePill(
                  label: options[index],
                  selected: index == selectedIndex,
                  height: 38,
                  onTap: () => onSelected(index),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 可点击的普通行（右侧可选值文本 + chevron）。
class _TappableRow extends StatelessWidget {
  const _TappableRow({required this.label, required this.onTap, this.value});

  final String label;
  final VoidCallback onTap;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter,
          vertical: AppSpacing.lg,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: AppText.body.copyWith(color: colors.textPrimary),
              ),
            ),
            if (value != null)
              Text(
                value!,
                style: AppText.callout.copyWith(color: colors.textSecondary),
              ),
            const SizedBox(width: AppSpacing.xs),
            Icon(Icons.chevron_right, size: 18, color: colors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// W1 占位弹窗：说明该功能尚未实现。
Future<void> _showPlaceholderDialog(BuildContext context, String title) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: const Text('该功能属于 W1 纯 UI 外壳，具体实现将在后续版本补齐。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
