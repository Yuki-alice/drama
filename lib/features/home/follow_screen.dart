import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/app/app_screen.dart';
import 'package:duanju_app/app/router.dart' show DetailRouteArgs;
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/home/saved_library.dart';
import 'package:duanju_app/features/lan/lan_screen.dart';
import 'package:duanju_app/features/player/playback_launch_screen.dart';

/// 追剧页：追剧与最近观看合并为同一媒体库，用分段控件切换。
class FollowScreen extends StatefulWidget {
  const FollowScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialHistory = false,
  });
  final AppRepository repository;
  final LocalStore store;

  /// 从「我的 · 历史记录」进入时直接落到最近观看。
  final bool initialHistory;

  @override
  State<FollowScreen> createState() => _FollowScreenState();
}

class _FollowScreenState extends State<FollowScreen> {
  bool _history = false;

  @override
  void initState() {
    super.initState();
    _history = widget.initialHistory;
  }

  @override
  void didUpdateWidget(covariant FollowScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialHistory != widget.initialHistory) {
      _history = widget.initialHistory;
    }
  }

  void _open(Drama drama) =>
      context.push('/detail', extra: DetailRouteArgs(drama: drama));

  void _continue(Drama drama) => unawaited(
    openPlaybackDirectly(
      context,
      drama: drama,
      repository: widget.repository,
      store: widget.store,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final canDownload =
        widget.repository.supportsDownloads && widget.store.canDownload;
    return AppScreen(
      title: '追剧',
      actions: [
        if (!_history)
          IconButton(
            key: const ValueKey('follow-lan-sync'),
            tooltip: '追剧同步',
            onPressed: () => openLanSync(context),
            icon: const Icon(Icons.sync_rounded),
          ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('追剧')),
                  ButtonSegment(value: true, label: Text('最近观看')),
                ],
                selected: {_history},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _history = selection.first),
              ),
            ),
          ),
          Expanded(
            child: SavedLibrary(
              key: ValueKey('library-$_history'),
              repository: widget.repository,
              store: widget.store,
              history: _history,
              onOpen: _open,
              onContinue: _continue,
              onDownload: canDownload
                  ? (drama) => context.push(
                      '/detail',
                      extra: DetailRouteArgs(drama: drama),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
