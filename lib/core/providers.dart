import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'core_bridge.dart';
import 'local_store.dart';

/// FFI 仓库桥：应用启动时由 bootstrap 覆写注入实际实例。
final repositoryProvider = Provider<AppRepository>((ref) {
  throw UnimplementedError('由 AppBootstrap override');
});

/// 单用户本地存储桥（ChangeNotifier 桥接，业务代码可渐进迁移 watch）。
final storeProvider = ChangeNotifierProvider<LocalStore>((ref) {
  throw UnimplementedError('由 AppBootstrap override');
});

/// 主题模式：根组件只 watch 此 provider，其余 store 变更不再触发全树重建。
final themeModeProvider = Provider<String>((ref) {
  final store = ref.watch(storeProvider);
  return store.themeMode;
});

/// Bootstrap 状态：核心初始化进度由 AppBootstrap 写入、路由 `/` 消费。
final appReadyProvider = StateProvider<bool>((ref) => false);
final bootstrapErrorProvider = StateProvider<String?>((ref) => null);
final bootstrapRetryProvider = Provider<VoidCallback>((ref) => () {});
