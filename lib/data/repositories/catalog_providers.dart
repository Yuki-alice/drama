import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/drama_category.dart';
import '../../domain/models/source.dart';
import '../services/rust_core.dart';
import 'catalog_repository.dart';
import 'fake_catalog_repository.dart';
import 'source_catalog_repository.dart';

/// Rust 核心实例。
///
/// `null` = 核心不可用（native asset 缺失/初始化失败）→ 全站回退到 mock。
/// 在 `main()` 中用 `overrideWithValue` 注入（见 `lib/main.dart`）。
final rustCoreProvider = Provider<RustCoreHolder?>((ref) => null);

/// 目录仓库：核心在线走红果免签轨①，否则回退 [FakeCatalogRepository]。
///
/// 回退是**显式已知**行为（不是静默失败）：核心不可用时 UI 仍可导航与展示
/// mock，避免整站白屏；真实错误（网络/解析）由具体 op 抛 `RustCoreException`
/// 上报给 UI 的错误态。
///
/// **缓存策略已下沉到 Rust**（`rust/core/src/cache.rs`：TTL / 弱网回退 /
/// 榜单熔断 / 并发去重 / 分页水位 / 封面端口自愈），因此这里不再包
/// `CachingCatalogRepository` 装饰器——每个请求直接进 Rust，由 Rust 决定
/// 命中缓存还是打网络，并在 `data.stale` 里回报是否用了兜底旧值。
final catalogRepositoryProvider = Provider<CatalogRepository>((ref) {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) {
    debugPrint('[W2] Rust 核心不可用，目录仓库回退到 mock 实现');
    return FakeCatalogRepository();
  }

  return SourceCatalogRepository(
    holder.core,
    onStale: (stale) {
      // 延迟到当前调用栈之后，避免在别的 provider 构建期间同步改状态。
      Future<void>.microtask(
        () => ref.read(staleDataNoticeProvider.notifier).setStale(stale),
      );
    },
  );
});

/// 可用源列表（`version` 下发 id + caps；选源器与 caps 门控的数据源）。
///
/// 核心不可用时为空（搜索等调用方按既有错误路径处理，不静默造源）。
/// 结果由 Riverpod 缓存，进程内只拉一次。
final availableSourcesProvider = FutureProvider<List<SourceInfo>>((ref) async {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) return const <SourceInfo>[];
  final envelope = await holder.core.call('version');
  if (envelope['ok'] != true) return const <SourceInfo>[];
  final data = envelope['data'];
  if (data is! Map) return const <SourceInfo>[];
  final sources = (Map<String, Object?>.from(data))['sources'];
  if (sources is! List) return const <SourceInfo>[];
  return <SourceInfo>[
    for (final item in sources)
      if (item is Map) SourceInfo.fromJson(Map<String, Object?>.from(item)),
  ];
});

/// 按源取目录仓库（搜索/详情等跨源入口用；首页仍走默认的
/// [catalogRepositoryProvider]，行为不变）。
///
/// 分类表：内置源用硬编码表（与历史行为一致）；规则源**异步拉后端**
/// `categories` op（规则包声明了什么分类就展示什么，前端不硬编码）。
final catalogRepositoryForSourceProvider =
    Provider.family<CatalogRepository, String>((ref, source) {
      final holder = ref.watch(rustCoreProvider);
      if (holder == null) return FakeCatalogRepository();
      return SourceCatalogRepository(
        holder.core,
        source: source,
        categoryList: _categoriesFor(source),
        onStale: (stale) {
          Future<void>.microtask(
            () => ref.read(staleDataNoticeProvider.notifier).setStale(stale),
          );
        },
      );
    });

/// 规则源分类缓存（`categories` op 结果，进程内一次）。
///
/// 为什么放这里而不是 provider family：分类表是**每个源一份**的静态数据，
/// 与仓库实例无关；缓存住避免每次切源都打一次网络。
final _ruleSourceCategories = <String, List<DramaCategory>>{};

/// 取规则源分类：先查缓存，未命中则拉 `categories` op。
///
/// 拉取失败返回空表——规则包没声明分类时 UI 不显示分类条，
/// 不冒充「全部」。同步返回是因为 `Provider.family` 不支持 async 构造；
/// 真正的拉取由首页首次加载触发（见 [_ensureRuleCategories]）。
List<DramaCategory> _categoriesFor(String source) => switch (source) {
  'hongguo' => HongguoCategories.all,
  'huangguoai' => HuangguoCategories.all,
  _ => _ruleSourceCategories[source] ?? const <DramaCategory>[],
};

/// 拉取规则源分类（`categories` op；进程级缓存，重复调用不重复打网络）。
///
/// wire 形态 `[{id, name}]`；失败返回空表——规则包没声明分类时 UI
/// 不显示分类条，不冒充「全部」。
Future<List<DramaCategory>> fetchRuleSourceCategories(
  ProviderContainer container,
  String source,
) async {
  if (source == 'hongguo' || source == 'huangguoai') {
    return _categoriesFor(source);
  }
  final cached = _ruleSourceCategories[source];
  if (cached != null) return cached;

  final holder = container.read(rustCoreProvider);
  if (holder == null) return const <DramaCategory>[];
  try {
    final envelope = await holder.core.call('categories', source: source);
    if (envelope['ok'] != true) return const <DramaCategory>[];
    final data = envelope['data'];
    final items = data is Map ? data['items'] : null;
    if (items is! List) return const <DramaCategory>[];
    final categories = <DramaCategory>[
      for (final item in items)
        if (item is Map)
          DramaCategory(
            id: (item['id'] as String? ?? ''),
            name: (item['name'] as String? ?? ''),
          ),
    ];
    _ruleSourceCategories[source] = categories;
    return categories;
  } on Object {
    return const <DramaCategory>[];
  }
}

/// 是否正在展示「缓存兜底」数据（供 home 页显示轻提示）。
///
/// 由 [SourceCatalogRepository] 经回调置位：读到 Rust 返回的
/// `data.stale == true`（网络失败后的兜底旧值）→ true；否则 false。
class StaleNoticeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setStale(bool stale) {
    if (state != stale) state = stale;
  }
}

final staleDataNoticeProvider = NotifierProvider<StaleNoticeNotifier, bool>(
  StaleNoticeNotifier.new,
);
