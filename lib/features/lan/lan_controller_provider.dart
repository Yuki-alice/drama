import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:duanju_app/core/providers.dart';
import 'package:duanju_app/features/lan/lan_controller.dart';

/// 全应用唯一的设备互联控制器；生命周期随容器销毁。
final lanControllerProvider = Provider<LanController>((ref) {
  final link = LanController(
    ref.watch(repositoryProvider),
    ref.watch(storeProvider),
    kind: Platform.isWindows || Platform.isMacOS || Platform.isLinux
        ? 'computer'
        : 'phone',
  );
  ref.onDispose(link.dispose);
  return link;
});
