import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../domain/models/drama.dart';
import '../ui/core/widgets/app_glass_scaffold.dart';
import '../ui/core/widgets/content_widgets.dart';
import '../ui/features/about/views/about_view.dart';
import '../ui/features/detail/views/detail_view.dart';
import '../ui/features/disclaimer/view_models/disclaimer_view_model.dart';
import '../ui/features/disclaimer/views/disclaimer_view.dart';
import '../ui/features/downloads/views/downloads_view.dart';
import '../ui/features/home/views/home_view.dart';
import '../ui/features/library/views/library_view.dart';
import '../ui/features/player/views/player_view.dart';
import '../ui/features/profile/views/profile_view.dart';
import '../ui/features/ranking/views/ranking_view.dart';
import '../ui/features/search/views/search_view.dart';
import '../ui/features/settings/views/settings_view.dart';
import 'app_navigation_shell.dart';
import 'routes.dart';

/// 路由 `source` 查询参数：缺省/空白归主源（与 Rust 信封缺省一致）。
String _sourceOf(GoRouterState state) {
  final source = (state.uri.queryParameters['source'] ?? '').trim();
  return source.isEmpty ? 'hongguo' : source;
}

/// 应用路由。
///
/// 用 [Provider] **只读一次**首启免责声明标志来决定 `initialLocation`；
/// 之后不再重建路由器，避免"重建即重置导航栈"。首启确认由
/// [DisclaimerView] 自行 `context.go(AppRoutes.home)` 完成。
final appRouterProvider = Provider<GoRouter>((ref) {
  final acknowledged = ref.read(disclaimerAcknowledgedProvider);
  return GoRouter(
    initialLocation: acknowledged ? AppRoutes.home : AppRoutes.disclaimer,
    routes: <RouteBase>[
      // 主导航：四个分支各保留自己的状态（IndexedStack）。
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppNavigationShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.home,
                builder: (context, state) => const HomeView(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.ranking,
                builder: (context, state) => const RankingView(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.library,
                builder: (context, state) => const LibraryView(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.profile,
                builder: (context, state) => const ProfileView(),
              ),
            ],
          ),
        ],
      ),

      // 二级页：push 出来，隐藏主导航并使用 iOS 式转场。
      GoRoute(
        path: AppRoutes.search,
        pageBuilder: (context, state) => _page(const SearchView()),
      ),
      GoRoute(
        path: AppRoutes.detailPattern,
        pageBuilder: (context, state) => _page(
          DetailView(
            id: state.pathParameters['id'] ?? '',
            source: _sourceOf(state),
            // 列表卡片点入时随路携带剧目数据：详情页在数据到达前就能渲染
            // 海报头，封面 Hero 转场才有落点。深链进入时没有 extra（null），
            // 页面走普通加载态——不为深链伪造数据。
            initial: state.extra is Drama ? state.extra as Drama : null,
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.playerPattern,
        pageBuilder: (context, state) => _page(
          PlayerView(
            id: state.pathParameters['id'] ?? '',
            episode: int.tryParse(state.uri.queryParameters['ep'] ?? ''),
            source: _sourceOf(state),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.downloads,
        pageBuilder: (context, state) => _page(const DownloadsView()),
      ),
      GoRoute(
        path: AppRoutes.settings,
        pageBuilder: (context, state) => _page(const SettingsView()),
      ),
      GoRoute(
        path: AppRoutes.about,
        pageBuilder: (context, state) => _page(const AboutView()),
      ),
      GoRoute(
        path: AppRoutes.disclaimer,
        pageBuilder: (context, state) => _page(const DisclaimerView()),
      ),
    ],
    errorBuilder: (context, state) =>
        _AppErrorView(detail: state.error?.toString()),
  );
});

/// iOS 式转场（玻璃 UI 的目标观感，非 Android 默认转场）。
Page<void> _page(Widget child) => CupertinoPage<void>(child: child);

/// 路由错误页。
class _AppErrorView extends StatelessWidget {
  const _AppErrorView({this.detail});

  final String? detail;

  @override
  Widget build(BuildContext context) => AppGlassScaffold(
        title: '页面不存在',
        body: Center(
          child: ErrorView(
            message: detail ?? '未找到该页面',
            onRetry: () => context.go(AppRoutes.home),
          ),
        ),
      );
}
