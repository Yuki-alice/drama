import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../router/routes.dart';
import '../../../core/theme/appearance_controller.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/tokens/glass_tier.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';

/// 设置页。
///
/// 二级页，`AppGlassScaffold` 包整页。玻璃不嵌套：外观分组的玻璃开关 / chips
/// 一律直接落在 body（背景是 `AppBackdrop`），绝不塞进 `GlassSurfaceCard`
/// ——玻璃套玻璃会静默降质；分组标题用 `SectionHeader`，普通行用 `InkWell`。
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final controller = ref.read(appearanceProvider.notifier);
    final colors = AppColors.of(context);

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
          const SectionHeader(title: '外观'),
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

          // ── 播放（W1 纯本地 mock，不持久化） ────────────────────
          const SectionHeader(title: '播放'),
          _ChipField(
            label: '默认清晰度',
            options: const <String>['标清', '高清', '超清'],
            selectedIndex: ref.watch(_playbackQualityProvider),
            onSelected: ref.read(_playbackQualityProvider.notifier).update,
          ),
          _SwitchRow(
            label: '自动连播下一集',
            value: ref.watch(_autoPlayNextProvider),
            onChanged: ref.read(_autoPlayNextProvider.notifier).update,
          ),

          // ── 下载（W1 纯本地 mock，不持久化） ────────────────────
          const SectionHeader(title: '下载'),
          _ChipField(
            label: '同时下载任务数',
            options: const <String>['1', '2', '3', '4', '5', '6'],
            selectedIndex: ref.watch(_downloadConcurrencyProvider) - 1,
            onSelected: (index) => ref
                .read(_downloadConcurrencyProvider.notifier)
                .update(index + 1),
          ),

          // ── 存储 ───────────────────────────────────────────────
          const SectionHeader(title: '存储'),
          _TappableRow(
            label: '清除缓存',
            value: '目录缓存',
            onTap: () => _clearCache(context, ref),
          ),

          // ── 关于 ───────────────────────────────────────────────
          const SectionHeader(title: '关于'),
          _TappableRow(
            label: '关于本应用',
            onTap: () => context.push(AppRoutes.about),
          ),
        ],
      ),
    );
  }

  /// 清除目录缓存（的 `CacheStore.clear()`），并重建仓库以清掉内存态
  /// （熔断计数与 in-flight 去重）。缓存只是加速手段，清除后下次进入页面会重新拉取。
  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final store = ref.read(cacheStoreProvider);
    if (store == null) {
      // 未注入缓存（widget 测试路径）：如实说明未启用，不假装清除成功。
      await _showPlaceholderDialog(context, '清除缓存');
      return;
    }
    await store.clear();
    ref.invalidate(catalogRepositoryProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('目录缓存已清除，再进入页面会重新拉取')));
  }
}

// ── 本地 mock 状态（W1 外壳，不持久化；仅用小型 Notifier，保持页面为
//    ConsumerWidget） ─────────────────────────────────────────────────────

/// 播放清晰度：0 标清 / 1 高清 / 2 超清。
final _playbackQualityProvider = NotifierProvider<_IntNotifier, int>(
  () => _IntNotifier(1),
);

/// 是否自动连播下一集。
final _autoPlayNextProvider = NotifierProvider<_BoolNotifier, bool>(
  () => _BoolNotifier(true),
);

/// 下载并发数（默认 2）。
final _downloadConcurrencyProvider = NotifierProvider<_IntNotifier, int>(
  () => _IntNotifier(2),
);

class _IntNotifier extends Notifier<int> {
  _IntNotifier(this._initial);

  final int _initial;

  @override
  int build() => _initial;

  void update(int value) => state = value;
}

class _BoolNotifier extends Notifier<bool> {
  _BoolNotifier(this._initial);

  final bool _initial;

  @override
  bool build() => _initial;

  void update(bool value) => state = value;
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

/// 「标签 + 一排 GlassChip」字段（主题 / 清晰度 / 并发数共用）。
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
              for (var index = 0; index < options.length; index++)
                GlassChip(
                  label: options[index],
                  onTap: () => onSelected(index),
                  selected: index == selectedIndex,
                  selectedColor: colors.accent.withValues(alpha: 0.28),
                  useOwnLayer: true,
                  quality: GlassQuality.standard,
                  labelStyle: AppText.callout.copyWith(
                    color: index == selectedIndex
                        ? colors.textPrimary
                        : colors.textSecondary,
                    fontWeight: index == selectedIndex
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                  semanticLabel: options[index],
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
