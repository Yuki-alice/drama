import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/playback_repository.dart';
import '../../../../data/repositories/progress_repository.dart';
import '../../../../data/services/rust_core.dart';
import '../../../core/playback/playback_settings.dart';
import '../../../../domain/models/episode.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../detail/view_models/detail_view_model.dart';

/// 播放页。
///
/// 画面区为 media_kit 真播放器（不透明内容层），流地址取自 Rust `play`
/// 返回的本机代理 URL；控制条为玻璃功能层。
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({super.key, required this.id, this.episode});

  final String id;

  /// 1-based 集号；为 null 时默认第 1 集。
  final int? episode;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView> {
  late int _episode = widget.episode ?? 1;
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  /// 进度上报订阅（播放中定期把位置写入 Rust 持久化）。
  StreamSubscription<Duration>? _positionSub;

  /// 播放结束订阅（用于自动连播）。
  StreamSubscription<bool>? _completedSub;

  /// 是否已按续播记录定位过（每集只跳一次，避免与用户拖动打架）。
  bool _resumeApplied = false;

  /// 当前已真正打开（有媒体在播放器里）的集号；`null` = 尚未打开。
  ///
  /// 切集后到新媒体打开前，位置流仍会推旧视频的位置——据 [episode] 上报
  /// 会把「旧集的位置」记成「新集的进度」。故只在集号一致时上报。
  int? _openedEpisode;

  /// 选集分组下标（0-based）。切换分组**只影响渲染**——每组的剧集 Rust 已一次给全。
  int _groupIndex = 0;

  /// 播放中换档的目标高度；`null` = 跟随设置页的清晰度偏好。
  ///
  /// 换档是**本集**的选择，不该反向改写全局偏好（那是设置页的事）。
  int? _qualityOverride;

  /// 是否正在换档（禁用菜单、避免连点）。
  bool _switchingQuality = false;

  @override
  void initState() {
    super.initState();
    _positionSub = _player.stream.position.listen(_onPosition);
    // 播放自然结束 → 自动连播下一集（若无下一集则停在当前集）。
    _completedSub = _player.stream.completed.listen((completed) {
      if (completed && mounted) _playNextIfAny();
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _completedSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// 播放位置回调：节流后上报进度（`historyPut` 同时刷新追剧条目与历史）。
  ///
  /// 上报失败**静默忽略**——播放不应因持久化失败而中断；下次回调会重试。
  void _onPosition(Duration position) {
    if (!mounted) return;
    // 仅上报「与当前播放器媒体同一集」的位置，避免切集瞬间写错集号。
    if (_openedEpisode != _episode) return;
    final actions = ref.read(progressActionsProvider);
    final now = DateTime.now();
    if (actions.shouldThrottle(widget.id, now)) return;
    final duration = _player.state.duration;
    actions.markReported(widget.id, now);
    unawaited(
      actions
          .reportProgress(
            ref,
            id: widget.id,
            episode: _episode,
            position: position,
            duration: duration,
          )
          .catchError((Object _) {}),
    );
  }

  /// 自动连播：受设置开关约束，且仅当当前集不是最后一集时前进。
  void _playNextIfAny() {
    if (!ref.read(playbackSettingsProvider).autoPlayNext) return;
    if (_episode >= _episodeCount) return;
    _goToEpisode(_episode + 1);
  }

  /// 总集数：优先用 Rust 分组结果（与选集区同一口径），未就绪时回落详情。
  int get _episodeCount {
    final fromGroups = ref
        .read(episodeGroupsProvider(widget.id))
        .value
        ?.total;
    if (fromGroups != null && fromGroups > 0) return fromGroups;
    return ref.read(detailProvider(widget.id)).value?.episodes.length ?? 0;
  }

  /// 切集：重置续播标记（新集需按该集记录重新定位）。
  ///
  /// 集号可能落在别的分组里（用户从「1-50」点「101-120」的集），
  /// 故顺带把分组下标对齐，避免选集区高亮与实际播放的集脱节。
  void _goToEpisode(int episode) {
    final groups = ref.read(episodeGroupsProvider(widget.id)).value;
    final size = groups?.groupSize ?? 0;
    setState(() {
      _episode = episode;
      _resumeApplied = false;
      // 换档是**本集**的选择：切集后回到「跟随偏好」，否则标题与选集
      // 会停在上一集的档位上，与设置页不一致。
      _qualityOverride = null;
      if (groups != null && size > 0) {
        final index = (episode - 1) ~/ size;
        _groupIndex = index.clamp(0, groups.groups.length - 1);
      }
    });
  }

  /// 换档：走 Rust `playQuality`（复用已解析出的候选线路，零签名零网络），
  /// 拿到新地址后**原地续播**——记下当前位置与播放状态，重新开流再跳回去，
  /// 用户感知是「画质变了，进度没动」。
  Future<void> _switchQuality(int height) async {
    final holder = ref.read(rustCoreProvider);
    if (holder == null || _switchingQuality) return;
    final plan = ref
        .read(playPlanProvider((id: widget.id, episode: _episode)))
        .value;
    final vid = plan?.vid ?? '';
    // 离线本地文件 / 源未给 vid：没有可换的候选档位，安静地什么都不做。
    if (vid.isEmpty || plan == null || plan.offline) return;

    setState(() => _switchingQuality = true);
    try {
      final next = await PlaybackRepository(
        SeriesCoreShim(holder.core),
      ).switchQuality(seriesId: widget.id, vid: vid, quality: height);
      final position = _player.state.position;
      final wasPlaying = _player.state.playing;
      await _player.open(Media(next.proxyUrl), play: wasPlaying);
      await _player.seek(position);
      if (!mounted) return;
      setState(() {
        _qualityOverride = height;
        _switchingQuality = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _switchingQuality = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换清晰度失败：${_errorMessage(error)}')));
    }
  }

  /// 拖动进度条：跳转并把当前位置**立即**上报，避免「拖完就退出」丢进度。
  void _onSeek(Duration target) {
    unawaited(_player.seek(target));
    final actions = ref.read(progressActionsProvider);
    actions.markReported(widget.id, DateTime.now());
    unawaited(
      actions
          .reportProgress(
            ref,
            id: widget.id,
            episode: _episode,
            position: target,
            duration: _player.state.duration,
          )
          .catchError((Object _) {}),
    );
  }

  /// 打开该集媒体；若本集正是上次观看到的那一集，则跳到上次位置续播。
  ///
  /// 续播只在「记录集号 == 当前集」时生效——历史记录只存最后观看的一集，
  /// 用户手动切到别的集时不该套用旧偏移。
  Future<void> _openAndMaybeResume(PlaybackPlan plan) async {
    final episodeAtOpen = _episode;
    // 尊重「进入播放页立即播放」设置：关闭时只装载不播放（用户按播放键开始）。
    final autoPlay = ref.read(playbackSettingsProvider).autoPlayOnOpen;
    await _player.open(Media(plan.proxyUrl), play: autoPlay);
    if (!mounted) return;
    // 打开过程中用户可能已切集：此时这次 open 的结果已过期，
    // 记下集号也无意义（下一次 plan 会重新 open）。
    if (episodeAtOpen != _episode) return;
    _openedEpisode = episodeAtOpen;

    // 诊断留痕：把实际解析到的轨道信息打到日志。
    // 播放失败常表现为「静默黑屏」，没有这行日志就无从区分是取流、代理还是
    // 解码的问题（实测踩过：media_kit 未初始化时整页变红且无其他线索）。
    unawaited(_logPlaybackState(plan));

    if (_resumeApplied) return;
    final resume = await ref.read(resumeProvider(widget.id).future);
    if (!mounted || _resumeApplied) return;
    if (resume == null || resume.episode != _episode) return;
    final target = resume.position;
    // 只对「看了一部分」的记录续播：过短（刚点开）或已近片尾则不跳。
    if (target < const Duration(seconds: 5)) return;
    final duration = _player.state.duration;
    if (duration > Duration.zero &&
        target >= duration - const Duration(seconds: 10)) {
      return;
    }
    _resumeApplied = true;
    await _player.seek(target);
  }

  /// 轮询并打印播放器实际状态（时长/分辨率/是否在推进）。
  ///
  /// 只在 `kDebugMode` 下工作；失败不抛（诊断代码不该影响播放）。
  Future<void> _logPlaybackState(PlaybackPlan plan) async {
    if (!kDebugMode) return;
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (mounted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final duration = _player.state.duration;
        final width = _player.state.width ?? 0;
        if (duration > Duration.zero && width > 0) {
          debugPrint(
            '[player] ready ep=$_episode quality=${plan.quality} '
            'encrypted=${plan.encrypted} '
            '${width}x${_player.state.height} duration=$duration',
          );
          final p0 = _player.state.position;
          await Future<void>.delayed(const Duration(seconds: 3));
          final p1 = _player.state.position;
          debugPrint('[player] position $p0 -> $p1 playing=${_player.state.playing}');
          return;
        }
      }
      debugPrint(
        '[player] NOT ready after 15s (duration=${_player.state.duration} '
        'width=${_player.state.width}) url=${plan.proxyUrl}',
      );
    } catch (error) {
      debugPrint('[player] state probe failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(detailProvider(widget.id));
    // 选集分组（Rust `episodeGroups`）：组大小/起止/标签/每组剧集一次给全，
    // Dart 只按组渲染。它与详情页共用同一口径，且复用详情缓存（命中即零网络）。
    ref.watch(episodeGroupsProvider(widget.id));
    // 取流就绪即打开；切集（key 变化）自动重解重开。
    ref.listen(playPlanProvider((id: widget.id, episode: _episode)), (_, next) {
      next.whenData((plan) {
        unawaited(_openAndMaybeResume(plan));
      });
    });

    // 预取下一集：把 moov 解析与 CDN 首字节提前做完，点「下一集」即播。
    // 只在详情已就绪且确实还有下一集时发起；失败静默（可选能力）。
    final episodeCount = detailAsync.value?.episodes.length ?? 0;
    if (episodeCount > _episode) {
      ref.watch(
        preloadNextProvider((
          id: widget.id,
          episode: _episode,
          total: episodeCount,
        )),
      );
    }

    return detailAsync.when(
      data: (detail) => _playerBody(context, detail.episodes),
      loading: () => AppGlassScaffold(
        title: '播放',
        leading: _backAction(context),
        body: const LoadingView(),
      ),
      error: (error, _) => AppGlassScaffold(
        title: '播放',
        leading: _backAction(context),
        // 未找到（StateError）走空态；其余真错误显式呈现并可重试。
        body: error is StateError
            ? const EmptyView(message: '未找到该剧集', icon: Icons.search_off)
            : ErrorView(
                message: _errorMessage(error),
                onRetry: () => ref.invalidate(detailProvider(widget.id)),
              ),
      ),
    );
  }

  Widget _backAction(BuildContext context) => GlassIconAction(
    icon: Icons.arrow_back_ios_new,
    semanticLabel: '返回',
    onPressed: () => context.pop(),
  );

  Widget _playerBody(BuildContext context, List<Episode> episodes) {
    final colors = AppColors.of(context);
    // 选集渲染用 Rust 分组；未就绪（首次加载 / 详情成功但分组在途）时
    // 退回整表渲染，避免选集区闪空。
    final groupsAsync = ref.watch(episodeGroupsProvider(widget.id));
    final groups = groupsAsync.value;
    final total = groups?.total ?? episodes.length;
    final hasPrevious = _episode > 1;
    final hasNext = _episode < total;
    final planAsync = ref.watch(
      playPlanProvider((id: widget.id, episode: _episode)),
    );

    final settings = ref.watch(playbackSettingsProvider);
    final plan = planAsync.value;
    // 换档后标题要显示**实际**档位，而不是设置里的期望上限。
    final qualityLabel = _qualityOverride != null
        ? _labelOfHeight(plan?.qualityOptions ?? const <QualityOption>[], _qualityOverride!)
        : (plan?.qualityText ?? settings.qualityLabel);
    return AppGlassScaffold(
      title: '第 $_episode 集 · $qualityLabel',
      leading: _backAction(context),
      actions: <Widget>[
        if (plan != null && plan.qualityOptions.isNotEmpty && !plan.offline)
          _QualityMenu(
            options: plan.qualityOptions,
            current: _qualityOverride ?? plan.quality,
            switching: _switchingQuality,
            onPick: _switchQuality,
          ),
      ],
      body: ListView(
        children: <Widget>[
          // ── 画面区（不透明内容层，真播放器） ───────────────────
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              // 视频区恒为纯黑：暖色底会在画面边缘透出，污染观感
              // （HIG dark-mode.md：媒体沉浸场景用固定深底是合理例外）。
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Video(controller: _controller),
                  planAsync.when(
                    data: (_) => const SizedBox.shrink(),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Center(
                      child: Padding(
                        padding: AppSpacing.pageH,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              _errorMessage(error),
                              textAlign: TextAlign.center,
                              style: AppText.callout.copyWith(
                                color: Colors.white.withValues(alpha: 0.82),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextButton(
                              onPressed: () => ref.invalidate(
                                playPlanProvider((
                                  id: widget.id,
                                  episode: _episode,
                                )),
                              ),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 可拖动进度条 + 时间 + 缓冲/清晰度 ─────────────────
          Padding(
            padding: AppSpacing.pageH,
            child: _Scrubber(
              player: _player,
              accent: colors.accent,
              onSeek: _onSeek,
            ),
          ),

          // ── 控制条（玻璃功能层） ─────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                GlassIconAction(
                  icon: Icons.skip_previous,
                  semanticLabel: '上一集',
                  size: 44,
                  iconSize: 20,
                  onPressed: hasPrevious
                      ? () => _goToEpisode(_episode - 1)
                      : () {},
                ),
                const SizedBox(width: AppSpacing.lg),
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  builder: (context, snapshot) {
                    final playing = snapshot.data ?? false;
                    return GlassIconAction(
                      icon: playing ? Icons.pause : Icons.play_arrow,
                      semanticLabel: playing ? '暂停' : '播放',
                      size: 56,
                      iconSize: 26,
                      tint: colors.accent,
                      onPressed: () =>
                          playing ? _player.pause() : _player.play(),
                    );
                  },
                ),
                const SizedBox(width: AppSpacing.lg),
                GlassIconAction(
                  icon: Icons.skip_next,
                  semanticLabel: '下一集',
                  size: 44,
                  iconSize: 20,
                  onPressed: hasNext
                      ? () => _goToEpisode(_episode + 1)
                      : () {},
                ),
              ],
            ),
          ),

          SectionHeader(
            title: groups == null ? '选集' : '选集（共 $total 集）',
          ),
          // 分组切换：每组 50 集（口径由 Rust 给）。之前播放页 `take(60)`
          // 硬截，60 集以上的剧在播放页根本点不到后半段——现在按组翻页。
          if (groups != null && groups.groups.length > 1)
            Padding(
              padding: AppSpacing.pageH,
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  for (final group in groups.groups)
                    _MiniEpisodeChip(
                      label: group.label,
                      selected: group.index == _groupIndex,
                      onTap: () => setState(() => _groupIndex = group.index),
                    ),
                ],
              ),
            ),
          if (groups != null && groups.groups.length > 1)
            const SizedBox(height: AppSpacing.md),
          Padding(
            padding: AppSpacing.pageH,
            child: _episodeChips(
              groups: groups,
              fallback: episodes,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  /// 当前分组的集号 chip。
  ///
  /// 分组数据未就绪（首次加载 / 分组 op 失败）时整表兜底渲染，
  /// 保证选集区不会因为一次可选请求失败而空掉。
  Widget _episodeChips({
    required EpisodeGroups? groups,
    required List<Episode> fallback,
  }) {
    final List<Episode> items;
    if (groups == null || groups.groups.isEmpty) {
      items = fallback;
    } else {
      final index = _groupIndex.clamp(0, groups.groups.length - 1);
      items = groups.groups[index].episodes;
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        for (final episode in items)
          _MiniEpisodeChip(
            label: '${episode.index}',
            selected: episode.index == _episode,
            onTap: () => _goToEpisode(episode.index),
          ),
      ],
    );
  }
}

/// 统一错误文案（[RustCoreException] 带错误码，其余直接 `toString`）。
String _errorMessage(Object error) =>
    error is RustCoreException ? '${error.msg}（${error.code}）' : '$error';

/// `mm:ss` 时长展示。
String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// 可拖动进度条 + 时间读数 + 缓冲/清晰度状态。
///
/// 拖动期间**不被播放位置流覆盖**：手指按住时以本地拖拽值为准，
/// 松手才 `seek` 并交回流驱动——否则拖动会被每秒数次的位置回调打断。
class _Scrubber extends StatefulWidget {
  const _Scrubber({
    required this.player,
    required this.accent,
    required this.onSeek,
  });

  final Player player;
  final Color accent;
  final ValueChanged<Duration> onSeek;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  /// 拖拽中的临时位置；null = 未在拖动。
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Column(
      children: <Widget>[
        const SizedBox(height: AppSpacing.lg),
        StreamBuilder<Duration>(
          stream: widget.player.stream.position,
          builder: (context, positionSnap) => StreamBuilder<Duration>(
            stream: widget.player.stream.duration,
            builder: (context, durationSnap) => StreamBuilder<Duration>(
              stream: widget.player.stream.buffer,
              builder: (context, bufferSnap) => StreamBuilder<bool>(
                stream: widget.player.stream.buffering,
                builder: (context, bufferingSnap) {
                  final total = durationSnap.data ?? Duration.zero;
                  final streamed = positionSnap.data ?? Duration.zero;
                  final buffered = bufferSnap.data ?? Duration.zero;
                  final buffering = bufferingSnap.data ?? false;
                  final totalMs = total.inMilliseconds;
                  final maxValue = totalMs > 0 ? totalMs.toDouble() : 1.0;
                  final raw = _dragValue ?? streamed.inMilliseconds.toDouble();
                  final value = raw.clamp(0.0, maxValue);
                  final shown = Duration(milliseconds: value.round());

                  return Column(
                    children: <Widget>[
                      SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 4,
                          activeTrackColor: widget.accent,
                          // 已缓冲但未播放的部分用中性色，与已播部分区分。
                          secondaryActiveTrackColor: colors.borderStrong,
                          inactiveTrackColor: colors.divider,
                          thumbColor: widget.accent,
                          overlayColor: colors.accentSubtle,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 18,
                          ),
                        ),
                        child: Slider(
                          value: value,
                          max: maxValue,
                          // 已缓冲到哪：secondary 段从当前值画到 buffer 值。
                          secondaryTrackValue: buffered.inMilliseconds
                              .toDouble()
                              .clamp(value, maxValue),
                          // 时长未知（尚未拿到 metadata）时禁用拖动，避免乱跳。
                          onChanged: totalMs > 0
                              ? (v) => setState(() => _dragValue = v)
                              : null,
                          onChangeEnd: totalMs > 0
                              ? (v) {
                                  final target = Duration(
                                    milliseconds: v.round(),
                                  );
                                  setState(() => _dragValue = null);
                                  widget.onSeek(target);
                                }
                              : null,
                        ),
                      ),
                      // Slider 自带留白较大，这里收紧后放读数行。
                      Transform.translate(
                        offset: const Offset(0, -6),
                        child: Row(
                          children: <Widget>[
                            Text(
                              _formatDuration(shown),
                              style: AppText.caption.copyWith(
                                color: colors.textSecondary,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            if (buffering) ...<Widget>[
                              const SizedBox(width: AppSpacing.sm),
                              SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: colors.textTertiary,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Text(
                                '缓冲中',
                                style: AppText.caption.copyWith(
                                  color: colors.textTertiary,
                                ),
                              ),
                            ],
                            const Spacer(),
                            Text(
                              // 时长未知时显示占位，而不是刺眼的 00:00。
                              totalMs > 0 ? _formatDuration(total) : '--:--',
                              style: AppText.caption.copyWith(
                                color: colors.textSecondary,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 档位标签：`height` 不在档位表里时回落到 `{h}P`。
String _labelOfHeight(List<QualityOption> options, int height) {
  for (final option in options) {
    if (option.height == height) return option.label;
  }
  return '${height}P';
}

/// 清晰度切换菜单（播放中可切档）。
///
/// 档位表来自 Rust，切换走 `playQuality`——复用已解析的候选线路，
/// 不重跑签名链。离线本地文件没有候选档位，菜单不显示。
class _QualityMenu extends StatelessWidget {
  const _QualityMenu({
    required this.options,
    required this.current,
    required this.switching,
    required this.onPick,
  });

  final List<QualityOption> options;
  final int current;
  final bool switching;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Center(
      child: switching
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: colors.textTertiary,
                ),
              ),
            )
          : PopupMenuButton<int>(
              tooltip: '切换清晰度',
              onSelected: onPick,
              itemBuilder: (context) => <PopupMenuEntry<int>>[
                for (final option in options)
                  PopupMenuItem<int>(
                    value: option.height,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.check,
                          size: 16,
                          // 未选中也要占位，否则菜单项文字会左右跳动。
                          color: option.height == current
                              ? colors.accent
                              : Colors.transparent,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(option.label, style: AppText.callout),
                      ],
                    ),
                  ),
              ],
              // 用图标而非「清晰度 ▾」文案：窄屏（最小 420pt）下
              // 标题 + 返回 + 文案 action 会挤爆 AppBar。
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Icon(
                  Icons.high_quality,
                  size: 20,
                  color: colors.textSecondary,
                ),
              ),
            ),
    );
  }
}

class _MiniEpisodeChip extends StatelessWidget {
  const _MiniEpisodeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 48,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.contentSurface,
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: AppText.callout.copyWith(
            color: selected ? colors.accent : colors.textPrimary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
