import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 分层依赖方向（下 → 上）：
/// core ← data ← widgets/features ← app
const _rules = <String, List<String>>{
  'lib/core': [
    'package:duanju_app/features/',
    'package:duanju_app/widgets/',
    'package:duanju_app/data/',
    'package:duanju_app/app/',
  ],
  'lib/data': [
    'package:duanju_app/features/',
    'package:duanju_app/widgets/',
    'package:duanju_app/app/',
  ],
  'lib/widgets': ['package:duanju_app/features/', 'package:duanju_app/data/'],
  'lib/features': ['package:duanju_app/app/main.dart'],
};

void main() {
  for (final rule in _rules.entries) {
    test('${rule.key} 不得依赖上层', () {
      final violations = <String>[];
      for (final entity in Directory(rule.key).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          final line = lines[index].trimLeft();
          if (!line.startsWith('import ')) continue;
          for (final forbidden in rule.value) {
            if (line.contains(forbidden)) {
              violations.add('${entity.path}:${index + 1} → $line');
            }
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason: '${rule.key} 出现了反向依赖：\n${violations.join('\n')}',
      );
    });
  }
}
