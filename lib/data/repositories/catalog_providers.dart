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
/// 分类表按源映射（`version` 暂不下发分类，R2 再补）；未知源给空表，
/// 不冒充有分类。
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

List<DramaCategory> _categoriesFor(String source) => switch (source) {
  'hongguo' => HongguoCategories.all,
  'huangguoai' => HuangguoCategories.all,
  _ => const <DramaCategory>[],
};

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
