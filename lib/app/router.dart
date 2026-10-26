import 'package:duanju_app/core/app_build.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/app/app_shell.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/app/main.dart' show ConfigRecoveryScreen;
import 'package:duanju_app/core/providers.dart';
import 'package:duanju_app/features/downloads/media_library.dart';
import 'package:duanju_app/features/detail/detail_screen.dart';
import 'package:duanju_app/features/downloads/downloads_screen.dart';
import 'package:duanju_app/features/downloads/batch_download_screen.dart';
import 'package:duanju_app/features/downloads/local_media_screen.dart';
import 'package:duanju_app/features/downloads/merge_queue_screen.dart';
import 'package:duanju_app/features/home/discovery_screen.dart';
import 'package:duanju_app/features/home/follow_screen.dart';
import 'package:duanju_app/features/home/rankings_screen.dart';
import 'package:duanju_app/features/home/recommendations_screen.dart';
import 'package:duanju_app/features/home/search_screen.dart';
import 'package:duanju_app/features/me/me_screen.dart';
import 'package:duanju_app/features/player/player_screen.dart';
import 'package:duanju_app/features/player/playback_launch_screen.dart';
import 'package:duanju_app/features/settings/settings_screen.dart';
import 'package:duanju_app/features/sources/sources_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 路由参数：复杂对象经 extra 传递，保持各屏构造函数不变。
class DetailRouteArgs {
  const DetailRouteArgs({required this.drama, this.resumeOnOpen = false});
  final Drama drama;
  final bool resumeOnOpen;
}

class PlayerRouteArgs {
  const PlayerRouteArgs({
    required this.detail,
    this.initialIndex = 0,
    this.initialPosition = 0,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
}

class SourcesRouteArgs {
  const SourcesRouteArgs({this.initialSource, this.drama});
  final String? initialSource;
  final Drama? drama;
}

final router = GoRouter(
  initialLocation: '/discover',
  routes: [
    // 一级导航：三个分支各自保留状态，二级页面挂在外层全屏渲染。
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _AppGate(child: AppShell(navigationShell: navigationShell)),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/discover',
              name: 'discover',
              pageBuilder: _page(
                (ref, state) => DiscoveryScreen(
                  repository: ref.read(repositoryProvider),
                  store: ref.read(storeProvider),
                ),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/follow',
              name: 'follow',
              pageBuilder: _page(
                (ref, state) => FollowScreen(
                  repository: ref.read(repositoryProvider),
                  store: ref.read(storeProvider),
                  initialHistory:
                      state.uri.queryParameters['tab'] == 'history',
                ),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/me',
              name: 'me',
              pageBuilder: _page(
                (ref, state) => MeScreen(
                  repository: ref.read(repositoryProvider),
                  store: ref.read(storeProvider),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/detail',
      name: 'detail',
      pageBuilder: _page((ref, state) {
        final args = state.extra! as DetailRouteArgs;
        return DetailScreen(
          drama: args.drama,
          resumeOnOpen: args.resumeOnOpen,
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
        );
      }),
    ),
    GoRoute(
      path: '/player',
      name: 'player',
      pageBuilder: _immersive((ref, state) {
        final args = state.extra! as PlayerRouteArgs;
        return PlayerScreen(
          detail: args.detail,
          initialIndex: args.initialIndex,
          initialPosition: args.initialPosition,
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
        );
      }),
    ),
    GoRoute(
      path: '/launch',
      name: 'launch',
      pageBuilder: _immersive((ref, state) {
        final drama = state.extra! as Drama;
        return PlaybackLaunchScreen(
          drama: drama,
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
        );
      }),
    ),
    GoRoute(
      path: '/search',
      name: 'search',
      pageBuilder: _page((ref, state) {
        final group = state.extra is SourceGroup ? state.extra as SourceGroup : null;
        return SearchScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
          group: group,
        );
      }),
    ),
    GoRoute(
      path: '/rankings',
      name: 'rankings',
      pageBuilder: _page((ref, state) {
        final group = state.extra as String?;
        return RankingsScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
          initialGroup: group ?? 'all',
        );
      }),
    ),
    GoRoute(
      path: '/recommendations',
      name: 'recommendations',
      pageBuilder: _page(
        (ref, state) => RecommendationsScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
        ),
      ),
    ),
    GoRoute(
      path: '/batch',
      name: 'batch',
      pageBuilder: _page((ref, state) {
        final dramas = (state.extra as List<Drama>).toList();
        return BatchDownloadScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
          dramas: dramas,
        );
      }),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      pageBuilder: _page(
        (ref, state) => SettingsScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
          initialCategory: state.uri.queryParameters['category'],
        ),
      ),
    ),
    GoRoute(
      path: '/sources',
      name: 'sources',
      pageBuilder: _page((ref, state) {
        final args = state.extra as SourcesRouteArgs?;
        return SourcesScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
          initialSource: args?.initialSource,
          drama: args?.drama,
        );
      }),
    ),
    GoRoute(
      path: '/downloads',
      name: 'downloads',
      pageBuilder: _page(
        (ref, state) => DownloadsScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
        ),
      ),
    ),
    GoRoute(
      path: '/local-media',
      name: 'local-media',
      pageBuilder: _page(
        (ref, state) => LocalMediaScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(storeProvider),
        ),
      ),
    ),
    GoRoute(
      path: '/merge-queue',
      name: 'merge-queue',
      pageBuilder: _page((ref, state) {
        final repository = ref.read(repositoryProvider);
        final store = ref.read(storeProvider);
        return MergeQueueScreen(
          library: MediaLibrary.current ?? MediaLibrary(repository, store),
          repository: repository,
          store: store,
        );
      }),
    ),
  ],
);

/// 启动门禁：初始化中显示占位，失败显示重试，锁定显示恢复。
class _AppGate extends ConsumerWidget {
  const _AppGate({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appReadyProvider)) {
      return const _BootScreen();
    }
    final failure = ref.watch(bootstrapErrorProvider);
    if (failure != null) {
      return _BootScreen(error: failure, onRetry: ref.read(bootstrapRetryProvider));
    }
    final store = ref.watch(storeProvider);
    if (store.locked) return ConfigRecoveryScreen(store: store);
    return child;
  }
}

/// 沉浸式页面（播放/启动）：无转场直切，保持全屏观感。
GoRouterPageBuilder _immersive(
  Widget Function(WidgetRef ref, GoRouterState state) builder,
) =>
    (context, state) => CustomTransitionPage(
      key: state.pageKey,
      child: Consumer(builder: (context, ref, _) => builder(ref, state)),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      transitionsBuilder: (_, _, _, child) => child,
    );

/// 统一页面构建：屏幕经 Consumer 从 provider 读取 repository/store，
/// fade-through 强调曲线转场（AppMotion 令牌）。
GoRouterPageBuilder _page(
  Widget Function(WidgetRef ref, GoRouterState state) builder,
) =>
    (context, state) => CustomTransitionPage(
      key: state.pageKey,
      child: Consumer(builder: (context, ref, _) => builder(ref, state)),
      transitionDuration: AppMotion.enter,
      reverseTransitionDuration: AppMotion.exit,
      transitionsBuilder: (context, animation, secondary, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.standard,
          reverseCurve: AppMotion.decelerate,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.03),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );

/// 启动占位：初始化进度与失败重试。
class _BootScreen extends StatelessWidget {
  const _BootScreen({this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.play_circle_fill_rounded,
              color: Color(0xFFFF765F),
              size: 72,
            ),
            const SizedBox(height: 24),
            Text(
              error ?? '正在打开$appName',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 24),
            if (error == null)
              const CircularProgressIndicator()
            else
              FilledButton(onPressed: onRetry, child: const Text('重新打开')),
          ],
        ),
      ),
    ),
  );
}
