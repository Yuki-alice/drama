import 'package:duanju_app/core/app_build.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/data/media/media_library.dart';
import 'package:duanju_app/features/lan/lan_controller.dart';
import 'package:duanju_app/app/app_shell.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/app/main.dart' show ConfigRecoveryScreen;
import 'package:duanju_app/core/providers.dart';
import 'package:duanju_app/data/media/media_library_provider.dart';
import 'package:duanju_app/features/lan/lan_controller_provider.dart';
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

/// 屏幕的公共依赖。
///
/// 路由里 15 处 `ref.read(repositoryProvider)` + `ref.read(storeProvider)`
/// 是纯样板：每个 builder 都要重复同样的两行。这里一次取齐，屏幕构造时只
/// 需展开。lan / library 属于少数屏幕才需要的可选依赖，按需传。
class AppDeps {
  const AppDeps({
    required this.repository,
    required this.store,
    this.lan,
    this.library,
  });

  final AppRepository repository;
  final LocalStore store;
  final LanController? lan;
  final MediaLibrary? library;
}

AppDeps _deps(
  WidgetRef ref, {
  bool withLan = false,
  bool withLibrary = false,
}) => AppDeps(
  repository: ref.read(repositoryProvider),
  store: ref.read(storeProvider),
  lan: withLan ? ref.read(lanControllerProvider) : null,
  library: withLibrary ? ref.read(mediaLibraryProvider) : null,
);

final routerProvider = Provider<GoRouter>((_) => _buildRouter());

GoRouter _buildRouter() => GoRouter(
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
              pageBuilder: _page((ref, state) {
                final deps = _deps(ref);
                return DiscoveryScreen(
                  repository: deps.repository,
                  store: deps.store,
                );
              }),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/follow',
              name: 'follow',
              pageBuilder: _page((ref, state) {
                final deps = _deps(ref);
                return FollowScreen(
                  repository: deps.repository,
                  store: deps.store,
                  initialHistory: state.uri.queryParameters['tab'] == 'history',
                );
              }),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/me',
              name: 'me',
              pageBuilder: _page((ref, state) {
                final deps = _deps(ref);
                return MeScreen(repository: deps.repository, store: deps.store);
              }),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/detail',
      name: 'detail',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref);
        final args = state.extra! as DetailRouteArgs;
        return DetailScreen(
          drama: args.drama,
          resumeOnOpen: args.resumeOnOpen,
          repository: deps.repository,
          store: deps.store,
        );
      }),
    ),
    GoRoute(
      path: '/player',
      name: 'player',
      pageBuilder: _immersive((ref, state) {
        final deps = _deps(ref, withLan: true);
        final args = state.extra! as PlayerRouteArgs;
        return PlayerScreen(
          detail: args.detail,
          initialIndex: args.initialIndex,
          initialPosition: args.initialPosition,
          repository: deps.repository,
          store: deps.store,
          lan: deps.lan!,
        );
      }),
    ),
    GoRoute(
      path: '/launch',
      name: 'launch',
      pageBuilder: _immersive((ref, state) {
        final deps = _deps(ref);
        final drama = state.extra! as Drama;
        return PlaybackLaunchScreen(
          drama: drama,
          repository: deps.repository,
          store: deps.store,
        );
      }),
    ),
    GoRoute(
      path: '/search',
      name: 'search',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref);
        final group = state.extra is SourceGroup
            ? state.extra as SourceGroup
            : null;
        return SearchScreen(
          repository: deps.repository,
          store: deps.store,
          group: group,
        );
      }),
    ),
    GoRoute(
      path: '/rankings',
      name: 'rankings',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref);
        final group = state.extra as String?;
        return RankingsScreen(
          repository: deps.repository,
          store: deps.store,
          initialGroup: group ?? 'all',
        );
      }),
    ),
    GoRoute(
      path: '/recommendations',
      name: 'recommendations',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref);
        return RecommendationsScreen(
          repository: deps.repository,
          store: deps.store,
        );
      }),
    ),
    GoRoute(
      path: '/batch',
      name: 'batch',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref);
        final dramas = (state.extra as List<Drama>).toList();
        return BatchDownloadScreen(
          repository: deps.repository,
          store: deps.store,
          dramas: dramas,
        );
      }),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref);
        return SettingsScreen(
          repository: deps.repository,
          store: deps.store,
          initialCategory: state.uri.queryParameters['category'],
        );
      }),
    ),
    GoRoute(
      path: '/sources',
      name: 'sources',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref);
        final args = state.extra as SourcesRouteArgs?;
        return SourcesScreen(
          repository: deps.repository,
          store: deps.store,
          initialSource: args?.initialSource,
          drama: args?.drama,
        );
      }),
    ),
    GoRoute(
      path: '/downloads',
      name: 'downloads',
      pageBuilder: _page((ref, state) {
        // DownloadsScreen 不依赖媒体库，不需要 withLibrary。
        final deps = _deps(ref);
        return DownloadsScreen(repository: deps.repository, store: deps.store);
      }),
    ),
    GoRoute(
      path: '/local-media',
      name: 'local-media',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref, withLibrary: true);
        return LocalMediaScreen(
          repository: deps.repository,
          store: deps.store,
          library: deps.library!,
        );
      }),
    ),
    GoRoute(
      path: '/merge-queue',
      name: 'merge-queue',
      pageBuilder: _page((ref, state) {
        final deps = _deps(ref, withLibrary: true);
        return MergeQueueScreen(
          library: deps.library!,
          repository: deps.repository,
          store: deps.store,
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
      return _BootScreen(
        error: failure,
        onRetry: ref.read(bootstrapRetryProvider),
      );
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
