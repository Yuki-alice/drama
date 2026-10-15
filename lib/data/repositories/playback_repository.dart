import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/core/playback/playback_settings.dart';
import '../services/rust_core.dart';
import 'catalog_providers.dart';

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
  });

  final String proxyUrl;
  final String url;
  final String vid;
  final bool encrypted;
  final int quality;
  final Duration duration;
  final List<int> qualities;
  final List<String> variants;

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
    );
  }
}

/// 取流仓库：`play{id, episode, vid?}` → [PlaybackPlan]。
class PlaybackRepository {
  const PlaybackRepository(this._core);

  final SeriesCoreShim _core;

  Future<PlaybackPlan> resolve({
    required String seriesId,
    required int episode,
    String? vid,
    int quality = 0,
  }) async {
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

  /// 预取下集（可选能力，失败静默忽略；`quality` 语义同 [resolve]）。
  Future<String?> preload({
    required String seriesId,
    required int episode,
    int quality = 0,
  }) async {
    try {
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

/// 对 [RustCore] 的最小调用面（便于单测替换；生产实现即透传）。
class SeriesCoreShim {
  const SeriesCoreShim(this._core);

  final RustCore _core;

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
