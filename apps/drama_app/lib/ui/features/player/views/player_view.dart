import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/services/rust_core.dart';
import '../../../../domain/models/episode.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../detail/view_models/detail_view_model.dart';

/// 播放页（PRD F-05）。
///
/// W1 只有**布局占位**：画面区为不透明的黑色占位块 + 控制条骨架；
/// W3 接入 `media_kit` 与本地 StreamGateway（届时这里是全项目唯一需要
/// `platformViewBackdrop: true` 的场景，ARCH §4）。
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
  bool _playing = false;

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(detailProvider(widget.id));

    return detailAsync.when(
      data: (detail) => _player(context, detail.episodes),
      loading: () => AppGlassScaffold(
        title: '播放',
        leading: _backAction(context),
        body: const LoadingView(),
      ),
      error: (error, _) => AppGlassScaffold(
        title: '播放',
        leading: _backAction(context),
        // 未找到（StateError）走空态；其余真错误显式呈现并可重试（plan §8）。
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

  Widget _player(BuildContext context, List<Episode> episodes) {
    final colors = AppColors.of(context);
    final hasPrevious = _episode > 1;
    final hasNext = _episode < episodes.length;

    return AppGlassScaffold(
      title: '第 $_episode 集',
      leading: _backAction(context),
      body: ListView(
        children: <Widget>[
          // ── 画面区（不透明内容层） ──────────────────────────
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: const Color(0xFF000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.play_circle_outline,
                      size: 56,
                      color: Color(0xB3FFFFFF),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'W1 播放占位 · W3 接入 media_kit',
                      style: AppText.callout.copyWith(
                        color: const Color(0xB3FFFFFF),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── 进度条占位 ──────────────────────────────────────
          Padding(
            padding: AppSpacing.pageH,
            child: Column(
              children: <Widget>[
                const SizedBox(height: AppSpacing.lg),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.capsule),
                  child: LinearProgressIndicator(
                    value: 0.32,
                    minHeight: 4,
                    backgroundColor: colors.divider,
                    valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    Text(
                      '00:45',
                      style: AppText.caption.copyWith(
                        color: colors.textTertiary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '02:24',
                      style: AppText.caption.copyWith(
                        color: colors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
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
                GlassIconAction(
                  icon: _playing ? Icons.pause : Icons.play_arrow,
                  semanticLabel: _playing ? '暂停' : '播放',
                  size: 56,
                  iconSize: 26,
                  tint: colors.accent,
                  onPressed: () => setState(() => _playing = !_playing),
                ),
                const SizedBox(width: AppSpacing.lg),
                GlassIconAction(
                  icon: Icons.skip_next,
                  semanticLabel: '下一集',
                  size: 44,
                  iconSize: 20,
                  onPressed: hasNext ? () => setState(() => _episode += 1) : () {},
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
