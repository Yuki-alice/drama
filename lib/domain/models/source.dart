import 'package:flutter/foundation.dart';

/// 源能力位（Rust `version.sources[].caps` 解包；字段缺省按不支持处理，
/// 与契约「未声明即隐藏」的口径一致）。
@immutable
class SourceCaps {
  const SourceCaps({
    this.catalog = false,
    this.search = false,
    this.suggest = false,
    this.recommend = false,
    this.ranking = false,
    this.detail = false,
    this.playback = false,
  });

  final bool catalog;
  final bool search;
  final bool suggest;
  final bool recommend;
  final bool ranking;
  final bool detail;
  final bool playback;

  factory SourceCaps.fromJson(Map<String, Object?> json) => SourceCaps(
    catalog: json['catalog'] == true,
    search: json['search'] == true,
    suggest: json['suggest'] == true,
    recommend: json['recommend'] == true,
    ranking: json['ranking'] == true,
    detail: json['detail'] == true,
    playback: json['playback'] == true,
  );
}

/// 内容源（主源内建 + 规则源动态注册，均经 `version` 下发）。
@immutable
class SourceInfo {
  const SourceInfo({
    required this.id,
    required this.caps,
    this.name = '',
    this.kind = 'builtin',
  });

  /// 源 id（与 Rust 信封 `source`、缓存 key 首段同一口径）。
  final String id;

  final SourceCaps caps;

  /// 展示名（Rust `sources[].name`；缺省回退 id）。
  final String name;

  /// `builtin` / `rule`。
  final String kind;

  /// 是否主源（默认源兜底；规则源缺失时 UI 仍可用）。
  bool get isDefault => id == 'hongguo';

  /// 是否规则安装的源。
  bool get isRule => kind == 'rule';

  /// 展示名：Rust 下发的 name 优先，主源兜底「红果」。
  String get displayName => name.isNotEmpty
      ? name
      : (isDefault ? '红果' : id);

  factory SourceInfo.fromJson(Map<String, Object?> json) {
    final caps = json['caps'];
    return SourceInfo(
      id: json['id'] as String? ?? '',
      caps: caps is Map
          ? SourceCaps.fromJson(Map<String, Object?>.from(caps))
          : const SourceCaps(),
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? 'builtin',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
