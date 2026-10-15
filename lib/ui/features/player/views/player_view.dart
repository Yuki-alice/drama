import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../data/repositories/playback_repository.dart';
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

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(detailProvider(widget.id));
    // 取流就绪即打开；切集（key 变化）自动重解重开。
    ref.listen(playPlanProvider((id: widget.id, episode: _episode)), (_, next) {
      next.whenData((plan) {
        _player.open(Media(plan.proxyUrl));
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
                      ? () => setState(() => _episode -= 1)
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
                      ? () => setState(() => _episode += 1)
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
                    onTap: () => setState(() => _episode = episode.index),
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
