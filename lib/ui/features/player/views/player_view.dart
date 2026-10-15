import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
    final episodes =
        ref.read(detailProvider(widget.id)).value?.episodes.length ?? 0;
    if (episodes == 0 || _episode >= episodes) return;
    _goToEpisode(_episode + 1);
  }

  /// 切集：重置续播标记（新集需按该集记录重新定位）。
  void _goToEpisode(int episode) {
    setState(() {
      _episode = episode;
      _resumeApplied = false;
    });
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

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(detailProvider(widget.id));
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
    final hasPrevious = _episode > 1;
    final hasNext = _episode < episodes.length;
    final planAsync = ref.watch(
      playPlanProvider((id: widget.id, episode: _episode)),
    );

    final settings = ref.watch(playbackSettingsProvider);
    return AppGlassScaffold(
      title: '第 $_episode 集 · ${settings.qualityLabel}',
      leading: _backAction(context),
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

          const SectionHeader(title: '选集'),
          Padding(
            padding: AppSpacing.pageH,
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final episode in episodes.take(60))
                  _MiniEpisodeChip(
                    label: '${episode.index}',
                    selected: episode.index == _episode,
                    onTap: () => _goToEpisode(episode.index),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
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
