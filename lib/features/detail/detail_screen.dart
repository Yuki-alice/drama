import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/app/app_screen.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/app/router.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/core/hongguo_series.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/detail/detail_view_model.dart';
import 'package:duanju_app/features/detail/download_picker.dart';
import 'package:duanju_app/features/detail/episode_browser.dart';
import 'package:duanju_app/features/sources/sources_screen.dart';
import 'package:duanju_app/widgets/drama_labels.dart';
import 'package:duanju_app/widgets/remote_widgets.dart';
import 'package:duanju_app/widgets/widgets.dart';

/// 条目详情的三档形态，断点与 Animeko SubjectDetailsPaneKind 对齐。
enum _DetailPane { compact, medium, expanded }

_DetailPane _detailPaneOf(double width) => switch (width) {
  < 600 => _DetailPane.compact,
  < 1600 => _DetailPane.medium,
  _ => _DetailPane.expanded,
};

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    this.resumeOnOpen = false,
    this.downloadOnOpen = false,
  });
  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final bool resumeOnOpen;
  final bool downloadOnOpen;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final DetailViewModel _model;
  bool _expandedDescription = false;
  bool _showEpisodes = false;
  final _scroll = ScrollController();
  final _episodeAnchor = GlobalKey();

  DramaDetail? get _detail => _model.detail;
  String? get _error => _model.error;
  bool get _loading => _model.loading;
  int get _episodePage => _model.episodePage;

  Widget? get _sourceDiagnostics => widget.repository.supportsSourceManagement
      ? SourceDiagnosticsButton(
          repository: widget.repository,
          store: widget.store,
          drama: widget.drama,
        )
      : null;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    _model = DetailViewModel(
      repository: widget.repository,
      store: widget.store,
      drama: widget.drama,
      persist: (action) => saveUserChange(context, action),
    )..addListener(_onModelChanged);
    _model.load(
      resumeOnOpen: widget.resumeOnOpen,
      downloadOnOpen: widget.downloadOnOpen,
    );
  }

  @override
  void didUpdateWidget(covariant DetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    widget.store.removeListener(_onStoreChanged);
    _model.removeListener(_onModelChanged);
    _model.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _onModelChanged() {
    if (!mounted) return;
    setState(() {});
    final action = _model.takeInitialAction();
    if (action == DetailInitialAction.resume) {
      unawaited(_play(_model.resumeIndex, resume: true));
    } else if (action == DetailInitialAction.download) {
      unawaited(_download());
    }
  }

  Future<void> _download() async {
    final detail = _detail;
    if (detail == null || !widget.store.canDownload) return;
    final selection = await Navigator.of(context).push<DownloadSelection>(
      MaterialPageRoute(
        builder: (_) => DownloadPicker(
          detail: detail,
          preferences: widget.store.downloadPreferences,
        ),
      ),
    );
    if (selection == null || !mounted || !widget.store.canDownload) return;
    try {
      final added = await widget.repository.enqueueDownloads(
        detail,
        selection.episodes,
        quality: selection.quality,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
          action: SnackBarAction(
            label: '查看',
            onPressed: () => context.push('/downloads'),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _play(int index, {bool resume = false}) async {
    final detail = _detail;
    if (detail == null ||
        index < 0 ||
        index >= detail.episodes.length ||
        !widget.store.allowsSource(detail.drama.source)) {
      return;
    }
    if (detail.episodes[index].vip &&
        detail.drama.source != SourceSite.dsd.id) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这是一集 VIP 内容'),
          content: const Text('站源可能只提供试看或限制播放。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('尝试播放'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    final saved = widget.store.watched(detail.drama.id);
    final position =
        resume &&
            saved?.episode == detail.episodes[index].number &&
            !saved!.finished
        ? saved.position
        : 0.0;
    if (!mounted) return;
    await context.push(
      '/player',
      extra: PlayerRouteArgs(
        detail: detail,
        initialIndex: index,
        initialPosition: position,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSeriesDrama(Drama drama) async {
    if (drama.id == (_detail?.drama.id ?? widget.drama.id)) return;
    final anchor = _detail?.drama ?? widget.drama;
    if (widget.store.following(anchor.id)?.seriesSeasons[drama.id]?.read ==
        false) {
      await saveUserChange(
        context,
        () => widget.store.markSeriesSeasonRead(anchor.id, drama.id),
      );
      if (!mounted) return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  void _locateEpisode(int index) {
    _model.setEpisodePage(index ~/ episodePageSize);
    setState(() => _showEpisodes = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _episodeAnchor.currentContext;
      if (!mounted || context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: .15,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final drama = _detail?.drama ?? widget.drama;
    final watched = widget.store.watched(drama.id);
    final episodes = _detail?.episodes ?? const <Episode>[];
    final allowed = widget.store.allowsSource(drama.source);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: LayoutBuilder(
        builder: (context, outer) {
          final pane = _detailPaneOf(outer.maxWidth);
          return AppScreen(
            title: drama.title,
            floatingTitle: true,
            actions: [
              RefreshAction(
                loading: _loading,
                tooltip: '更新剧集信息',
                onPressed: allowed ? _model.load : null,
              ),
            ],
            bottomBar: pane == _DetailPane.compact && allowed
                ? _playBar(drama, episodes, watched)
                : null,
            body: !allowed
                ? const StatusPanel(title: '当前用户无权访问', message: '请返回剧库后重新选择。')
                : SingleChildScrollView(
                    controller: _scroll,
                    padding: EdgeInsets.zero,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1500),
                        child: pane == _DetailPane.compact
                            ? _compact(drama, episodes, watched)
                            : _columns(
                                drama,
                                episodes,
                                watched,
                                pane: pane,
                                width: outer.maxWidth,
                              ),
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }

  // region 紧凑单列

  Widget _compact(Drama drama, List<Episode> episodes, WatchEntry? watched) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(drama, width: 140),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: _titleBlock(drama, compact: true)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _followingControls(drama),
        ),
        _DetailTabs(
          episodes: episodes.length,
          selected: _showEpisodes ? 1 : 0,
          onSelect: (index) => setState(() => _showEpisodes = index == 1),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: _showEpisodes
              ? _episodeSection(drama, episodes, watched, width: 320)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _description(drama),
                    _tags(drama),
                    const SizedBox(height: AppSpacing.lg),
                    _infoTable(drama, episodes.length),
                    _seriesSelector(drama),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  // endregion

  // region 双栏 / 三栏

  Widget _columns(
    Drama drama,
    List<Episode> episodes,
    WatchEntry? watched, {
    required _DetailPane pane,
    required double width,
  }) {
    final sidebar = pane == _DetailPane.expanded ? 340.0 : 280.0;
    final rail = pane == _DetailPane.expanded ? 372.0 : 0.0;
    final gap = pane == _DetailPane.expanded ? 48.0 : 24.0;
    final center = width - sidebar - rail - gap * 2 - 64;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: sidebar,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _cover(drama, width: sidebar),
                const SizedBox(height: AppSpacing.lg),
                _playAction(drama, episodes, watched, expand: true),
                if (widget.repository.supportsDownloads &&
                    widget.store.canDownload) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _downloadAction(episodes, expand: true),
                ],
                const SizedBox(height: AppSpacing.md),
                _followingControls(drama, expand: true),
                const SizedBox(height: AppSpacing.lg),
                _statsRow(drama),
                const Divider(height: AppSpacing.xxl),
                _infoTable(drama, episodes.length),
                _tags(drama),
              ],
            ),
          ),
          SizedBox(width: gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _titleBlock(drama),
                const SizedBox(height: AppSpacing.lg),
                _description(drama),
                _seriesSelector(drama),
                const SizedBox(height: AppSpacing.lg),
                _episodeSection(
                  drama,
                  episodes,
                  watched,
                  width: math.max(240, center),
                ),
              ],
            ),
          ),
          if (rail > 0) ...[
            SizedBox(width: gap),
            SizedBox(
              width: rail,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _railCard('观看进度', _progressBody(drama, episodes, watched)),
                  _railCard('站源', _sourceBody(drama, watched)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _railCard(String title, Widget body) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
    child: Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppShapes.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          body,
        ],
      ),
    ),
  );

  Widget _progressBody(
    Drama drama,
    List<Episode> episodes,
    WatchEntry? watched,
  ) {
    if (watched == null || episodes.isEmpty) {
      return Text(
        '还没有观看记录，播放后会自动记住进度。',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.6,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '第 ${watched.episode} 集',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          '${formatPosition(watched.position)} / ${formatPosition(watched.duration)} · ${watched.finished ? '已看完' : '观看中'}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextButton(
          onPressed: () => _locateEpisode(
            math.max(
              0,
              episodes.indexWhere((e) => e.number == watched.episode),
            ),
          ),
          child: const Text('定位到这一集'),
        ),
      ],
    );
  }

  Widget _sourceBody(Drama drama, WatchEntry? watched) {
    final site = SourceSite.byId(drama.source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(site.name, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          watched == null
              ? '站源数据随剧库更新'
              : '最近观看 ${watched.updatedAt.toString().substring(0, 16)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (_detail?.warning.isNotEmpty == true) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            _detail!.warning,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_sourceDiagnostics != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _sourceDiagnostics!,
        ],
      ],
    );
  }

  // endregion

  // region 片段

  Widget _cover(Drama drama, {required double width}) => SizedBox(
    width: width,
    child: AspectRatio(
      aspectRatio: 849 / 1200,
      child: DramaCover(
        drama: drama,
        repository: widget.repository,
        radius: AppShapes.large,
      ),
    ),
  );

  Widget _titleBlock(Drama drama, {bool compact = false}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          drama.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: compact
              ? theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                )
              : theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _metaLine(drama),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        if (drama.source == 'huangdou')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              drama.vipStatus == null
                  ? 'VIP 状态待补齐'
                  : drama.vip
                  ? 'VIP 内容'
                  : '免费内容',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  String _metaLine(Drama drama) {
    final parts = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.category.isNotEmpty) drama.category,
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        releaseLabelOf(drama.releaseStatus),
    ];
    return parts.join(' · ');
  }

  Widget _statsRow(Drama drama) {
    final theme = Theme.of(context);
    final stats = <(String, String)>[
      (drama.episodes > 0 ? '${drama.episodes}' : '—', '总集数'),
      (drama.heat.isEmpty ? '—' : drama.heat, '热度'),
      (drama.onlineDate.isEmpty ? '—' : drama.onlineDate, '上线'),
    ];
    return Row(
      children: [
        for (final (value, label) in stats)
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.md,
                horizontal: 4,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppShapes.large),
              ),
              child: Column(
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _infoTable(Drama drama, int episodeCount) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('来源', SourceSite.byId(drama.source).name),
      ('分集', episodeCount > 0 ? '$episodeCount 集' : '待更新'),
      if (drama.category.isNotEmpty) ('分类', drama.category),
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        ('状态', releaseLabelOf(drama.releaseStatus)),
      if (drama.views.isNotEmpty) ('播放', drama.views),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('作品信息', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.md),
        for (final (key, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 56,
                  child: Text(
                    key,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _description(Drama drama) {
    if (drama.description.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('简介', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Text(
            drama.description,
            maxLines: _expandedDescription ? null : 3,
            overflow: _expandedDescription
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  setState(() => _expandedDescription = !_expandedDescription),
              child: Text(_expandedDescription ? '收起简介' : '展开简介'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tags(Drama drama) {
    if (drama.tags.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('标签', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in drama.tags.take(12))
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppShapes.small),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Text(tag, style: theme.textTheme.bodySmall),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seriesSelector(Drama drama) {
    final entries = hongguoSeriesEntries(
      drama,
      widget.store.seriesDramasFor(drama),
    );
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final notices = widget.store.following(drama.id)?.seriesSeasons ?? const {};
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('相关推荐', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in entries)
                ChoiceChip(
                  key: ValueKey('series-${entry.drama.id}'),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '${entry.label} · ${entry.drama.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (notices[entry.drama.id]?.read == false) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.fiber_new_rounded,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                  selected: entry.drama.id == drama.id,
                  onSelected: entry.drama.id == drama.id
                      ? null
                      : (_) => _openSeriesDrama(entry.drama),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _episodeSection(
    Drama drama,
    List<Episode> episodes,
    WatchEntry? watched, {
    required double width,
  }) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || episodes.isEmpty) {
      return StatusPanel(
        title: _error != null ? '剧集信息暂时不可用' : '暂时没有可播放的集数',
        message: _error ?? '可以更新剧集信息后重试。',
        onRetry: _model.load,
        secondaryAction: _sourceDiagnostics,
      );
    }
    final start = (_episodePage * episodePageSize).clamp(
      0,
      episodes.length - 1,
    );
    final visible = episodes.skip(start).take(episodePageSize).toList();
    final digits = episodes.fold<int>(
      1,
      (value, episode) => math.max(value, episode.number.toString().length),
    );
    final scale = MediaQuery.textScalerOf(context);
    final minimum = math.max(82.0, scale.scale(20) * digits * .65 + 40);
    final columns = ((width - 40) / minimum).floor().clamp(1, 12);
    final extent = math.max(54.0, scale.scale(20) + 30);
    final cellWidth = (width - (columns - 1) * 10.0 - 8) / math.max(1, columns);
    return Column(
      key: _episodeAnchor,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '选集 · ${episodes.length} 集'
                '${watched == null ? '' : ' · 当前第 ${watched.episode} 集'}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            TextButton(onPressed: () => _model.load(), child: const Text('刷新')),
          ],
        ),
        EpisodeRangeBar(
          episodes: episodes,
          page: _episodePage,
          title: '',
          currentNumber: watched?.episode,
          onLocate: _locateEpisode,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var index = 0; index < visible.length; index++)
                SizedBox(
                  width: cellWidth,
                  height: extent,
                  child: RemoteEpisodeButton(
                    key: ValueKey('episode-${visible[index].number}'),
                    number: visible[index].number,
                    vip: visible[index].vip,
                    current: visible[index].number == watched?.episode,
                    onPressed: () => _play(start + index),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _followingControls(Drama drama, {bool expand = false}) {
    final state = widget.store.following(drama.id);
    final theme = Theme.of(context);
    final menu = PopupMenuButton<String>(
      key: const ValueKey('follow-status'),
      tooltip: '追剧与观看状态',
      onSelected: (value) async {
        if (value == 'remove') {
          await saveUserChange(
            context,
            () => widget.store.toggleFavorite(drama),
          );
        } else {
          final status = FollowStatus.values.firstWhere(
            (status) => status.name == value,
          );
          await saveUserChange(
            context,
            () => widget.store.setFollowStatus(drama, status),
          );
        }
      },
      itemBuilder: (_) => [
        for (final status in FollowStatus.values)
          CheckedPopupMenuItem(
            value: status.name,
            checked: state?.status == status,
            child: Text(status.label),
          ),
        if (state != null)
          const PopupMenuItem(value: 'remove', child: Text('取消追剧')),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: state == null
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(AppShapes.full),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Icon(
              state?.status == FollowStatus.watched
                  ? Icons.check_circle_outline
                  : state == null
                  ? Icons.bookmark_add_outlined
                  : Icons.bookmark_rounded,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(state?.label ?? '加入追剧')),
            const Icon(Icons.expand_more_rounded, size: 18),
          ],
        ),
      ),
    );
    if (state == null || !state.hasUpdates) return menu;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        menu,
        ActionChip(
          label: Text('${state.updateLabel} · 标为已读'),
          onPressed: () => saveUserChange(
            context,
            () => widget.store.markUpdatesRead(drama.id),
          ),
        ),
      ],
    );
  }

  Widget _playAction(
    Drama drama,
    List<Episode> episodes,
    WatchEntry? watched, {
    bool expand = false,
  }) {
    final resumeIndex = resumeEpisodeIndex(episodes, watched);
    return FilledButton.icon(
      key: const ValueKey('start-play'),
      style: FilledButton.styleFrom(
        minimumSize: Size(expand ? double.infinity : 0, 52),
        shape: const StadiumBorder(),
      ),
      onPressed: episodes.isEmpty
          ? null
          : () => _play(resumeIndex, resume: true),
      icon: const Icon(Icons.play_arrow_rounded, size: 26),
      label: Text(
        watched != null && episodes.isNotEmpty
            ? '继续播放 · 第 ${episodes[resumeIndex].number} 集'
            : '立即播放',
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _downloadAction(List<Episode> episodes, {bool expand = false}) =>
      FilledButton.tonalIcon(
        key: const ValueKey('download-episodes'),
        style: FilledButton.styleFrom(
          minimumSize: Size(expand ? double.infinity : 0, 52),
          shape: const StadiumBorder(),
        ),
        onPressed: episodes.isEmpty ? null : _download,
        icon: const Icon(Icons.download_rounded, size: 22),
        label: const Text('下载选集'),
      );

  /// 紧凑端保留常驻播放条，宽屏的播放入口在左侧栏。
  Widget _playBar(Drama drama, List<Episode> episodes, WatchEntry? watched) {
    final resumeIndex = resumeEpisodeIndex(episodes, watched);
    return Material(
      color: AppSurfaces.of(context).navContainer,
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  if (widget.repository.supportsDownloads &&
                      widget.store.canDownload) ...[
                    IconButton.filledTonal(
                      tooltip: '下载选集',
                      onPressed: episodes.isEmpty ? null : _download,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(52, 52),
                      ),
                      icon: const Icon(Icons.download_rounded),
                    ),
                    const SizedBox(width: AppSpacing.md),
                  ],
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('start-play'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 52),
                      ),
                      onPressed: episodes.isEmpty
                          ? null
                          : () => _play(resumeIndex, resume: true),
                      icon: const Icon(Icons.play_arrow_rounded, size: 26),
                      label: Text(
                        watched != null && episodes.isNotEmpty
                            ? '继续播放 · 第 ${episodes[resumeIndex].number} 集'
                            : '立即播放',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // endregion
}

class _DetailTabs extends StatelessWidget {
  const _DetailTabs({
    required this.episodes,
    required this.selected,
    required this.onSelect,
  });
  final int episodes;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          for (final (index, label) in const [(0, '详情'), (1, '剧集')])
            Expanded(
              child: InkWell(
                onTap: () => onSelect(index),
                child: ColoredBox(
                  color: Colors.transparent,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        index == 1 ? '$label · $episodes' : label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: index == selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SizedBox(
                          height: 3,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            color: index == selected
                                ? theme.colorScheme.primary
                                : Colors.transparent,
                          ),
                        ),
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
}
