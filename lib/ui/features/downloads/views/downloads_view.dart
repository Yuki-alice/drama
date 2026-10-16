import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/services/rust_core.dart';
import '../../../../router/routes.dart';
import '../../../core/format.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../view_models/downloads_view_model.dart';

/// 下载管理页（W1 纯 UI 外壳 / mock 数据）。
class DownloadsView extends ConsumerWidget {
  const DownloadsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(downloadGroupsProvider);
    final colors = AppColors.of(context);

    return AppGlassScaffold(
      title: '下载管理',
      leading: GlassIconAction(
        icon: Icons.arrow_back_ios_new,
        semanticLabel: '返回',
        onPressed: () => context.pop(),
      ),
      body: groupsAsync.when(
        data: (groups) => groups.isEmpty
            ? const Center(child: EmptyView(message: '还没有下载任务'))
            : ContentWidthConstraint(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  children: <Widget>[
                    _SummaryCard(groups: groups, colors: colors),
                    for (final group in groups)
                      _DownloadGroupSection(group: group, colors: colors),
                  ],
                ),
              ),
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          message: _errorMessage(error),
          onRetry: () => ref.invalidate(downloadGroupsProvider),
        ),
      ),
    );
  }
}

/// 统一错误文案（[RustCoreException] 带错误码，其余直接 `toString`）。
String _errorMessage(Object error) =>
    error is RustCoreException ? '${error.msg}（${error.code}）' : '$error';

/// 顶部汇总统计（玻璃卡内仅放普通 Text / Row，避免玻璃套玻璃）。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.groups, required this.colors});

  final List<DownloadGroup> groups;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    var total = 0;
    var active = 0;
    var done = 0;
    for (final group in groups) {
      for (final task in group.tasks) {
        total++;
        if (task.status == DownloadStatus.downloading) active++;
        if (task.status == DownloadStatus.completed) done++;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.md,
        AppSpacing.gutter,
        AppSpacing.sm,
      ),
      child: GlassSurfaceCard(
        child: Row(
          children: <Widget>[
            Expanded(
              child: _Stat(label: '任务总数', value: '$total', colors: colors),
            ),
            Expanded(
              child: _Stat(label: '进行中', value: '$active', colors: colors),
            ),
            Expanded(
              child: _Stat(label: '已完成', value: '$done', colors: colors),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条统计项。
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.colors});

  final String label;
  final String value;
  final AppColors colors;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Text(value, style: AppText.title.copyWith(color: colors.textPrimary)),
      const SizedBox(height: AppSpacing.xs),
      Text(label, style: AppText.caption.copyWith(color: colors.textSecondary)),
    ],
  );
}

/// 单部剧的下载分组（标题 + 普通任务行）。
class _DownloadGroupSection extends StatelessWidget {
  const _DownloadGroupSection({required this.group, required this.colors});

  final DownloadGroup group;
  final AppColors colors;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      SectionHeader(
        title: group.drama.title,
        actionLabel: '已完成 ${group.completedCount}/${group.tasks.length}',
        onAction: () => context.push(AppRoutes.detail(group.drama.id)),
      ),
      for (final task in group.tasks) _TaskRow(task: task, colors: colors),
    ],
  );
}

/// 单条任务行（集号 + 状态 + 进度 + 大小/速度 + 操作，全部为普通控件）。
///
/// 已完成的行整行可点 → 直接进播放页离线播放（`playPlanProvider` 会走
/// `playLocal` 命中本地文件）。
class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task, required this.colors});

  final DownloadTask task;
  final AppColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final barColor = switch (task.status) {
      DownloadStatus.queued => colors.divider,
      DownloadStatus.paused => colors.textTertiary,
      _ => colors.accent,
    };
    final detail = _detailLine(task);

    return InkWell(
      // 只有已完成才整行可点：未完成的整行点击没有合理目标，
      // 误触会被当成「什么都点不动」。
      onTap: task.status == DownloadStatus.completed
          ? () => context.push(AppRoutes.player(task.dramaId, episode: task.episode))
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 52,
              child: Text(
                '第 ${task.episode} 集',
                style: AppText.callout.copyWith(color: colors.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _statusLine(task),
                    style: AppText.callout.copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.capsule),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 4,
                      backgroundColor: colors.divider,
                      valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    ),
                  ),
                  if (detail.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: task.status == DownloadStatus.failed
                            ? colors.textSecondary
                            : colors.textTertiary,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            IconButton(
              onPressed: () => downloadAction(ref, task),
              tooltip: _actionLabel(task.status),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _actionIcon(task.status),
                size: 18,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首行文案：状态 + 进度百分比（已完成不显示百分比，改由副行给体积）。
String _statusLine(DownloadTask task) => switch (task.status) {
  DownloadStatus.downloading ||
  DownloadStatus.paused ||
  DownloadStatus.queued =>
    '${task.status.label} · ${(task.progress * 100).round()}%',
  _ => task.status.label,
};

/// 副行：下载中给「已下/总量 · 速率」，失败给原因，已完成给体积。
///
/// 失败原因一律显示——Rust 的错误串（如“解析/网络”）是用户唯一能拿到的线索，
/// 隐藏它只会得到「点了下载没反应」的观感。
String _detailLine(DownloadTask task) => switch (task.status) {
  DownloadStatus.downloading => <String>[
    '${formatBytes(task.done)} / ${formatBytes(task.total)}',
    formatSpeed(task.speed),
  ].where((part) => part.isNotEmpty).join(' · '),
  DownloadStatus.completed => formatBytes(task.total),
  DownloadStatus.failed =>
    task.error.isEmpty ? '下载失败，点右侧重试' : task.error,
  _ => task.total > 0 ? formatBytes(task.total) : '',
};

/// 任务行右侧操作的图标（按状态切换语义）。
IconData _actionIcon(DownloadStatus status) => switch (status) {
  DownloadStatus.downloading => Icons.pause,
  DownloadStatus.paused => Icons.play_arrow,
  DownloadStatus.failed => Icons.refresh,
  DownloadStatus.completed => Icons.delete_outline,
  DownloadStatus.queued => Icons.close,
};

/// 任务行右侧操作的提示文案。
String _actionLabel(DownloadStatus status) => switch (status) {
  DownloadStatus.downloading => '暂停',
  DownloadStatus.paused => '继续',
  DownloadStatus.failed => '重试',
  DownloadStatus.completed => '删除',
  DownloadStatus.queued => '取消',
};
