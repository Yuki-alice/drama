import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/app/app_layout.dart';
import 'package:duanju_app/app/app_screen.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/widgets/expressive.dart';

/// 我的：个人中心（Kazumi 表达性布局）——统计、规则、历史/下载与偏好入口。
class MeScreen extends StatelessWidget {
  const MeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppScreen(
      title: '我的',
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.surfaceContainerHigh,
              foregroundColor: theme.colorScheme.onSurface,
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
            ),
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.tune_rounded, size: 20),
            label: const Text('设置'),
          ),
        ),
      ],
      body: AnimatedBuilder(
        animation: store,
        builder: (_, _) => _MeSpace(
          store: store,
          supportsDownloads:
              repository.supportsDownloads && store.canDownload,
        ),
      ),
    );
  }
}

class _MeSpace extends StatelessWidget {
  const _MeSpace({
    required this.store,
    required this.supportsDownloads,
  });

  final LocalStore store;
  final bool supportsDownloads;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = constraints.maxWidth >= 840 ? 32.0 : 16.0;
        final width = (constraints.maxWidth - inset * 2).clamp(0.0, 1120.0);
        final stack =
            width < 840 || MediaQuery.textScalerOf(context).scale(14) > 20;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SpaceHeading(),
                  const SizedBox(height: 20),
                  AdaptivePair(
                    stack: stack,
                    gap: 16,
                    first: _StatsPanel(
                      favorites: store.favorites.length,
                      history: store.history.length,
                      sources: store.sources.length,
                    ),
                    second: _RulesTile(
                      caption:
                          '${store.sources.length} 个已启用站源 · '
                          '按需安装更多规则',
                      onTap: () => context.push('/sources'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  AdaptivePair(
                    stack: stack,
                    gap: 16,
                    first: _ToolTile(
                      icon: Icons.history_rounded,
                      title: '历史记录',
                      caption:
                          '${store.history.length} 部最近观看 · '
                          '在追剧页切换查看',
                      color: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer,
                      foreground: Theme.of(
                        context,
                      ).colorScheme.onSecondaryContainer,
                      onTap: () => context.go('/follow?tab=history'),
                    ),
                    second: _ToolTile(
                      icon: Icons.downloading_rounded,
                      title: '下载与本地',
                      caption: supportsDownloads
                          ? '任务、合并队列与本地媒体库'
                          : '当前环境未开放本地下载',
                      color: Theme.of(
                        context,
                      ).colorScheme.tertiaryContainer,
                      foreground: Theme.of(
                        context,
                      ).colorScheme.onTertiaryContainer,
                      onTap: () => context.push('/downloads'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _PreferencesPanel(stack: stack),
                  const SizedBox(height: 16),
                  AdaptivePair(
                    stack: stack,
                    gap: 16,
                    first: _ToolTile(
                      icon: Icons.devices_rounded,
                      title: '设备互联',
                      caption: '局域网追剧同步与推送播放',
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh,
                      foreground: Theme.of(context).colorScheme.onSurface,
                      onTap: () => context.push('/settings?category=lan'),
                    ),
                    second: _ToolTile(
                      icon: Icons.info_outline_rounded,
                      title: '关于$appName',
                      caption:
                          'v${AppLayout.versionOf(context)} · '
                          '数据只保存在这台设备',
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh,
                      foreground: Theme.of(context).colorScheme.onSurface,
                      onTap: () => context.push('/settings?category=about'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SpaceHeading extends StatelessWidget {
  const _SpaceHeading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              '个人中心',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                height: 1.15,
              ),
            ),
          ),
        ),
        ShapeIcon(
          shape: ShapeKind.sun,
          icon: Icons.person_rounded,
          size: 56,
          color: theme.colorScheme.primaryContainer,
          foreground: theme.colorScheme.onPrimaryContainer,
        ),
      ],
    );
  }
}

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.favorites,
    required this.history,
    required this.sources,
  });

  final int favorites;
  final int history;
  final int sources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return _ExpressivePanel(
      color: colors.surfaceContainerHigh,
      radius: BorderRadius.circular(48),
      onTap: () => context.go('/follow'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '观看统计',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Metric(value: '$favorites', label: '追剧中'),
                _Metric(value: '$history', label: '最近观看'),
                _Metric(value: '$sources', label: '已启用站源'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 主规则入口：primary 容器 + 不对称圆角。
class _RulesTile extends StatelessWidget {
  const _RulesTile({required this.caption, required this.onTap});
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return _ExpressivePanel(
      color: colors.primaryContainer,
      radius: const BorderRadius.only(
        topLeft: Radius.circular(28),
        bottomLeft: Radius.circular(28),
        bottomRight: Radius.circular(28),
        topRight: Radius.circular(64),
      ),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                ShapeIcon(
                  shape: ShapeKind.clover,
                  icon: Icons.extension_rounded,
                  size: 52,
                  color: colors.primary,
                  foreground: colors.onPrimary,
                ),
                const Spacer(),
                _ArrowCue(
                  color: colors.primary.withValues(alpha: .16),
                  foreground: colors.onPrimaryContainer,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              '规则设置',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onPrimaryContainer,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.caption,
    required this.color,
    required this.foreground,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String caption;
  final Color color;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _ExpressivePanel(
      color: color,
      radius: BorderRadius.circular(28),
      foreground: foreground,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon, size: 30),
                const Spacer(),
                const Icon(Icons.arrow_forward_rounded, size: 20),
              ],
            ),
            const SizedBox(height: 26),
            Text(
              title,
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              caption,
              style: text.bodySmall?.copyWith(color: foreground, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreferencesPanel extends StatelessWidget {
  const _PreferencesPanel({required this.stack});
  final bool stack;

  static const _entries = [
    ('外观', Icons.palette_rounded, 'appearance'),
    ('播放', Icons.play_circle_rounded, 'playback'),
    ('网络', Icons.language_rounded, 'network'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final buttons = Flex(
      direction: stack ? Axis.vertical : Axis.horizontal,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _entries.length; i++) ...[
          if (i > 0) const SizedBox(width: 4, height: 4),
          if (stack) _button(context, i)
          else Expanded(child: _button(context, i)),
        ],
      ],
    );
    return _ExpressivePanel(
      color: colors.surfaceContainerLow,
      radius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                '偏好设置',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (stack) buttons else IntrinsicHeight(child: buttons),
          ],
        ),
      ),
    );
  }

  Widget _button(BuildContext context, int index) {
    final (label, icon, category) = _entries[index];
    final colors = Theme.of(context).colorScheme;
    final radius = stack
        ? BorderRadius.vertical(
            top: Radius.circular(index == 0 ? 24 : 8),
            bottom: Radius.circular(
              index == _entries.length - 1 ? 24 : 8,
            ),
          )
        : BorderRadius.horizontal(
            left: Radius.circular(index == 0 ? 24 : 8),
            right: Radius.circular(
              index == _entries.length - 1 ? 24 : 8,
            ),
          );
    return ExpressiveAction(
      color: colors.secondaryContainer,
      foreground: colors.onSecondaryContainer,
      radius: radius,
      onTap: () => context.push('/settings?category=$category'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28),
            const SizedBox(height: 10),
            Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArrowCue extends StatelessWidget {
  const _ArrowCue({required this.color, required this.foreground});
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 52,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(
        Icons.arrow_forward_rounded,
        color: foreground,
        size: 20,
      ),
    ),
  );
}

/// 可按压的整块面板：内容自绘，交互交给 ExpressiveAction。
class _ExpressivePanel extends StatelessWidget {
  const _ExpressivePanel({
    required this.color,
    required this.radius,
    required this.child,
    this.foreground,
    this.onTap,
  });

  final Color color;
  final BorderRadius radius;
  final Color? foreground;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => ExpressiveAction(
    color: color,
    foreground:
        foreground ?? Theme.of(context).colorScheme.onSurface,
    radius: radius,
    onTap: onTap,
    child: child,
  );
}
