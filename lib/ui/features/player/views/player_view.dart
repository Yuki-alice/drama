import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../data/repositories/playback_repository.dart';
import '../../../../data/repositories/progress_repository.dart';
import '../../../../data/services/rust_core.dart';
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

  /// 自动连播：仅当当前集不是最后一集时前进。
  void _playNextIfAny() {
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

  /// 打开该集媒体；若本集正是上次观看到的那一集，则跳到上次位置续播。
  ///
  /// 续播只在「记录集号 == 当前集」时生效——历史记录只存最后观看的一集，
  /// 用户手动切到别的集时不该套用旧偏移。
  Future<void> _openAndMaybeResume(PlaybackPlan plan) async {
    final episodeAtOpen = _episode;
    await _player.open(Media(plan.proxyUrl));
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

    return AppGlassScaffold(
      title: '第 $_episode 集',
      leading: _backAction(context),
      body: ListView(
        children: <Widget>[
          // ── 画面区（不透明内容层，真播放器） ───────────────────
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: const Color(0xFF000000),
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
                                color: const Color(0xB3FFFFFF),
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

          // ── 进度条（播放器真实位置） ───────────────────────────
          Padding(
            padding: AppSpacing.pageH,
            child: StreamBuilder<Duration>(
              stream: _player.stream.position,
              builder: (context, position) => StreamBuilder<Duration>(
                stream: _player.stream.duration,
                builder: (context, duration) {
                  final total = duration.data ?? Duration.zero;
                  final current = position.data ?? Duration.zero;
                  final progress = total.inMilliseconds > 0
                      ? (current.inMilliseconds / total.inMilliseconds).clamp(
                          0.0,
                          1.0,
                        )
                      : 0.0;
                  return Column(
                    children: <Widget>[
                      const SizedBox(height: AppSpacing.lg),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.capsule),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: colors.divider,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            colors.accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: <Widget>[
                          Text(
                            _formatDuration(current),
                            style: AppText.caption.copyWith(
                              color: colors.textTertiary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _formatDuration(total),
                            style: AppText.caption.copyWith(
                              color: colors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
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
