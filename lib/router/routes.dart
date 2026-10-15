/// 声明式路由的路径常量（导航骨架）。
///
/// 用常量而非裸字符串，保证 `context.go(...)` 与路由表不会各自漂移。
abstract final class AppRoutes {
  // ── 主分支（承载底部/侧边导航） ──────────────────────────────
  static const String home = '/home';
  static const String ranking = '/ranking';
  static const String library = '/library';
  static const String profile = '/profile';

  // ── 二级页（push 出来，隐藏主导航） ──────────────────────────
  static const String search = '/search';
  static const String downloads = '/downloads';
  static const String settings = '/settings';
  static const String about = '/about';
  static const String disclaimer = '/disclaimer';

  // ── 带路径参数 ───────────────────────────────────────────────
  static const String detailPattern = '/drama/:id';
  static const String playerPattern = '/player/:id';

  /// 详情页路径。
  static String detail(String id) => '/drama/$id';

  /// 播放页路径；`episode` 为 1-based 集号。
  static String player(String id, {int? episode}) =>
      episode == null ? '/player/$id' : '/player/$id?ep=$episode';
}
