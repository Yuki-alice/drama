import 'package:flutter/material.dart';

import 'package:duanju_app/app/app_theme.dart';

/// 统一页面骨架：顶栏初始与内容同为 canvas，滚动后过渡到导航着色，
/// 对应 Animeko 的 topAppBarColors(scrolledContainerColor: surfaceContainer)。
class AppScreen extends StatefulWidget {
  const AppScreen({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.leading,
    this.floatingTitle = false,
    this.bottomBar,
    this.floatingActionButton,
    this.maxContentWidth,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? leading;

  /// 标题随滚动渐显（详情页用），否则始终显示。
  final bool floatingTitle;
  final Widget? bottomBar;
  final Widget? floatingActionButton;
  final double? maxContentWidth;

  @override
  State<AppScreen> createState() => _AppScreenState();
}

class _AppScreenState extends State<AppScreen> {
  bool _scrolled = false;

  bool _onScroll(ScrollUpdateNotification notification) {
    if (notification.depth > 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final next = notification.metrics.pixels > 24;
    if (next != _scrolled) setState(() => _scrolled = next);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = AppSurfaces.of(context);
    final body = NotificationListener<ScrollUpdateNotification>(
      onNotification: _onScroll,
      child: widget.body,
    );
    return Scaffold(
      backgroundColor: surfaces.canvas,
      appBar: AppBar(
        leading: widget.leading,
        automaticallyImplyLeading: widget.leading == null,
        backgroundColor: _scrolled ? surfaces.navContainer : surfaces.canvas,
        foregroundColor: theme.colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 16,
        centerTitle: false,
        title: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          opacity: widget.floatingTitle && !_scrolled ? 0 : 1,
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -.2,
            ),
          ),
        ),
        actions: [...widget.actions, const SizedBox(width: 4)],
      ),
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: widget.bottomBar,
      body: widget.maxContentWidth == null
          ? body
          : Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.maxContentWidth!),
                child: body,
              ),
            ),
    );
  }
}
