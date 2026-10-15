import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/catalog_repository.dart';

/// 详情 + 选集（PRD F-04）。
///
/// W2 起真源一次请求拿全（`detail` op）；未找到时仓库抛
/// `StateError('未找到剧集')`，视图在 error 分支渲染空态。
final detailProvider = FutureProvider.family<DramaDetail, String>(
  (ref, id) => ref.watch(catalogRepositoryProvider).detail(id),
);
