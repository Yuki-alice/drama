import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cache_store.dart';
import '../services/rust_core.dart';
import 'caching_catalog_repository.dart';
import 'catalog_repository.dart';
import 'fake_catalog_repository.dart';
import 'hongguo_catalog_repository.dart';

/// Rust 核心实例。
///
/// `null` = 核心不可用（native asset 缺失/初始化失败）→ 全站回退到 mock。
/// 在 `main()` 中用 `overrideWithValue` 注入（见 `lib/main.dart`）。
final rustCoreProvider = Provider<RustCoreHolder?>((ref) => null);

/// 目录缓存存储。
///
/// `null` = 未注入（例如 widget 测试）→ 目录仓库**跳过缓存装饰器**直接透传，
/// 保证测试无需注入缓存也能跑。启动时在 `main()` 里 `overrideWithValue`
/// 注入已 `load()` 完毕的 [FileCacheStore]。
final cacheStoreProvider = Provider<CacheStore?>((ref) => null);

/// 目录仓库：核心在线走红果免签轨①（包缓存装饰器），否则回退 [FakeCatalogRepository]。
///
/// 回退是**显式已知**行为（不是静默失败）：核心不可用时 UI 仍可导航与展示
/// mock，避免整站白屏；真实错误（网络/解析）由具体 op 抛 `RustCoreException`
/// 上报给 UI 的错误态。
final catalogRepositoryProvider = Provider<CatalogRepository>((ref) {
  final holder = ref.watch(rustCoreProvider);
  if (holder == null) {
    debugPrint('[W2] Rust 核心不可用，目录仓库回退到 mock 实现');
    return FakeCatalogRepository();
  }

  final store = ref.watch(cacheStoreProvider);
  if (store == null) {
    // 未注入缓存：直接返回真实仓库（widget 测试路径）。
    return HongguoCatalogRepository(holder.core, holder: holder);
  }

  return CachingCatalogRepository(
    inner: HongguoCatalogRepository(holder.core, holder: holder),
    store: store,
    onStale: (message) {
      // 延迟到当前调用栈之后，避免在别的 provider 构建期间同步改状态。
      Future<void>.microtask(
        () => ref
            .read(staleDataNoticeProvider.notifier)
            .setStale(message != null),
      );
    },
  );
});

/// 是否正在展示「缓存兜底」数据（供 home 页显示轻提示）。
///
/// 由 [CachingCatalogRepository] 经回调置位：缓存兜底 → true；网络成功 → false。
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
