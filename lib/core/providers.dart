import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'catalog_updates.dart';
import 'core_bridge.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'models.dart';

/// 目录更新事件通道：由组合根与仓库共用同一实例。
final catalogUpdatesProvider = Provider<CatalogUpdates>((ref) {
  return CatalogUpdates();
});

/// FFI 仓库桥：应用启动时由 bootstrap 覆写注入实际实例。
final repositoryProvider = Provider<AppRepository>((ref) {
  throw UnimplementedError('由 AppBootstrap override');
});

/// 单用户本地存储桥（ChangeNotifier 桥接，业务代码可渐进迁移 watch）。
final storeProvider = ChangeNotifierProvider<LocalStore>((ref) {
  throw UnimplementedError('由 AppBootstrap override');
});

// —— 分领域订阅入口 ——
//
// `LocalStore` 是单个 ChangeNotifier：任何写入都会唤醒全部监听者，
// 于是 15 秒一次的进度保存会重建详情页/下载页整屏。下面这些 provider
// 只在对应领域真正变化时才更新，配合 `ref.watch` 即可做细粒度重建。
// 不使用对象相等性是因为 Drama/WatchEntry 都没实现 `==`。
//
// 注意：不能写成 `Provider(() { final s = ref.watch(storeProvider); return s.someRevision; })`
// ——`ChangeNotifierProvider` 的 notifyListeners 不会改变 provider 的 state
// 实例，`ref.watch(storeProvider)` 因此不会重算，修订号会永远停在旧值。
// 必须用 `ref.listen` 显式接收通知。

/// 把 [LocalStore] 的某个修订号暴露成可订阅的 [Notifier]。
///
/// [selector] 每次收到通知时重读，只有值变化才通知下游。
class StoreRevisionNotifier extends Notifier<int> {
  StoreRevisionNotifier(this._select);
  final int Function(LocalStore store) _select;
  LocalStore? _store;

  @override
  int build() {
    final store = ref.watch(storeProvider);
    if (_store != store) {
      _store = store;
    }
    // listen 的回调在 store 每次 notify 后执行；select 抽出的值不变时
    // 不更新 state，下游就不会重建。
    ref.listen<LocalStore>(storeProvider, (_, next) {
      final value = _select(next);
      if (value != state) state = value;
    }, fireImmediately: false);
    return _select(store);
  }
}

/// 库数据（历史/收藏/追剧）修订号。
final libraryRevisionProvider = NotifierProvider<StoreRevisionNotifier, int>(
  () => StoreRevisionNotifier((store) => store.libraryRevision),
);

/// 设置（主题、播放/下载偏好、目录视图、搜索记录）修订号。
final settingsRevisionProvider = NotifierProvider<StoreRevisionNotifier, int>(
  () => StoreRevisionNotifier((store) => store.settingsRevision),
);

/// 站源准入（开关 + 已安装扩展）修订号。
final accessRevisionProvider = NotifierProvider<StoreRevisionNotifier, int>(
  () => StoreRevisionNotifier((store) => store.accessRevision),
);

/// 主题模式：根组件只 watch 此 provider，其余领域变更不再触发全树重建。
final themeModeProvider = Provider<String>((ref) {
  ref.watch(settingsRevisionProvider);
  return ref.watch(storeProvider).themeMode;
});

/// 当前可用站源列表；只在站源开关/扩展安装变化时重建。
final availableSourcesProvider = Provider<List<SourceSite>>((ref) {
  ref.watch(accessRevisionProvider);
  return ref.watch(storeProvider).sources;
});

/// 收藏列表；只在库数据变化时重建。
final favoritesProvider = Provider<List<Drama>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(storeProvider).favorites;
});

/// 追剧状态快照；只在库数据变化时重建。
final followStatesProvider = Provider<Map<String, FollowCheck>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(storeProvider).followChecks;
});

/// Bootstrap 状态：核心初始化进度由 AppBootstrap 写入、路由 `/` 消费。
final appReadyProvider = StateProvider<bool>((ref) => false);
final bootstrapErrorProvider = StateProvider<String?>((ref) => null);
final bootstrapRetryProvider = Provider<VoidCallback>((ref) => () {});
