import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:duanju_app/core/providers.dart';
import 'package:duanju_app/data/media/media_library.dart';

/// 全应用唯一的媒体库实例；生命周期随容器销毁。
final mediaLibraryProvider = Provider<MediaLibrary>((ref) {
  final library = MediaLibrary.attached(
    ref.watch(repositoryProvider),
    ref.watch(storeProvider),
  );
  ref.onDispose(library.dispose);
  return library;
});
