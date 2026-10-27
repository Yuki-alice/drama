import 'dart:convert';

import 'models.dart';

/// 站源可用性策略：与持久化分离，便于在 ViewModel/服务中复用与测试。
class SourceAccessPolicy {
  const SourceAccessPolicy(this._enabled);

  final Map<String, bool> _enabled;

  static const empty = SourceAccessPolicy({});

  factory SourceAccessPolicy.decode(String? raw) {
    if (raw == null) return empty;
    try {
      return SourceAccessPolicy(Map<String, bool>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return empty;
    }
  }

  bool enabled(String source) =>
      _enabled[source] ?? !SourceSite.isRestricted(source);

  bool allows(String source) =>
      SourceSite.isAvailable(source) && enabled(source);

  List<SourceSite> get available =>
      SourceSite.values.where((site) => allows(site.id)).toList();

  SourceAccessPolicy withSource(String source, bool value) =>
      SourceAccessPolicy({..._enabled, source: value});

  Map<String, bool> get raw => Map.unmodifiable(_enabled);

  String encode() => jsonEncode(_enabled);
}
