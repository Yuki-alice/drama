import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../domain/models/episode.dart';

/// 详情 + 选集。
///
/// W2 起真源一次请求拿全（`detail` op）；未找到时仓库抛
/// `StateError('未找到剧集')`，视图在 error 分支渲染空态。
final detailProvider = FutureProvider.family<DramaDetail, String>(
  (ref, id) => ref.watch(catalogRepositoryProvider).detail(id),
);

/// 选集分组（Rust `episodeGroups` op）。
///
/// 与 [detailProvider] 分开：分组是**渲染口径**（每组几集、起止、标签），
/// 由 Rust 给，播放页与详情页共用同一份结果；它复用详情缓存，命中即零网络。
final episodeGroupsProvider = FutureProvider.family<EpisodeGroups, String>(
  (ref, id) => ref
      .watch(catalogRepositoryProvider)
      .episodeGroups(seriesId: id),
);
