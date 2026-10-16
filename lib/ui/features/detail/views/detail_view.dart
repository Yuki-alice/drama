import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/repositories/catalog_repository.dart';
import '../../../../data/repositories/download_repository.dart';
import '../../../../data/repositories/progress_repository.dart';
import '../../../../domain/models/drama.dart';
import '../../../../domain/models/episode.dart';
import '../../../../router/routes.dart';
import '../../../core/errors.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/drama_cover.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/glass_top_bar.dart';
import '../../../core/widgets/lockups.dart';
import '../view_models/detail_view_model.dart';

/// 详情页（版式对齐参考截图：窄屏单栏、宽屏双栏）。
///
/// **页面背景 = 海报高斯模糊**（Kazumi 同款）：整页铺一层放大虚化的封面，
/// 顶部留足可读性，往下渐隐回纯色——下半页的选集/简介坐在实底色上，
/// 不会出现「文字压在花图上」。
///
/// 窄屏（< 900pt）单栏：小海报 + 标题/标签/状态、追剧行、[下载 | 开始观看]、
/// 水平选集条、可展开简介、题材标签。
/// 宽屏（≥ 900pt）双栏：左列海报 + 主操作 + 统计，右列标题/元信息/简介/
/// 选集网格（分组翻页）/题材。
///
/// 海报是**封面 Hero 的落点**：列表卡片点进来时封面从卡片位置飞到页内。
/// 落点要在路由转场开始前就存在，所以路由 `extra` 会带上卡片侧的
/// [Drama]（见 `widget.initial`）；数据未到时先用它渲染海报头，
/// 深链进入（extra 为 null）则走普通加载态。
class DetailView extends ConsumerStatefulWidget {
  const DetailView({
    super.key,
    required this.id,
    this.source = 'hongguo',
    this.initial,
  });

  final String id;

  /// 所属源（路由 `?source=` 携带，缺省主源；同 id 跨源是不同剧）。
  final String source;

  /// 列表卡片传来的剧目数据（Hero 落点用）；深链进入为 null。
  final Drama? initial;

  @override
  ConsumerState<DetailView> createState() => _DetailViewState();
}

/// 宽屏双栏的启用宽度（参考截图是桌面窗口，约 900pt 起排得开）。
const double _kWideBreakpoint = 900;

class _DetailViewState extends ConsumerState<DetailView> {
  /// 用户手动选中的分组；null = 自动（跟随续播所在组）。
  int? _groupIndex;

  /// 追剧写入进行中（忽略重复点击）。
  bool _togglingFollow = false;

  @override
  Widget build(BuildContext context) {
    final key = (id: widget.id, source: widget.source);
    final detailAsync = ref.watch(detailProvider(key));
    final initial = widget.initial;

    return detailAsync.when(
      data: (detail) => _body(context, drama: detail.drama, detail: detail),
      // 卡片数据在（列表进入）：先渲染海报头，选集区等数据。
      loading: () => initial == null
          ? _statusScaffold(
              context,
              const LoadingView(label: '正在加载剧集详情'),
            )
          : _body(context, drama: initial, detail: null),
      error: (error, _) {
        if (initial != null) {
          // 海报头已经渲染出来了：选集区展示失败 + 重试，别整页翻掉。
          return _body(context, drama: initial, detail: null, loadError: error);
        }
        return error is StateError
            ? _statusScaffold(
                context,
                const EmptyView(message: '未找到该剧集', icon: Icons.search_off),
              )
            : _statusScaffold(
                context,
                ErrorView(
                  message: errorMessage(error),
                  onRetry: () => ref.invalidate(
                      detailProvider((id: widget.id, source: widget.source))),
                ),
              );
      },
    );
  }

  // ── 页面骨架 ────────────────────────────────────────────────────

  /// 完整页：模糊背景 + 滚动内容 + 固定玻璃顶栏。
  Widget _body(
    BuildContext context, {
    required Drama drama,
    required DramaDetail? detail,
    Object? loadError,
  }) {
    final colors = AppColors.of(context);
    final key = (id: widget.id, source: widget.source);

    // 分组口径来自 Rust（`episodeGroups` op）；未就绪时整表兜底渲染。
    final groups = ref.watch(episodeGroupsProvider(key)).value;
    final episodes = detail?.episodes ?? const <Episode>[];
    final isFollowing = ref.watch(isFollowingProvider(key)).value ?? false;
    final resume = ref.watch(resumeProvider(key)).value;
    final currentEpisode = resume?.episode ?? 1;
    // 仅当「确实看过一部分」才叫续播：位置为 0 只是刚打开过。
    final hasResume = resume != null && resume.position > Duration.zero;

    final activeGroup = _activeGroupIndex(groups, currentEpisode);
    final visibleEpisodes = _visibleEpisodes(groups, episodes, currentEpisode);

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // ── 底：海报高斯模糊 ───────────────────────────────────
          _PosterBackdrop(drama: drama),

          // ── 中：滚动内容（窄屏单栏 / 宽屏双栏） ────────────────
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= _kWideBreakpoint;
              return ListView(
                padding: EdgeInsetsDirectional.only(
                  top: glassTopBarClearance(context) + AppSpacing.sm,
                  bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xxl,
                ),
                children: <Widget>[
                  Center(
                    child: ConstrainedBox(
                      // 宽屏收 1080 防拉伸；窄屏收 720（平板竖窗也能读）。
                      constraints: BoxConstraints(
                        maxWidth: wide ? 1080 : 720,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                        ),
                        child: wide
                            ? _wideContent(
                                drama: drama,
                                groups: groups,
                                episodes: visibleEpisodes,
                                activeGroup: activeGroup,
                                currentEpisode: currentEpisode,
                                isFollowing: isFollowing,
                                hasResume: hasResume,
                                detail: detail,
                                loadError: loadError,
                              )
                            : _compactContent(
                                drama: drama,
                                groups: groups,
                                episodes: visibleEpisodes,
                                activeGroup: activeGroup,
                                currentEpisode: currentEpisode,
                                isFollowing: isFollowing,
                                hasResume: hasResume,
                                detail: detail,
                                loadError: loadError,
                              ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),

          // ── 顶：固定玻璃栏（返回 + 分享 + 更多） ───────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: GlassIconAction(
                icon: Icons.arrow_back_ios_new_rounded,
                semanticLabel: '返回',
                onPressed: () => context.pop(),
              ),
              actions: <Widget>[
                GlassIconAction(
                  icon: Icons.ios_share_rounded,
                  semanticLabel: '分享',
                  onPressed: () => _notify(context, '分享尚未接入'),
                ),
                GlassIconAction(
                  icon: Icons.more_horiz_rounded,
                  semanticLabel: '更多',
                  onPressed: () => unawaited(
                    _showMoreSheet(context, drama, detail),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 无卡片数据的加载/错误态（深链进入）：纯色底 + 玻璃顶栏。
  Widget _statusScaffold(BuildContext context, Widget child) {
    final colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ListView(
            padding: EdgeInsets.only(
              top: glassTopBarClearance(context) + AppSpacing.md,
            ),
            children: <Widget>[child],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: '剧集详情',
              leading: GlassIconAction(
                icon: Icons.arrow_back_ios_new_rounded,
                semanticLabel: '返回',
                onPressed: () => context.pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 窄屏单栏（参考截图版式） ────────────────────────────────────

  Widget _compactContent({
    required Drama drama,
    required EpisodeGroups? groups,
    required List<Episode> episodes,
    required int activeGroup,
    required int currentEpisode,
    required bool isFollowing,
    required bool hasResume,
    required DramaDetail? detail,
    required Object? loadError,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _CompactHeader(drama: drama),
        const SizedBox(height: AppSpacing.xl),
        _ActionRows(
          isFollowing: isFollowing,
          hasResume: hasResume,
          currentEpisode: currentEpisode,
          onToggleFollow: () => unawaited(_toggleFollow(drama)),
          onDownload: () =>
              unawaited(_downloadEpisode(drama, detail, currentEpisode)),
          onPlay: () => _playEpisode(null),
        ),
        const SizedBox(height: AppSpacing.xl),
        _EpisodeSection(
          compact: true,
          groups: groups,
          episodes: episodes,
          activeGroup: activeGroup,
          currentEpisode: currentEpisode,
          loading: detail == null && loadError == null,
          loadError: loadError,
          onRetry: _retryDetail,
          onEpisodeTap: _playEpisode,
          onGroupChanged: (index) => setState(() => _groupIndex = index),
          onManageDownloads: () => context.push(AppRoutes.downloads),
        ),
        const SizedBox(height: AppSpacing.xl),
        _SynopsisSection(text: drama.summary),
        const SizedBox(height: AppSpacing.xl),
        if (drama.tags.isNotEmpty) _TagSection(tags: drama.tags),
      ],
    );
  }

  // ── 宽屏双栏（参考截图版式） ────────────────────────────────────

  Widget _wideContent({
    required Drama drama,
    required EpisodeGroups? groups,
    required List<Episode> episodes,
    required int activeGroup,
    required int currentEpisode,
    required bool isFollowing,
    required bool hasResume,
    required DramaDetail? detail,
    required Object? loadError,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // ── 左列：海报 + 主操作 + 统计 ──────────────────────────
        SizedBox(
          width: 268,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _WidePoster(drama: drama),
              const SizedBox(height: AppSpacing.lg),
              InkPill(
                label: hasResume ? '继续观看 第 $currentEpisode 集' : '开始观看',
                icon: Icons.play_arrow_rounded,
                height: 48,
                onTap: () => _playEpisode(null),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinePill(
                label: isFollowing ? '已追剧' : '追剧',
                icon: isFollowing
                    ? Icons.bookmark_added_rounded
                    : Icons.bookmark_add_outlined,
                selected: isFollowing,
                height: 44,
                onTap: _togglingFollow
                    ? null
                    : () => unawaited(_toggleFollow(drama)),
              ),
              const SizedBox(height: AppSpacing.lg),
              _StatsRow(
                episodeCount: drama.episodeCount,
                statusLabel: drama.status.label,
                hasResume: hasResume,
                currentEpisode: currentEpisode,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.xl + AppSpacing.md),

        // ── 右列：标题 / 元信息 / 简介 / 选集 / 题材 ────────────
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                drama.title,
                style: AppText.display.copyWith(
                  color: AppColors.of(context).textPrimary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (drama.categoryName.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  drama.categoryName,
                  style: AppText.callout.copyWith(
                    color: AppColors.of(context).textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Text(
                _metaLine(drama),
                style: AppText.mono.copyWith(
                  color: AppColors.of(context).textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              _Synopsis(text: drama.summary),
              const SizedBox(height: AppSpacing.xl),
              _EpisodeSection(
                compact: false,
                groups: groups,
                episodes: episodes,
                activeGroup: activeGroup,
                currentEpisode: currentEpisode,
                loading: detail == null && loadError == null,
                loadError: loadError,
                onRetry: _retryDetail,
                onEpisodeTap: _playEpisode,
                onGroupChanged: (index) => setState(() => _groupIndex = index),
                onManageDownloads: () => context.push(AppRoutes.downloads),
              ),
              const SizedBox(height: AppSpacing.xl),
              if (drama.tags.isNotEmpty) _TagSection(tags: drama.tags),
            ],
          ),
        ),
      ],
    );
  }

  // ── 分组口径 ────────────────────────────────────────────────────

  /// 生效分组下标：用户手选优先，否则自动定位续播所在组（没看过 → 第一组）。
  int _activeGroupIndex(EpisodeGroups? groups, int currentEpisode) {
    if (groups == null || groups.groups.isEmpty) return 0;
    if (_groupIndex != null) {
      return _groupIndex!.clamp(0, groups.groups.length - 1);
    }
    final auto = groups.groups.indexWhere(
      (group) => currentEpisode >= group.start && currentEpisode <= group.end,
    );
    return auto < 0 ? 0 : auto;
  }

  /// 当前分组要展示的剧集；分组结果未就绪时整表兜底。
  List<Episode> _visibleEpisodes(
    EpisodeGroups? groups,
    List<Episode> all,
    int currentEpisode,
  ) {
    if (groups == null || groups.groups.isEmpty) return all;
    return groups.groups[_activeGroupIndex(groups, currentEpisode)].episodes;
  }

  // ── 行为（沿用既有实现，仅入参适配渐进渲染） ────────────────────

  void _retryDetail() => ref.invalidate(
        detailProvider((id: widget.id, source: widget.source)),
      );

  /// 选集/主操作：锁定集必须**明示**原因，不得静默失败。
  void _playEpisode(Episode? episode) {
    final index = episode?.index ?? _resumeEpisodeOr1();
    if (episode != null && episode.locked) {
      _notify(
        context,
        '第 ${episode.index} 集需 App 授权（公开轨仅覆盖可试看集）',
      );
      return;
    }
    context.push(
      AppRoutes.player(widget.id, episode: index, source: widget.source),
    );
  }

  int _resumeEpisodeOr1() {
    final resume =
        ref.read(resumeProvider((id: widget.id, source: widget.source))).value;
    return resume?.episode ?? 1;
  }

  /// 切换追剧态：写入 Rust 持久化，成功后由 provider 失效驱动 UI 刷新。
  Future<void> _toggleFollow(Drama drama) async {
    final key = (id: widget.id, source: widget.source);
    final wasFollowing = ref.read(isFollowingProvider(key)).value ?? false;
    // 先取 messenger：避免 await 之后再用 BuildContext（跨异步间隙）。
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _togglingFollow = true);
    try {
      final actions = ref.read(progressActionsProvider);
      if (wasFollowing) {
        await actions.unfollow(ref, widget.id, source: widget.source);
      } else {
        await actions.follow(
          ref,
          id: widget.id,
          title: drama.title,
          cover: drama.cover,
          totalEpisode: drama.episodeCount,
          source: widget.source,
        );
      }
      messenger.showSnackBar(
        SnackBar(content: Text(wasFollowing ? '已取消追剧' : '已加入追剧')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('操作失败：${errorMessage(error)}')),
      );
    } finally {
      if (mounted) setState(() => _togglingFollow = false);
    }
  }

  /// 下载当前集：经 **provider 注入的仓库**调 Rust `downloadStart`。
  Future<void> _downloadEpisode(
    Drama drama,
    DramaDetail? detail,
    int episode,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (detail == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('剧集还没加载完，稍后再试')),
      );
      return;
    }
    try {
      final repo = ref.read(downloadRepositoryProvider);
      final vid = detail.episodes
          .where((e) => e.index == episode)
          .map((e) => e.vid ?? '')
          .firstWhere((v) => v.isNotEmpty, orElse: () => '');
      await repo.start(
        seriesId: widget.id,
        episode: episode,
        vid: vid,
        title: drama.title,
        cover: drama.cover,
        source: widget.source,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('已加入下载：第 $episode 集')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('下载失败：${errorMessage(error)}')),
      );
    }
  }

  /// 更多：低频动作收进 sheet。
  Future<void> _showMoreSheet(
    BuildContext context,
    Drama drama,
    DramaDetail? detail,
  ) async {
    final colors = AppColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: GlassSurfaceCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  drama.title,
                  style: AppText.title.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: AppSpacing.lg),
                _SheetRow(
                  icon: Icons.download_outlined,
                  label: '下载本集',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_downloadEpisode(drama, detail, 1));
                  },
                ),
                _SheetRow(
                  icon: Icons.ios_share_rounded,
                  label: '分享',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _notify(context, '分享尚未接入');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 元信息行：`已完结 · 全 82 集`。
String _metaLine(Drama drama) => <String>[
      drama.status.label,
      if (drama.episodeCount > 0) '全 ${drama.episodeCount} 集',
    ].join(' · ');

// ── 背景：海报高斯模糊 ────────────────────────────────────────────

/// 整页背景：海报放大 + 高斯模糊 + 可读性罩层。
///
/// 罩层分三段：顶部 52% 背景色（保住文字对比）→ 渐隐到纯色 → 纯色。
/// 效果与参考截图一致：上半页看得出「这是哪部剧的色调」，下半页是干净底。
class _PosterBackdrop extends StatelessWidget {
  const _PosterBackdrop({required this.drama});

  final Drama drama;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return RepaintBoundary(
      child: ColoredBox(
        color: colors.background,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 放大 1.18 再模糊：模糊会把边缘「吃」透明，放大一圈补回来。
            ClipRect(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                child: Transform.scale(
                  scale: 1.18,
                  child: _CoverFill(drama: drama),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    colors.background.withValues(alpha: .52),
                    colors.background.withValues(alpha: .52),
                    colors.background,
                    colors.background,
                  ],
                  stops: const <double>[0, .34, .58, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面填充（不透明内容层；无封面时回落确定性渐变）。
class _CoverFill extends StatelessWidget {
  const _CoverFill({required this.drama});

  final Drama drama;

  @override
  Widget build(BuildContext context) => DramaCover(
        seed: drama.coverSeed,
        cover: drama.cover,
        title: drama.title,
        radius: 0,
        showTitleOverlay: false,
        fill: true,
      );
}

// ── 窄屏组件 ─────────────────────────────────────────────────────

/// 窄屏头部：小海报（Hero 落点）+ 标题/标签/状态。
class _CompactHeader extends StatelessWidget {
  const _CompactHeader({required this.drama});

  final Drama drama;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 112,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: colors.mediaScrim.withValues(alpha: .18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: CoverHero(
              source: drama.source,
              id: drama.id,
              child: DramaCover(
                seed: drama.coverSeed,
                cover: drama.cover,
                title: drama.title,
                radius: AppRadii.lg,
                showTitleOverlay: false,
                fill: true,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                drama.title,
                style: AppText.title.copyWith(color: colors.textPrimary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  if (drama.categoryName.isNotEmpty)
                    _MetaChip(label: drama.categoryName),
                  if (drama.vip) const _MetaChip(label: 'VIP 预留'),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                _metaLine(drama),
                style: AppText.mono.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 窄屏操作区：追剧行（参考截图的「登录后可收藏」位）+ [下载 | 开始观看]。
class _ActionRows extends StatelessWidget {
  const _ActionRows({
    required this.isFollowing,
    required this.hasResume,
    required this.currentEpisode,
    required this.onToggleFollow,
    required this.onDownload,
    required this.onPlay,
  });

  final bool isFollowing;
  final bool hasResume;
  final int currentEpisode;
  final VoidCallback onToggleFollow;
  final VoidCallback onDownload;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            // 左：真实的观看进度（没有记录时收起，按钮贴右缘）。
            Expanded(
              child: hasResume
                  ? Text(
                      '上次看到 第 $currentEpisode 集',
                      style: AppText.mono.copyWith(
                        fontSize: 11.5,
                        color: AppColors.of(context).textSecondary,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            OutlinePill(
              label: isFollowing ? '已追剧' : '追剧',
              icon: isFollowing
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_add_outlined,
              selected: isFollowing,
              height: 40,
              onTap: onToggleFollow,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: <Widget>[
            _SquareAction(
              icon: Icons.download_outlined,
              semanticLabel: '下载本集',
              onTap: onDownload,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: InkPill(
                label: hasResume ? '继续观看 第 $currentEpisode 集' : '开始观看',
                icon: Icons.play_arrow_rounded,
                height: 48,
                onTap: onPlay,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 方形图标钮（下载等次级动作，内容层非玻璃）。
class _SquareAction extends StatelessWidget {
  const _SquareAction({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Material(
          color: colors.contentSurface,
          shape: AppRadii.shape(AppRadii.md),
          child: InkWell(
            onTap: onTap,
            customBorder: AppRadii.shape(AppRadii.md),
            child: Center(
              child: Icon(icon, size: 20, color: colors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

/// 题材小胶囊（描边款，参考截图的「2011年4月」位）。
class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.capsule),
        border: Border.all(color: colors.borderStrong),
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

// ── 宽屏组件 ─────────────────────────────────────────────────────

/// 宽屏左列海报（全列宽、Hero 落点）。
class _WidePoster extends StatelessWidget {
  const _WidePoster({required this.drama});

  final Drama drama;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.xl),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: colors.mediaScrim.withValues(alpha: .22),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: CoverHero(
          source: drama.source,
          id: drama.id,
          child: DramaCover(
            seed: drama.coverSeed,
            cover: drama.cover,
            title: drama.title,
            radius: AppRadii.xl,
            showTitleOverlay: false,
            fill: true,
          ),
        ),
      ),
    );
  }
}

/// 宽屏左列统计行（参考截图的 收藏/在看/想看 位，只放真实数据）。
class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.episodeCount,
    required this.statusLabel,
    required this.hasResume,
    required this.currentEpisode,
  });

  final int episodeCount;
  final String statusLabel;
  final bool hasResume;
  final int currentEpisode;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        if (episodeCount > 0)
          Expanded(
            child: _Stat(value: '$episodeCount', label: '总集数'),
          ),
        Expanded(
          child: _Stat(value: statusLabel, label: '状态'),
        ),
        if (hasResume)
          Expanded(
            child: _Stat(value: '第 $currentEpisode 集', label: '看到'),
          ),
      ],
    );
  }
}

/// 统计项：等宽数值 + 三级小标签（参考截图的数值在上、标签在下）。
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          value,
          style: AppText.mono.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppText.caption.copyWith(color: colors.textTertiary),
        ),
      ],
    );
  }
}

// ── 选集 ────────────────────────────────────────────────────────

/// 选集区：窄屏 = 标题 + 分组胶囊 + 水平集条；宽屏 = 标题 + 下载管理 +
/// 分组翻页 + 网格。
class _EpisodeSection extends StatelessWidget {
  const _EpisodeSection({
    required this.compact,
    required this.groups,
    required this.episodes,
    required this.activeGroup,
    required this.currentEpisode,
    required this.loading,
    required this.loadError,
    required this.onRetry,
    required this.onEpisodeTap,
    required this.onGroupChanged,
    required this.onManageDownloads,
  });

  final bool compact;
  final EpisodeGroups? groups;
  final List<Episode> episodes;
  final int activeGroup;
  final int currentEpisode;
  final bool loading;
  final Object? loadError;
  final VoidCallback onRetry;
  final ValueChanged<Episode> onEpisodeTap;
  final ValueChanged<int> onGroupChanged;
  final VoidCallback onManageDownloads;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final hasGroups = groups != null && groups!.groups.length > 1;
    final total = groups?.total ?? episodes.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (compact)
          SectionHead(title: '选集', subtitle: '共 $total 集')
        else
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.lg,
              bottom: AppSpacing.md,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '选集',
                    style: AppText.title.copyWith(color: colors.textPrimary),
                  ),
                ),
                _LinkButton(
                  label: '下载管理',
                  onTap: onManageDownloads,
                ),
                if (hasGroups) ...<Widget>[
                  const SizedBox(width: AppSpacing.sm),
                  _GroupPager(
                    group: groups!.groups[activeGroup],
                    total: groups!.total,
                    canPrev: activeGroup > 0,
                    canNext: activeGroup < groups!.groups.length - 1,
                    onPrev: () => onGroupChanged(activeGroup - 1),
                    onNext: () => onGroupChanged(activeGroup + 1),
                  ),
                ],
              ],
            ),
          ),
        if (hasGroups && compact) ...<Widget>[
          ChipStrip(
            padding: EdgeInsets.zero,
            children: <Widget>[
              for (final group in groups!.groups)
                OutlinePill(
                  label: group.label,
                  selected: group.index == activeGroup,
                  height: 36,
                  onTap: () => onGroupChanged(group.index),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (loadError != null)
          InlineRetry(
            message: '选集加载失败：${errorMessage(loadError!)}',
            onRetry: onRetry,
          )
        else if (loading)
          const LoadingView(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            label: '正在加载选集',
          )
        else if (episodes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Text(
              '暂无剧集',
              style: AppText.callout.copyWith(color: colors.textTertiary),
            ),
          )
        else if (compact)
          _EpisodeStrip(
            episodes: episodes,
            current: currentEpisode,
            onEpisodeTap: onEpisodeTap,
          )
        else
          _EpisodeGrid(
            episodes: episodes,
            current: currentEpisode,
            onEpisodeTap: onEpisodeTap,
          ),
      ],
    );
  }
}

/// 窄屏选集条：水平滚动的集卡（参考截图的 01/02/03 卡片）。
class _EpisodeStrip extends StatelessWidget {
  const _EpisodeStrip({
    required this.episodes,
    required this.current,
    required this.onEpisodeTap,
  });

  final List<Episode> episodes;
  final int current;
  final ValueChanged<Episode> onEpisodeTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 66,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: episodes.length,
          separatorBuilder: (context, index) =>
              const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, index) {
            final episode = episodes[index];
            return _EpisodeChip(
              episode: episode,
              current: episode.index == current,
              onTap: () => onEpisodeTap(episode),
            );
          },
        ),
      );
}

/// 集卡：集号 + 集标题（窄屏横条与宽屏网格共用同一张卡）。
class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({
    required this.episode,
    required this.current,
    required this.onTap,
  });

  final Episode episode;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final foreground = current ? colors.onInk : colors.textPrimary;
    final label =
        episode.locked ? '第 ${episode.index} 集，需授权' : '第 ${episode.index} 集';
    return Semantics(
      button: true,
      selected: current,
      label: label,
      child: PressableScale(
        scale: .94,
        borderRadius: AppRadii.md,
        onTap: onTap,
        child: Container(
          width: 118,
          height: 64,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            // 选中 = 墨色填充 + 反白字（重型填充色；绿色留给进度与状态）。
            color: current ? colors.textPrimary : colors.sunken,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: current ? colors.textPrimary : colors.divider,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    episode.locked
                        ? Icons.lock_outline_rounded
                        : Icons.graphic_eq_rounded,
                    size: 12,
                    color: foreground,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    episode.index.toString().padLeft(2, '0'),
                    style: AppText.mono.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                episode.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: current ? colors.onInk : colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 宽屏选集网格：列数随右列宽度（约 5 列起步），集卡同窄屏版式。
class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({
    required this.episodes,
    required this.current,
    required this.onEpisodeTap,
  });

  final List<Episode> episodes;
  final int current;
  final ValueChanged<Episode> onEpisodeTap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final columns = math.max(3, (constraints.maxWidth / 150).floor());
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              mainAxisExtent: 64,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              return _EpisodeChip(
                episode: episode,
                current: episode.index == current,
                onTap: () => onEpisodeTap(episode),
              );
            },
          );
        },
      );
}

/// 分组翻页（参考截图的 `< 1-10 / 24 >`）。
class _GroupPager extends StatelessWidget {
  const _GroupPager({
    required this.group,
    required this.total,
    required this.canPrev,
    required this.canNext,
    required this.onPrev,
    required this.onNext,
  });

  final EpisodeGroup group;
  final int total;
  final bool canPrev;
  final bool canNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: '上一组',
          onPressed: canPrev ? onPrev : null,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(
            minWidth: AppSpacing.minTapTarget,
            minHeight: AppSpacing.minTapTarget,
          ),
          icon: Icon(
            Icons.chevron_left_rounded,
            color: canPrev ? colors.textPrimary : colors.textDisabled,
          ),
        ),
        Text(
          '${group.label} / $total',
          style: AppText.mono.copyWith(color: colors.textSecondary),
        ),
        IconButton(
          tooltip: '下一组',
          onPressed: canNext ? onNext : null,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(
            minWidth: AppSpacing.minTapTarget,
            minHeight: AppSpacing.minTapTarget,
          ),
          icon: Icon(
            Icons.chevron_right_rounded,
            color: canNext ? colors.textPrimary : colors.textDisabled,
          ),
        ),
      ],
    );
  }
}

// ── 简介 / 题材 ─────────────────────────────────────────────────

/// 简介区（窄屏带区块标题；宽屏的简介在标题区之后，直接用展开体）。
class _SynopsisSection extends StatelessWidget {
  const _SynopsisSection({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHead(title: '简介'),
        _Synopsis(text: text),
      ],
    );
  }
}

/// 可展开简介：默认 4 行，溢出才出「显示更多 / 收起」。
class _Synopsis extends StatefulWidget {
  const _Synopsis({required this.text});

  final String text;

  @override
  State<_Synopsis> createState() => _SynopsisState();
}

class _SynopsisState extends State<_Synopsis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final style = AppText.body.copyWith(color: colors.textSecondary);

    return LayoutBuilder(
      builder: (context, constraints) {
        // 实测 4 行是否放得下：放得下就不显示展开钮（不制造假入口）。
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 4,
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.text,
              maxLines: _expanded ? null : 4,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
            if (overflows || _expanded)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _LinkButton(
                  label: _expanded ? '收起' : '显示更多',
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 题材区：底部标签云（内容层小胶囊）。
class _TagSection extends StatelessWidget {
  const _TagSection({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHead(title: '题材'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[for (final tag in tags) _Tag(tag)],
        ),
      ],
    );
  }
}

/// 题材标签（内容层，非玻璃）。
class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: colors.sunken,
        borderRadius: BorderRadius.circular(AppRadii.capsule),
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

/// 行内链接钮（绿色小字，44pt 可点区）。
class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return PressableScale(
      scale: .94,
      onTap: onTap,
      semanticLabel: label,
      child: SizedBox(
        height: AppSpacing.minTapTarget,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Align(
            alignment: AlignmentDirectional.center,
            child: Text(
              label,
              style: AppText.callout.copyWith(
                color: colors.accentDeep,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// sheet 内的一行（内容层，非玻璃控件）。
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: SizedBox(
          height: AppSpacing.minTapTarget,
          child: Row(
            children: <Widget>[
              Icon(icon, size: 20, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: AppText.body.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
