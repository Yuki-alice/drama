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
  ///
  /// `source` 缺省/主源时不拼 query（老路径字节不变，深链兼容）。
  static String detail(String id, {String source = 'hongguo'}) =>
      source == 'hongguo' ? '/drama/$id' : '/drama/$id?source=$source';

  /// 播放页路径；`episode` 为 1-based 集号。
  static String player(String id, {int? episode, String source = 'hongguo'}) {
    final base = '/player/$id';
    final query = <String>[
      if (episode != null) 'ep=$episode',
      if (source != 'hongguo') 'source=$source',
    ];
    return query.isEmpty ? base : '$base?${query.join('&')}';
  }
}
