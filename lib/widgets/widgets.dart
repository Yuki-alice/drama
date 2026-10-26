import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/responsive/window_type.dart';

Future<void> saveUserChange(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未能保存，请检查存储空间和权限后重试。')));
    }
  }
}

class RefreshAction extends StatefulWidget {
  const RefreshAction({
    super.key,
    required this.loading,
    required this.tooltip,
    required this.onPressed,
  });
  final bool loading;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<RefreshAction> createState() => _RefreshActionState();
}

class _RefreshActionState extends State<RefreshAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.loading) _rotation.repeat();
  }

  @override
  void didUpdateWidget(covariant RefreshAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading == oldWidget.loading) return;
    if (widget.loading) {
      _rotation.repeat();
    } else {
      _rotation.reset();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    value: widget.loading ? '正在更新' : null,
    child: IconButton(
      tooltip: widget.loading ? '正在更新' : widget.tooltip,
      onPressed: widget.loading ? null : widget.onPressed,
      disabledColor: widget.loading
          ? Theme.of(context).colorScheme.primary
          : null,
      icon: RotationTransition(
        turns: _rotation,
        child: const Icon(Icons.refresh_rounded),
      ),
    ),
  );
}

class DramaCover extends StatelessWidget {
  const DramaCover({
    super.key,
    required this.drama,
    required this.repository,
    this.radius = AppShapes.large,
  });
  final Drama drama;
  final AppRepository repository;
  final double radius;
  static const imagesDisabled = bool.fromEnvironment('DISABLE_REMOTE_IMAGES');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerHighest, colors.surfaceContainer],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_creation_outlined,
          size: 40,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          placeholder,
          if (!imagesDisabled && drama.id.isNotEmpty)
            CachedCoverImage(
              key: ValueKey('${drama.id}\u0000${drama.cover}'),
              drama: drama,
              repository: repository,
              placeholder: placeholder,
            ),
          // 底部渐变遮罩：集数信息在任意封面上可读。
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [.55, 1],
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: .62),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (drama.episodes > 0)
            Positioned(
              left: AppSpacing.sm,
              bottom: AppSpacing.sm,
              child: Text(
                '共 ${drama.episodes} 集',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .2,
                  shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
            ),
          if (drama.vip)
            Positioned(
              left: AppSpacing.sm,
              top: AppSpacing.sm,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6C86B),
                  borderRadius: BorderRadius.circular(AppShapes.full),
                ),
                child: const Text(
                  'VIP',
                  style: TextStyle(
                    color: Color(0xFF40300D),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CachedCoverImage extends StatefulWidget {
  const CachedCoverImage({
    super.key,
    required this.drama,
    required this.repository,
    required this.placeholder,
  });
  final Drama drama;
  final AppRepository repository;
  final Widget placeholder;
  @override
  State<CachedCoverImage> createState() => _CachedCoverImageState();
}

class _CoverRequests {
  static const _limit = 6;
  static final _waiting = <VoidCallback>[];
  static var _running = 0;

  static void add(VoidCallback start) {
    _waiting.add(start);
    _drain();
  }

  static void remove(VoidCallback start) => _waiting.remove(start);

  static Future<String> run(Future<String> Function() request) async {
    try {
      return await request();
    } finally {
      _running--;
      _drain();
    }
  }

  static void _drain() {
    while (_running < _limit && _waiting.isNotEmpty) {
      _running++;
      _waiting.removeLast()();
    }
  }
}

class _CachedCoverImageState extends State<CachedCoverImage> {
  Future<String>? _file;
  Timer? _delay;
  int _coverRevision = 0;
  bool _coverFailed = false;
  bool _retryOnFailure = false;
  bool _retryQueued = false;
  String? _failedPath;

  @override
  void initState() {
    super.initState();
    _coverRevision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _request();
  }

  void _request() {
    _cancelRequest();
    if (widget.repository.coverCached(widget.drama)) {
      _file = widget.repository.cover(widget.drama);
      return;
    }
    _file = null;
    _delay = Timer(
      const Duration(milliseconds: 150),
      () => _CoverRequests.add(_start),
    );
  }

  void _start() {
    final drama = widget.drama;
    final file = _CoverRequests.run(() => widget.repository.cover(drama));
    setState(() {
      _file = file;
    });
  }

  void _cancelRequest() {
    _delay?.cancel();
    _delay = null;
    _CoverRequests.remove(_start);
  }

  @override
  void didUpdateWidget(covariant CachedCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.catalogUpdates.removeListener(_metadataChanged);
      widget.repository.catalogUpdates.addListener(_metadataChanged);
    }
    if (oldWidget.repository != widget.repository ||
        oldWidget.drama.id != widget.drama.id ||
        oldWidget.drama.cover != widget.drama.cover ||
        oldWidget.drama.source != widget.drama.source) {
      _coverFailed = _retryOnFailure = false;
      _failedPath = null;
      _coverRevision = widget.repository.catalogUpdates.coverRevision(
        widget.drama.id,
      );
      _request();
    }
  }

  void _metadataChanged() {
    final revision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    if (revision == _coverRevision) return;
    _coverRevision = revision;
    _retryOnFailure = true;
    if (_coverFailed) _queueRetry();
  }

  void _queueRetry() {
    if (_retryQueued || !_retryOnFailure) return;
    _retryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retryQueued = false;
      if (!mounted || !_retryOnFailure) return;
      _retryOnFailure = false;
      _retry(_failedPath);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _cancelRequest();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    super.dispose();
  }

  Future<void> _retry(String? path) async {
    if (path != null) {
      await ResizeImage.resizeIfNeeded(
        440,
        null,
        FileImage(File(path)),
      ).evict();
    }
    if (mounted) {
      _cancelRequest();
      setState(() {
        _coverFailed = _retryOnFailure = false;
        _failedPath = null;
        _file = widget.repository.cover(
          widget.repository.catalogUpdates.current(widget.drama),
          force: true,
        );
      });
    }
  }

  Widget _failed(String? path) {
    _coverFailed = true;
    _failedPath = path;
    if (_retryOnFailure) _queueRetry();
    return Center(
      child: IconButton(
        tooltip: '重试海报',
        onPressed: () => _retry(path),
        icon: Icon(
          Icons.refresh_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _file == null
      ? widget.placeholder
      : FutureBuilder<String>(
          future: _file,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return widget.placeholder;
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _failed(null);
            }
            return Image.file(
              File(snapshot.data!),
              fit: BoxFit.cover,
              cacheWidth: 440,
              excludeFromSemantics: true,
              errorBuilder: (_, error, stack) => _failed(snapshot.data),
            );
          },
        );
}

class DramaTile extends StatelessWidget {
  const DramaTile({
    super.key,
    required this.drama,
    required this.repository,
    required this.onTap,
    this.subtitle,
    this.focusNode,
    this.onFocus,
    this.actions,
    this.badge,
    this.selected,
    this.onMore,
    this.onLongPress,
  });
  final Drama drama;
  final AppRepository repository;
  final VoidCallback onTap;
  final String? subtitle;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final Widget? actions;
  final String? badge;
  final bool? selected;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;

  static double titleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(14) * 2.6;

  static double subtitleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(12) * 1.3;

  /// 标题压在海报上，卡片高度即 2:3 海报本身。
  static double extentFor(BuildContext context, double width) =>
      (width * 1.5).ceilToDouble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overlay = theme.textTheme.titleSmall?.copyWith(
      height: 1.3,
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: Colors.white,
      shadows: const [
        Shadow(blurRadius: 8, color: Color(0xB3000000), offset: Offset(0, 1)),
      ],
    );
    final content = AspectRatio(
      aspectRatio: 2 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppShapes.largeIncreased),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DramaCover(drama: drama, repository: repository, radius: 0),
            // 底部遮罩承载标题文字，保证任意海报上都有足够对比度。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Color(0xB8000000), Color(0x00000000)],
                ),
              ),
              child: SizedBox.expand(),
            ),
            Positioned(
              left: AppSpacing.md,
              right: AppSpacing.md,
              bottom: AppSpacing.sm,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          height: 1.3,
                          color: Colors.white70,
                          shadows: const [
                            Shadow(
                              blurRadius: 6,
                              color: Color(0xB3000000),
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Text(
                    drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: overlay,
                  ),
                ],
              ),
            ),
            if (drama.vip)
              Positioned(
                left: AppSpacing.sm,
                top: AppSpacing.sm,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(AppShapes.extraSmall),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      'VIP',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            if (badge != null && badge!.isNotEmpty)
              Positioned(
                left: AppSpacing.sm,
                top: drama.vip ? 30.0 : AppSpacing.sm,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(AppShapes.full),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 3,
                    ),
                    child: Text(
                      badge!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .2,
                      ),
                    ),
                  ),
                ),
              ),
            if (actions != null && selected == null)
              Positioned(top: 2, right: 2, child: actions!),
            if (selected != null)
              Positioned(
                top: 6,
                right: 6,
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: selected!
                      ? theme.colorScheme.primary
                      : Colors.black.withValues(alpha: .64),
                  child: Icon(
                    selected! ? Icons.check_rounded : Icons.circle_outlined,
                    size: 22,
                    color: selected!
                        ? theme.colorScheme.onPrimary
                        : Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${drama.title}，${drama.episodes}集',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress ?? onMore,
        onSecondaryTap: onMore,
        borderRadius: BorderRadius.circular(AppShapes.largeIncreased),
        child: content,
      ),
    );
  }
}

class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.title,
    this.message = '',
    this.onRetry,
    this.icon = Icons.movie_filter_outlined,
    this.action = '重试',
    this.secondaryAction,
  });
  final String title;
  final String message;
  final VoidCallback? onRetry;
  final IconData icon;
  final String action;
  final Widget? secondaryAction;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图标置入 primaryContainer 音调圆：MD3 空态语言。
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 44, color: colors.onPrimaryContainer),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(title, textAlign: TextAlign.center, style: text.headlineSmall),
            if (message.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(action),
              ),
            ],
            if (secondaryAction != null) ...[
              const SizedBox(height: AppSpacing.sm),
              secondaryAction!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 骨架屏单元：shimmer 扫光呼吸块，Expressive 大圆角。
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width = double.infinity,
    this.height = 16,
    this.radius = AppShapes.small,
    this.padding = EdgeInsets.zero,
  });
  final double width;
  final double height;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// 目录加载骨架：与 [dramaGridDelegate] 同构的海报网格占位。
class CatalogSkeleton extends StatelessWidget {
  const CatalogSkeleton({super.key, this.width});
  final double? width;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = width ?? constraints.maxWidth;
        final columns = windowTypeOf(available).gridColumns(available);
        final spacing = catalogGridSpacing(available);
        const rows = 3;
        return Column(
          children: [
            for (var row = 0; row < rows; row++)
              Padding(
                padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : spacing),
                child: Row(
                  children: [
                    for (var column = 0; column < columns; column++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: column == columns - 1 ? 0 : spacing,
                          ),
                          child: const AspectRatio(
                            aspectRatio: 2 / 3,
                            child: SkeletonBox(
                              radius: AppShapes.largeIncreased,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 海报网格间距：紧凑端更密，宽屏更舒展。
double catalogGridSpacing(double width) => width < 600 ? 10.0 : 18.0;

SliverGridDelegate dramaGridDelegate(BuildContext context, double width) {
  final columns = windowTypeOf(width).gridColumns(width);
  final spacing = catalogGridSpacing(width);
  final tileWidth = (width - (columns - 1) * spacing) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: spacing + 6,
    crossAxisSpacing: spacing,
    mainAxisExtent: DramaTile.extentFor(context, tileWidth),
  );
}

String formatPosition(double seconds) {
  final value = seconds.isFinite ? seconds.toInt().clamp(0, 999999) : 0;
  return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
}
