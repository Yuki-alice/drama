import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../data/repositories/playback_repository.dart';
import '../../../../data/repositories/progress_repository.dart';
import '../../../../domain/models/episode.dart';
import '../../../core/errors.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../detail/view_models/detail_view_model.dart';
import '../view_models/player_controller.dart';

/// 播放页——**整窗接管**的沉浸式播放器。
///
/// 版式读法：没有一个「播放器卡片」，画面铺满整窗，控件浮在画面上且
/// **几秒后自动收起**，进度是一条发丝线。此前是「页面里嵌一个 16:9 视频 +
/// 下面一排按钮」——那是把手机横过来看的网页，不是 iOS 的播放器。
///
/// **两个版式由视频宽高比路由**（见设计规范「屏幕比例与页面关系」）：
/// - 9:16 竖版内容 → [PlayerViewPortrait]（抖音式：右侧互动栏 + 左下文案区）；
/// - 16:9 横版内容 → [PlayerViewLandscape]（顶部玻璃控件 + 底部控制条）。
///
/// 两者共用同一个 [PlayerController]，差别只在控件如何摆放。
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({
    super.key,
    required this.id,
    this.episode,
    this.source = 'hongguo',
  });

  final String id;

  /// 1-based 集号；为 null 时默认第 1 集。
  final int? episode;

  /// 所属源（路由 `?source=` 携带，缺省主源；取流/进度/续播全按源隔离）。
  final String source;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView> {
  late final PlayerController _controller = PlayerController(
    ref: ref,
    seriesId: widget.id,
    source: widget.source,
    initialEpisode: widget.episode,
  );

  @override
  void initState() {
    super.initState();
    _controller.attach();
    _controller.addListener(_onError);
  }

  @override
  void dispose() {
    _controller.removeListener(_onError);
    _controller.dispose();
    super.dispose();
  }

  /// 取一次错误并提示（不反复弹）。
  void _onError() {
    final error = _controller.takeError();
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(
      detailProvider((id: widget.id, source: widget.source)),
    );
    // 选集分组（Rust `episodeGroups`）：组大小/起止/标签/每组剧集一次给全，
    // Dart 只按组渲染。它与详情页共用同一口径，且复用详情缓存（命中即零网络）。
    ref.watch(episodeGroupsProvider((id: widget.id, source: widget.source)));

    final planAsync = ref.watch(
      playPlanProvider((
        id: widget.id,
        episode: _controller.episode,
        source: widget.source,
      )),
    );

    // 取流就绪即打开；切集（family key 变化）自动重解重开。
    ref.listen(
      playPlanProvider((
        id: widget.id,
        episode: _controller.episode,
        source: widget.source,
      )),
      (_, next) {
        next.whenData((plan) => unawaited(_controller.open(plan)));
      },
    );

    // 预取下一集：把 moov 解析与 CDN 首字节提前做完，点「下一集」即播。
    final episodeCount = _controller.episodeCount;
    if (episodeCount > _controller.episode) {
      ref.watch(
        preloadNextProvider((
          id: widget.id,
          episode: _controller.episode,
          total: episodeCount,
          source: widget.source,
        )),
      );
    }

    return detailAsync.when(
      data: (detail) => _shell(context, detail.episodes, planAsync),
      loading: () => AppGlassScaffold(
        immersive: true,
        title: '播放',
        leading: _backAction(),
        body: const LoadingView(label: '正在加载剧集'),
      ),
      error: (error, _) => AppGlassScaffold(
        immersive: true,
        title: '播放',
        leading: _backAction(),
        body: error is StateError
            ? const EmptyView(message: '未找到该剧集', icon: Icons.search_off)
            : ErrorView(
                message: errorMessage(error),
                onRetry: () => ref.invalidate(
                  detailProvider((id: widget.id, source: widget.source)),
                ),
              ),
      ),
    );
  }

  Widget _backAction() => GlassIconAction(
    icon: Icons.keyboard_arrow_down_rounded,
    semanticLabel: '收起播放器',
    tint: AppColors.of(context).onMedia,
    onPressed: () => context.pop(),
  );

  /// 外层壳：沉浸黑底 + 版式路由。
  Widget _shell(
    BuildContext context,
    List<Episode> episodes,
    AsyncValue<PlaybackPlan> planAsync,
  ) {
    return AppGlassScaffold(
      immersive: true,
      // 顶栏标题与控件由两个版式各自摆放，这里不要重复一层。
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final groups = ref
              .watch(
                episodeGroupsProvider((id: widget.id, source: widget.source)),
              )
              .value;

          // 竖屏 / 横屏由**窗口可用比例**决定。
          //
          // 说明：设计规范写的是「按视频比例路由」，但源站下发的档位信息里
          // 没有可靠的画面宽高比（`qualityOptions` 只有高度），而 media_kit
          // 的 `state.width/height` 要等首帧解码后才非零——用它做路由会导致
          // 控件先按竖版画出来再跳变。因此改用**窗口比例**：宽屏窗口给横版
          // 控制条（底部一条，不挡画面），窄窗给竖版（抖音式）。
          // 这是可控且无跳变的近似，代价是竖版内容在横屏窗口里也会用横版控件。
          final wide = MediaQuery.sizeOf(context).aspectRatio > 1.2;
          final portrait = !wide;

          return _PlayerChrome(
            controller: _controller,
            title: _titleOf(context),
            planAsync: planAsync,
            groups: groups,
            fallbackEpisodes: episodes,
            portrait: portrait,
          );
        },
      ),
    );
  }

  /// 剧名（详情缓存；播放页一定在详情之后进入，故通常已就绪）。
  String _titleOf(BuildContext context) =>
      ref
          .read(detailProvider((id: widget.id, source: widget.source)))
          .value
          ?.drama
          .title ??
      '';
}

/// 播放器控件层：统一处理「自动收起、点击唤回、进度、选集」。
///
/// 抽出来的原因很直接：竖版与横版**共用全部交互语义**（3.5s 自收、
/// 拖动定位、选集 sheet、换档），差别只在摆放。把交互写两遍必然漂移。
class _PlayerChrome extends StatefulWidget {
  const _PlayerChrome({
    required this.controller,
    required this.title,
    required this.planAsync,
    required this.groups,
    required this.fallbackEpisodes,
    required this.portrait,
  });

  final PlayerController controller;

  /// 剧名（详情缓存供给）。
  final String title;

  final AsyncValue<PlaybackPlan> planAsync;
  final EpisodeGroups? groups;
  final List<Episode> fallbackEpisodes;
  final bool portrait;

  @override
  State<_PlayerChrome> createState() => _PlayerChromeState();
}

class _PlayerChromeState extends State<_PlayerChrome> {
  Timer? _hideChrome;
  bool _chrome = true;
  int _groupIndex = 0;

  @override
  void initState() {
    super.initState();
    _armHide();
  }

  @override
  void dispose() {
    _hideChrome?.cancel();
    super.dispose();
  }

  /// 任何交互都把控件叫回来，并重新计时收起。
  void _poke([VoidCallback? action]) {
    action?.call();
    if (!_chrome) setState(() => _chrome = true);
    _armHide();
  }

  void _armHide() {
    _hideChrome?.cancel();
    _hideChrome = Timer(AppMotion.chromeIdle, () {
      if (mounted) setState(() => _chrome = false);
    });
  }

  /// 当前分组的集号（分组未就绪时整表兜底，选集区不因可选请求失败而空掉）。
  List<Episode> get _visibleEpisodes {
    final groups = widget.groups;
    if (groups == null || groups.groups.isEmpty) {
      return widget.fallbackEpisodes;
    }
    final index = _groupIndex.clamp(0, groups.groups.length - 1);
    return groups.groups[index].episodes;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final plan = widget.planAsync.value;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // ── 画面（内容层，不透明） ─────────────────────────────────
        ColoredBox(
          // 视频区恒为纯黑：暖色底会在画面边缘透出，污染观感
          // （媒体沉浸场景用固定深底是 HIG 认可的例外）。
          color: Colors.black,
          child: Center(
            child: widget.portrait
                ? AspectRatio(
                    aspectRatio: 9 / 16,
                    child: Video(controller: controller.videoController),
                  )
                : Video(controller: controller.videoController),
          ),
        ),

        // 取流未就绪 / 失败的画面之上提示。
        widget.planAsync.when(
          data: (_) => const SizedBox.shrink(),
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.white70),
          ),
          error: (error, _) => _StreamError(
            message: errorMessage(error),
            onRetry: () => setState(() {}),
          ),
        ),

        // 点空白处唤起 / 收起控件（在控件层之下，控件优先命中）。
        //
        // 竖版额外接管**上滑切集**：兑现左下「上滑看下一集」的提示，
        // 这是抖音式竖版的核心手感。阈值 320 用来排除点击时的微小位移；
        // 只在确实有下一集时动作，最后一集上滑无效果（静默，不弹提示）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_chrome) {
                _hideChrome?.cancel();
                setState(() => _chrome = false);
              } else {
                _poke();
              }
            },
            onVerticalDragEnd: widget.portrait
                ? (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity < -320 && controller.hasNext) {
                      _poke(controller.next);
                    }
                  }
                : null,
          ),
        ),

        // ── 控件层（玻璃功能层） ───────────────────────────────────
        AnimatedOpacity(
          opacity: _chrome ? 1 : 0,
          duration: AppMotion.normal,
          child: IgnorePointer(
            ignoring: !_chrome,
            child: widget.portrait
                ? _PortraitChrome(
                    controller: controller,
                    title: widget.title,
                    plan: plan,
                    groups: widget.groups,
                    visibleEpisodes: _visibleEpisodes,
                    groupIndex: _groupIndex,
                    onGroupChanged: (index) =>
                        setState(() => _groupIndex = index),
                    onEpisodes: () => unawaited(_openEpisodes(controller)),
                    onQuality: () => unawaited(_openQuality(controller)),
                    onPoke: _poke,
                  )
                : _LandscapeChrome(
                    controller: controller,
                    title: widget.title,
                    plan: plan,
                    groups: widget.groups,
                    visibleEpisodes: _visibleEpisodes,
                    groupIndex: _groupIndex,
                    onGroupChanged: (index) =>
                        setState(() => _groupIndex = index),
                    onEpisodes: () => unawaited(_openEpisodes(controller)),
                    onQuality: () => unawaited(_openQuality(controller)),
                    onPoke: _poke,
                  ),
          ),
        ),
      ],
    );
  }

  /// 选集：底部玻璃 sheet（盖在画面上，拉起来时画面仍在播）。
  Future<void> _openEpisodes(PlayerController controller) async {
    _poke();
    final groups = widget.groups;
    final colors = AppColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: GlassSurfaceCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '选集 · 共 ${controller.episodeCount} 集',
                  style: AppText.title.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: AppSpacing.md),
                if (groups != null && groups.groups.length > 1) ...<Widget>[
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      for (final group in groups.groups)
                        OutlinePill(
                          label: group.label,
                          selected: group.index == _groupIndex,
                          height: 36,
                          onTap: () =>
                              setState(() => _groupIndex = group.index),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                SizedBox(
                  height: 260,
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: <Widget>[
                        for (final episode in _visibleEpisodes)
                          _EpisodeTile(
                            index: episode.index,
                            selected: episode.index == controller.episode,
                            locked: episode.locked,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              controller.goToEpisode(episode.index);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 倍速 / 清晰度：一个 sheet 装两组（都属「播放参数」）。
  Future<void> _openQuality(PlayerController controller) async {
    _poke();
    final plan = widget.planAsync.value;
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
                  '播放设置',
                  style: AppText.title.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '倍速',
                  style: AppText.callout.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: <Widget>[
                    for (final speed in kPlaybackSpeeds)
                      OutlinePill(
                        label: '${speed}x',
                        selected: (controller.speed - speed).abs() < 0.01,
                        height: 36,
                        onTap: () => setState(() => controller.setSpeed(speed)),
                      ),
                  ],
                ),
                if (plan != null && plan.qualityOptions.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    plan.offline ? '清晰度（离线本地文件）' : '清晰度',
                    style: AppText.callout.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      for (final option in plan.qualityOptions)
                        OutlinePill(
                          label: option.label,
                          selected:
                              option.height ==
                              (controller.qualityOverride ?? plan.quality),
                          height: 36,
                          onTap: plan.offline
                              ? null
                              : () {
                                  Navigator.of(sheetContext).pop();
                                  unawaited(
                                    controller.switchQuality(
                                      plan,
                                      option.height,
                                    ),
                                  );
                                },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 倍速档位（与设置页共用一份，避免两处各写一遍）。
const List<double> kPlaybackSpeeds = <double>[0.75, 1, 1.25, 1.5, 2, 3];

// ─────────────────────────────────────────────────────────────────────────────
// 竖屏版（9:16 内容）
// ─────────────────────────────────────────────────────────────────────────────

/// 竖屏版：顶部返回胶囊 + 居中剧集名 + 右侧竖排互动栏 + 左下文案区 +
/// 底部全宽发丝进度线 + 中央半透明暂停幽灵图标。
class _PortraitChrome extends StatelessWidget {
  const _PortraitChrome({
    required this.controller,
    required this.title,
    required this.plan,
    required this.groups,
    required this.visibleEpisodes,
    required this.groupIndex,
    required this.onGroupChanged,
    required this.onEpisodes,
    required this.onQuality,
    required this.onPoke,
  });

  final PlayerController controller;
  final String title;
  final PlaybackPlan? plan;
  final EpisodeGroups? groups;
  final List<Episode> visibleEpisodes;
  final int groupIndex;
  final ValueChanged<int> onGroupChanged;
  final VoidCallback onEpisodes;
  final VoidCallback onQuality;
  final void Function([VoidCallback? action]) onPoke;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final safe = MediaQuery.paddingOf(context);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 顶部压深，保证玻璃控件上的白字可读。
        _EdgeScrim(alignment: Alignment.topCenter, height: safe.top + 96),
        // 底部压深，保证文案区可读。
        _EdgeScrim(alignment: Alignment.bottomCenter, height: 260),

        // ── 顶部：返回胶囊 + 居中剧集名 + 更多圆钮 ─────────────────
        PositionedDirectional(
          top: safe.top + AppSpacing.sm,
          start: AppSpacing.gutter,
          end: AppSpacing.gutter,
          child: Row(
            children: <Widget>[
              GlassIconAction(
                icon: Icons.keyboard_arrow_down_rounded,
                semanticLabel: '收起播放器',
                tint: colors.onMedia,
                onPressed: () => context.pop(),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      'EP ${controller.episode} · '
                      '${plan?.qualityText ?? '默认'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: AppText.mono.copyWith(
                        color: colors.onMedia,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              GlassCapsuleGroup(
                children: <Widget>[
                  GlassIconAction(
                    icon: Icons.high_quality_rounded,
                    semanticLabel: '清晰度与倍速',
                    size: 40,
                    iconSize: 19,
                    tint: colors.onMedia,
                    onPressed: onQuality,
                  ),
                  GlassIconAction(
                    icon: Icons.more_horiz_rounded,
                    semanticLabel: '选集',
                    size: 40,
                    iconSize: 19,
                    tint: colors.onMedia,
                    onPressed: onEpisodes,
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── 中央：暂停幽灵图标（半个透明度，不遮挡画面） ──────────
        Center(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: 1,
              duration: AppMotion.normal,
              child: StreamBuilder<bool>(
                stream: controller.player.stream.playing,
                builder: (context, snapshot) {
                  final playing = snapshot.data ?? false;
                  if (playing) return const SizedBox.shrink();
                  return Icon(
                    Icons.play_arrow_rounded,
                    size: 76,
                    color: colors.onMedia.withValues(alpha: .5),
                  );
                },
              ),
            ),
          ),
        ),

        // ── 右侧竖排互动栏 ────────────────────────────────────────
        PositionedDirectional(
          end: AppSpacing.sm,
          bottom: 148,
          child: _ActionRail(controller: controller),
        ),

        // ── 左下文案区 + 选集/倍速/清晰度小胶囊 + 上滑提示 ─────────
        PositionedDirectional(
          start: AppSpacing.gutter,
          end: 76,
          bottom: safe.bottom + 44,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title.isEmpty ? '第 ${controller.episode} 集' : title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.headline.copyWith(color: colors.onMedia),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _episodeMeta(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono.copyWith(
                  color: colors.onMediaSecondary,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // 三个玻璃小胶囊：选集 / 倍速 / 清晰度。
              GlassCapsuleGroup(
                children: <Widget>[
                  _MiniAction(
                    label: '选集',
                    icon: Icons.playlist_play_rounded,
                    onTap: onEpisodes,
                  ),
                  _MiniAction(label: '${controller.speed}x', onTap: onQuality),
                  _MiniAction(
                    label: plan?.qualityText ?? '默认',
                    onTap: onQuality,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              // 提示只在确实还有下一集时出现——最后一集上滑不动作，
              // 挂着提示就是撒谎。
              if (controller.hasNext)
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.keyboard_arrow_up_rounded,
                      size: 16,
                      color: colors.onMediaTertiary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '上滑看下一集',
                      style: AppText.caption.copyWith(
                        color: colors.onMediaTertiary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),

        // ── 底部全宽发丝进度线 ────────────────────────────────────
        PositionedDirectional(
          start: 0,
          end: 0,
          bottom: 0,
          child: _ProgressBar(controller: controller, height: 3),
        ),
      ],
    );
  }

  String _episodeMeta() {
    final total = controller.episodeCount;
    final parts = <String>[
      '第 ${controller.episode} 集',
      if (total > 0) '共 $total 集',
      if (plan?.offline == true) '离线',
      if (plan?.encrypted == true) '加密轨',
    ];
    return parts.join(' · ');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 横屏版（16:9 内容）
// ─────────────────────────────────────────────────────────────────────────────

/// 横屏版：整屏画面 + 顶部玻璃控件（返回 / 集名 / 1080P / 更多）+
/// 底部控制条（播放键 / 时间 / 发丝进度 / 倍速 / 选集）。
class _LandscapeChrome extends StatelessWidget {
  const _LandscapeChrome({
    required this.controller,
    required this.title,
    required this.plan,
    required this.groups,
    required this.visibleEpisodes,
    required this.groupIndex,
    required this.onGroupChanged,
    required this.onEpisodes,
    required this.onQuality,
    required this.onPoke,
  });

  final PlayerController controller;
  final String title;
  final PlaybackPlan? plan;
  final EpisodeGroups? groups;
  final List<Episode> visibleEpisodes;
  final int groupIndex;
  final ValueChanged<int> onGroupChanged;
  final VoidCallback onEpisodes;
  final VoidCallback onQuality;
  final void Function([VoidCallback? action]) onPoke;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final safe = MediaQuery.paddingOf(context);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _EdgeScrim(alignment: Alignment.topCenter, height: safe.top + 76),
        _EdgeScrim(alignment: Alignment.bottomCenter, height: 120),

        // ── 顶部玻璃控件 ──────────────────────────────────────────
        PositionedDirectional(
          top: safe.top + AppSpacing.sm,
          start: AppSpacing.gutter,
          end: AppSpacing.gutter,
          child: Row(
            children: <Widget>[
              GlassIconAction(
                icon: Icons.arrow_back_ios_new_rounded,
                semanticLabel: '收起播放器',
                tint: colors.onMedia,
                onPressed: () => context.pop(),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  title.isEmpty ? '第 ${controller.episode} 集' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline.copyWith(color: colors.onMedia),
                ),
              ),
              GlassCapsuleGroup(
                children: <Widget>[
                  _MiniAction(
                    label: plan?.qualityText ?? '默认',
                    onTap: onQuality,
                  ),
                  GlassIconAction(
                    icon: Icons.more_horiz_rounded,
                    semanticLabel: '选集',
                    size: 40,
                    iconSize: 19,
                    tint: colors.onMedia,
                    onPressed: onEpisodes,
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── 底部控制条：播放键 / 时间 / 发丝进度 / 倍速 / 选集 ─────
        PositionedDirectional(
          start: AppSpacing.gutter,
          end: AppSpacing.gutter,
          bottom: safe.bottom + AppSpacing.md,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ProgressBar(controller: controller, height: 3),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  StreamBuilder<bool>(
                    stream: controller.player.stream.playing,
                    builder: (context, snapshot) {
                      final playing = snapshot.data ?? false;
                      return GlassIconAction(
                        icon: playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        semanticLabel: playing ? '暂停' : '播放',
                        tint: colors.onMedia,
                        onPressed: () => onPoke(controller.togglePlay),
                      );
                    },
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _TimeReadout(controller: controller),
                  const Spacer(),
                  _MiniAction(label: '${controller.speed}x', onTap: onQuality),
                  const SizedBox(width: AppSpacing.sm),
                  _MiniAction(
                    label: '选集',
                    icon: Icons.playlist_play_rounded,
                    onTap: onEpisodes,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 共用部件
// ─────────────────────────────────────────────────────────────────────────────

/// 画面边缘压深（保证其上的白字可读）。播放器的顶部/底部各一条。
class _EdgeScrim extends StatelessWidget {
  const _EdgeScrim({required this.alignment, required this.height});

  final Alignment alignment;
  final double height;

  @override
  Widget build(BuildContext context) {
    final top = alignment == Alignment.topCenter;
    return Align(
      alignment: alignment,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: const <Color>[Color(0xA6000000), Color(0x00000000)],
            ),
          ),
        ),
      ),
    );
  }
}

/// 右侧竖排互动栏（喜欢 / 评论 / 收藏 / 分享）。
///
/// **只有「收藏」有真实后端**：它就是「追剧」，走 Rust 持久化写入，
/// 按钮态由 [isFollowingProvider] 驱动（已收藏时书签实心 + 文案切换）。
/// 喜欢 / 评论 / 分享依赖账号体系与评论后端，本应用没有——按钮保留形态
/// 但明确提示「尚未接入」，不编造看起来像真的计数。
class _ActionRail extends ConsumerWidget {
  const _ActionRail({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final following =
        ref
            .watch(
              isFollowingProvider((
                id: controller.seriesId,
                source: controller.source,
              )),
            )
            .value ??
        false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RailButton(
          icon: Icons.favorite_border_rounded,
          label: '喜欢',
          onTap: () => _notImplemented(context, '喜欢'),
        ),
        _RailButton(
          icon: Icons.mode_comment_outlined,
          label: '评论',
          onTap: () => _notImplemented(context, '评论'),
        ),
        _RailButton(
          icon: following
              ? Icons.bookmark_rounded
              : Icons.bookmark_border_rounded,
          label: following ? '已收藏' : '收藏',
          onTap: () => unawaited(_toggleFollow(context, ref, following)),
        ),
        _RailButton(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => _notImplemented(context, '分享'),
        ),
      ],
    );
  }

  /// 收藏 = 追剧：写入 Rust 持久化，成功后 provider 失效驱动按钮态刷新。
  ///
  /// 与详情页 `_toggleFollow` 同一口径：失败显式提示（不静默吞掉），
  /// 剧名 / 封面取自详情缓存（播放页一定在详情之后进入，通常已就绪）。
  Future<void> _toggleFollow(
    BuildContext context,
    WidgetRef ref,
    bool wasFollowing,
  ) async {
    // 先取 messenger：避免 await 之后再用 BuildContext（跨异步间隙）。
    final messenger = ScaffoldMessenger.of(context);
    try {
      final actions = ref.read(progressActionsProvider);
      if (wasFollowing) {
        await actions.unfollow(
          ref,
          controller.seriesId,
          source: controller.source,
        );
      } else {
        final detail = ref
            .read(
              detailProvider((
                id: controller.seriesId,
                source: controller.source,
              )),
            )
            .value;
        await actions.follow(
          ref,
          id: controller.seriesId,
          title: detail?.drama.title ?? '',
          cover: detail?.drama.cover ?? '',
          episode: controller.episode,
          totalEpisode: controller.episodeCount,
          source: controller.source,
        );
      }
      messenger.showSnackBar(
        SnackBar(content: Text(wasFollowing ? '已取消追剧' : '已加入追剧')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('操作失败：${errorMessage(error)}')),
      );
    }
  }

  void _notImplemented(BuildContext context, String feature) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$feature 尚未接入（无账号体系与评论后端）')));
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
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
      child: PressableScale(
        scale: .9,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 30, color: colors.onMedia),
              const SizedBox(height: 2),
              Text(
                label,
                style: AppText.caption.copyWith(color: colors.onMediaSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 玻璃胶囊里的一个迷你动作（选集 / 倍速 / 清晰度）。
class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.label, required this.onTap, this.icon});

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      // 40 高：玻璃胶囊组内的次级动作，仍高于 HIG 最小 28×28 的下限；
      // 主控（返回 / 播放）一律 44。
      child: PressableScale(
        scale: .92,
        onTap: onTap,
        child: SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 15, color: colors.onMedia),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Text(
                  label,
                  style: AppText.mono.copyWith(
                    color: colors.onMedia,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 发丝进度线（可拖）。
///
/// 全宽铺底：不点开控件也知道放到哪了。拖动时线宽加到 5 以示「可拖」。
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({required this.controller, this.height = 3});

  final PlayerController controller;
  final double height;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  /// 拖拽中的临时比例；null = 未在拖动。
  double? _dragFraction;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return StreamBuilder<Duration>(
      stream: widget.controller.player.stream.position,
      builder: (context, positionSnap) => StreamBuilder<Duration>(
        stream: widget.controller.player.stream.duration,
        builder: (context, durationSnap) {
          final total = durationSnap.data ?? Duration.zero;
          final position = positionSnap.data ?? Duration.zero;
          final totalMs = total.inMilliseconds;
          final fraction =
              _dragFraction ??
              (totalMs > 0 ? position.inMilliseconds / totalMs : 0.0);

          return LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (details) {
                setState(() {
                  _dragging = true;
                  _dragFraction =
                      (details.localPosition.dx / constraints.maxWidth).clamp(
                        0.0,
                        1.0,
                      );
                });
              },
              onHorizontalDragUpdate: (details) => setState(() {
                _dragFraction =
                    (details.localPosition.dx / constraints.maxWidth).clamp(
                      0.0,
                      1.0,
                    );
              }),
              onHorizontalDragEnd: (_) {
                final target = _dragFraction;
                setState(() {
                  _dragging = false;
                  _dragFraction = null;
                });
                if (target != null && totalMs > 0) {
                  widget.controller.seek(
                    Duration(milliseconds: (target * totalMs).round()),
                  );
                }
              },
              onHorizontalDragCancel: () =>
                  setState(() => _dragFraction = null),
              // 拖动区域比线本身高得多：3pt 的线没人能一次点中。
              child: SizedBox(
                height: 28,
                child: Align(
                  alignment: AlignmentDirectional.bottomCenter,
                  child: HairlineProgress(
                    fraction: fraction,
                    height: _dragging ? 5 : widget.height,
                    // 进度 = 状态；它**坐在画面上**，所以永远是白，
                    // 不随浅色/深色外观切换（视频是唯一有资格被折射的东西）。
                    color: colors.onMedia,
                    track: colors.hairlineTrack,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 时间读数（`mm:ss / mm:ss`，等宽，宽度不跳）。
class _TimeReadout extends StatelessWidget {
  const _TimeReadout({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return StreamBuilder<Duration>(
      stream: controller.player.stream.position,
      builder: (context, positionSnap) => StreamBuilder<Duration>(
        stream: controller.player.stream.duration,
        builder: (context, durationSnap) => StreamBuilder<bool>(
          stream: controller.player.stream.buffering,
          builder: (context, bufferingSnap) {
            final total = durationSnap.data ?? Duration.zero;
            final position = positionSnap.data ?? Duration.zero;
            final buffering = bufferingSnap.data ?? false;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '${_formatDuration(position)} / '
                  '${total > Duration.zero ? _formatDuration(total) : '--:--'}',
                  style: AppText.mono.copyWith(color: colors.onMediaSecondary),
                ),
                if (buffering) ...<Widget>[
                  const SizedBox(width: AppSpacing.sm),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// `mm:ss` 时长展示（等宽字族下宽度稳定）。
String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

/// 取流失败提示（覆盖在画面之上，不退出播放页）。
class _StreamError extends StatelessWidget {
  const _StreamError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: .72),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppText.callout.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
                shape: const StadiumBorder(),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 选集格（48×44：可点区达标，选中用墨底反白）。
class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.index,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: locked ? '第 $index 集，需授权' : '第 $index 集',
      child: PressableScale(
        scale: .92,
        onTap: onTap,
        child: Container(
          width: 52,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // 选中 = 墨色填充 + 反白字（重型填充色；绿色留给进度与状态）。
            color: selected ? colors.textPrimary : colors.sunken,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: selected ? colors.textPrimary : colors.divider,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (locked)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Icon(
                    Icons.lock_outline,
                    size: 11,
                    color: selected ? colors.onInk : colors.textSecondary,
                  ),
                ),
              Text(
                '$index',
                style: AppText.mono.copyWith(
                  color: selected ? colors.onInk : colors.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
