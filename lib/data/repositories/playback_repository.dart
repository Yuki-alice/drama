import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/core/playback/playback_settings.dart';
import '../services/rust_core.dart';
import 'catalog_providers.dart';

/// 可切换的清晰度档位。
///
/// 由 Rust 产出（去重降序 + 标签口径 4K/2K/1080P…）：档位命名是业务口径，
/// 不该在渲染层另算一套。
@immutable
class QualityOption {
  const QualityOption({required this.height, required this.label});

  /// 清晰度高度（1080/720/360…）。
  final int height;

  /// 展示标签（`4K` / `2K` / `1080P`）。
  final String label;
}

/// 播放计划：Rust `play` op 的解包结果。
///
/// 播放器只打开 [proxyUrl]（本机代理，Referer 鉴权与 CENC 解密已 baked 进去），
/// 不直接碰源站。`url` 为源站直链，仅供诊断；`variants` 为同集候选线路。
@immutable
class PlaybackPlan {
  const PlaybackPlan({
    required this.proxyUrl,
    required this.url,
    required this.vid,
    required this.encrypted,
    required this.quality,
    required this.duration,
    this.qualities = const <int>[],
    this.variants = const <String>[],
    this.qualityOptions = const <QualityOption>[],
    this.offline = false,
  });

  final String proxyUrl;
  final String url;
  final String vid;
  final bool encrypted;
  final int quality;
  final Duration duration;
  final List<int> qualities;
  final List<String> variants;

  /// 可切换的档位（Rust `play` / `playQuality` 随响应下发）。
  final List<QualityOption> qualityOptions;

  /// 当前档位的展示标签。
  ///
  /// 优先用 Rust 给的档位表（口径一致）；没有档位表时回落到 `{高度}P`，
  /// `height == 0`（源未上报清晰度）则显示「默认」。
  String get qualityText {
    for (final option in qualityOptions) {
      if (option.height == quality) return option.label;
    }
    return quality > 0 ? '${quality}P' : '默认';
  }

  /// 是否来自本地已完成的分集（`playLocal`）。
  ///
  /// 播放器逻辑不变，仅用于 UI 标注（例如标题显示「离线」）。
  final bool offline;

  factory PlaybackPlan.fromJson(Map<String, Object?> json) {
    final variants = <String>[];
    final qualities = <int>[];
    final rawVariants = json['variants'];
    if (rawVariants is List) {
      for (final item in rawVariants) {
        if (item is Map) {
          final url = item['url'] as String?;
          final quality = (item['quality'] as num?)?.toInt() ?? 0;
          if (url != null && url.isNotEmpty) {
            variants.add(url);
            qualities.add(quality);
          }
        }
      }
    }
    final seconds = (json['durationSecs'] as num?)?.toDouble() ?? 0;
    return PlaybackPlan(
      proxyUrl: json['proxyUrl'] as String? ?? '',
      url: json['url'] as String? ?? '',
      vid: json['vid'] as String? ?? '',
      encrypted: json['encrypted'] == true,
      quality: (json['quality'] as num?)?.toInt() ?? 0,
      duration: Duration(milliseconds: (seconds * 1000).round()),
      qualities: qualities,
      variants: variants,
      qualityOptions: _qualityOptions(json['qualityOptions']),
      offline: json['offline'] == true,
    );
  }

  static List<QualityOption> _qualityOptions(Object? raw) {
    if (raw is! List) return const <QualityOption>[];
    return <QualityOption>[
      for (final item in raw)
        if (item is Map)
          QualityOption(
            height: (item['height'] as num?)?.toInt() ?? 0,
            label: item['label'] as String? ?? '',
          ),
    ];
  }
}

/// 取流仓库：`play{id, episode, vid?}` → [PlaybackPlan]。
class PlaybackRepository {
  const PlaybackRepository(this._core);

  final CoreCaller _core;

  /// 取（剧，集）的播放计划：**离线优先**。
  ///
  /// ① 先问 Rust `playLocal`：本集已下载完成就直接出本地文件（零网络，
  ///   也不用再跑一遍签名/疑降级）；
  /// ② 本地没有（NOT_FOUND / BAD_REQUEST / 任何异常）才回落到在线 `play`。
  ///
  /// 本地文件一旦存在就赢，**不受清晰度偏好影响**——下载它就是为了离线看，
  /// 再按清晰度回落到联网既慢又违背用户预期。
  Future<PlaybackPlan> resolve({
    required String seriesId,
    required int episode,
    String? vid,
    int quality = 0,
  }) async {
    final offline = await localPlanOrNull(
      seriesId: seriesId,
      episode: episode,
    );
    if (offline != null) return offline;
    final envelope = await _core.call(
      'play',
      source: 'hongguo',
      params: <String, Object?>{
        'id': seriesId,
        'episode': episode,
        if (vid != null && vid.isNotEmpty) 'vid': vid,
        if (quality > 0) 'quality': quality,
      },
    );
    if (envelope['ok'] == true) {
      final data = envelope['data'];
      if (data is Map) {
        final plan = PlaybackPlan.fromJson(Map<String, Object?>.from(data));
        if (plan.proxyUrl.isEmpty) {
          throw const RustCoreException('PARSE', 'play 缺少 proxyUrl', false);
        }
        return plan;
      }
    }
    throw RustCoreException.fromEnvelope(envelope);
  }

  /// 探测本地已完成文件；没有（或探测失败）返回 `null`，不抛异常。
  Future<PlaybackPlan?> localPlanOrNull({
    required String seriesId,
    required int episode,
  }) async {
    try {
      final envelope = await _core.call(
        'playLocal',
        params: <String, Object?>{'id': seriesId, 'episode': episode},
      );
      if (envelope['ok'] != true) return null;
      final data = envelope['data'];
      if (data is! Map) return null;
      final plan = PlaybackPlan.fromJson(Map<String, Object?>.from(data));
      return plan.proxyUrl.isEmpty ? null : plan;
    } catch (_) {
      // 离线探测是**加速手段**：任何失败都安静地回落到在线取流，
      // 绝不能因为本地查不到而让用户看不了在线版。
      return null;
    }
  }

  /// 换档：同集换清晰度，返回新的播放计划。
  ///
  /// 走 Rust `playQuality`：**复用上一次解析出的候选线路**重挑目标档并重新注册
  /// 代理会话，零签名、零网络（直接用 `play` 换 `quality` 会因缓存键不同整条链
  /// 重跑，用户点一下要等一轮网络）。旁路缓存没有这一集时才回落完整解析。
  ///
  /// 注意：换档**不改**全局清晰度偏好——那是设置页的事。
  Future<PlaybackPlan> switchQuality({
    required String seriesId,
    required String vid,
    required int quality,
  }) async {
    final envelope = await _core.call(
      'playQuality',
      source: 'hongguo',
      params: <String, Object?>{
        'id': seriesId,
        'vid': vid,
        if (quality > 0) 'quality': quality,
      },
    );
    if (envelope['ok'] == true) {
      final data = envelope['data'];
      if (data is Map) {
        final plan = PlaybackPlan.fromJson(Map<String, Object?>.from(data));
        if (plan.proxyUrl.isEmpty) {
          throw const RustCoreException('PARSE', 'playQuality 缺少 proxyUrl', false);
        }
        return plan;
      }
    }
    throw RustCoreException.fromEnvelope(envelope);
  }

  /// 预取下集（可选能力，失败静默忽略；`quality` 语义同 [resolve]）。
  Future<String?> preload({
    required String seriesId,
    required int episode,
    int quality = 0,
  }) async {
    try {
      // 下一集已在本地：预取立即返回本地代理地址，
      // 省掉一次「注定用不上」的在线签名。
      final offline = await localPlanOrNull(
        seriesId: seriesId,
        episode: episode,
      );
      if (offline != null) return offline.proxyUrl;
      final envelope = await _core.call(
        'preload',
        source: 'hongguo',
        params: <String, Object?>{
          'id': seriesId,
          'episode': episode,
          if (quality > 0) 'quality': quality,
        },
        timeout: const Duration(seconds: 20),
      );
      if (envelope['ok'] == true) {
        final data = envelope['data'];
        if (data is Map<String, Object?>) {
          final url = data['proxyUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        } else if (data is Map) {
          final url = Map<String, Object?>.from(data)['proxyUrl'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      }
    } catch (_) {
      // 预取失败不打扰播放。
    }
    return null;
  }
}

/// 核心调用面（便于单测替换；生产实现 [SeriesCoreShim] 透传给 [RustCore]）。
abstract interface class CoreCaller {
  Future<Map<String, Object?>> call(
    String op, {
    String? source,
    Map<String, Object?>? params,
    Duration? timeout,
  });
}

/// 对 [RustCore] 的最小调用面（生产实现：直接透传）。
class SeriesCoreShim implements CoreCaller {
  const SeriesCoreShim(this._core);

  final RustCore _core;

  @override
  Future<Map<String, Object?>> call(
    String op, {
    String? source,
    Map<String, Object?>? params,
    Duration? timeout,
  }) => _core.call(op, source: source, params: params, timeout: timeout);
}

/// 取流 provider：按（剧，集）解析；切集自动重解。
/// Rust 侧无核心时抛 [StateError]（调用方走错误态，不静默回退假地址）。
///
/// **清晰度来自播放偏好**（`playbackSettingsProvider.qualityParam`）：
/// watch 它意味着用户在设置里改清晰度后，正在播放的集也会重新解析——
/// 这是想要的行为（改设置立刻生效），代价只是重新取一次流。
final playPlanProvider =
    FutureProvider.family<PlaybackPlan, ({String id, int episode})>((
      ref,
      key,
    ) async {
      final holder = ref.watch(rustCoreProvider);
      if (holder == null) {
        throw StateError('Rust 核心不可用，无法解析播放');
      }
      final quality = ref.watch(
        playbackSettingsProvider.select((s) => s.qualityParam),
      );
      final repository = PlaybackRepository(SeriesCoreShim(holder.core));
      return repository.resolve(
        seriesId: key.id,
        episode: key.episode,
        quality: quality,
      );
    });

/// 预取下一集（可选能力；失败静默忽略）。
///
/// 提前把 moov 解析与 CDN 首字节做完，用户点「下一集」时打开即播。
/// 只在有下一集时才发起。
final preloadNextProvider =
    FutureProvider.family<String?, ({String id, int episode, int total})>((
      ref,
      key,
    ) async {
      if (key.episode >= key.total) return null;
      final holder = ref.watch(rustCoreProvider);
      if (holder == null) return null;
      final quality = ref.watch(
        playbackSettingsProvider.select((s) => s.qualityParam),
      );
      final repository = PlaybackRepository(SeriesCoreShim(holder.core));
      return repository.preload(
        seriesId: key.id,
        episode: key.episode + 1,
        quality: quality,
      );
    });
