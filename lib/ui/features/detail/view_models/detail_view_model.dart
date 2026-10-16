import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../domain/models/episode.dart';

/// 详情 + 选集。
///
/// W2 起真源一次请求拿全（`detail` op）；未找到时仓库抛
/// `StateError('未找到剧集')`，视图在 error 分支渲染空态。
/// key 带源：同 id 跨源是不同剧，缓存与仲裁互不干扰。
final detailProvider =
    FutureProvider.family<DramaDetail, ({String id, String source})>(
      (ref, key) => ref
          .watch(catalogRepositoryForSourceProvider(key.source))
          .detail(key.id),
    );

/// 选集分组（Rust `episodeGroups` op）。
///
/// 与 [detailProvider] 分开：分组是**渲染口径**（每组几集、起止、标签），
/// 由 Rust 给，播放页与详情页共用同一份结果；它复用详情缓存，命中即零网络。
final episodeGroupsProvider =
    FutureProvider.family<EpisodeGroups, ({String id, String source})>(
      (ref, key) => ref
          .watch(catalogRepositoryForSourceProvider(key.source))
          .episodeGroups(seriesId: key.id),
    );
