import 'package:flutter/foundation.dart';

/// 首页分类（「分类横滑切类」）。
@immutable
class DramaCategory {
  const DramaCategory({required this.id, required this.name});

  final String id;

  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DramaCategory &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
