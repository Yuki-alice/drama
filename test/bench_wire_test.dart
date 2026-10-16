import 'dart:convert';

import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 当前 wire payload 实测：列表 op 出参体积 + 字段占比。
///
/// 目的：给「出参瘦身」定靶。成本模型 ≈ 119µs 固定 + 34.4µs/KB，
/// 所以每砍 1KB ≈ 省 34µs。
void main() {
  test('LIVE: 列表 op wire payload 体积与字段占比', () async {
    final core = await RustCore.spawn();
    await core.call('init', params: {'dataDir': '/tmp/drama-wire'});

    // 直接拿原始信封，量真实出参（不经 Dart 模型）
    final env = await core.call(
      'catalog',
      source: 'hongguo',
      params: <String, Object?>{'category': 'real-drama', 'page': 0},
    );
    final data = env['data']! as Map<String, Object?>;
    final items = data['items']! as List<Object?>;
    final raw = jsonEncode(env);
    // ignore: avoid_print
    print('catalog 信封总字节=${raw.length} 条目=${items.length}');
    // ignore: avoid_print
    print('data 字节=${jsonEncode(data).length}');

    final fields = <String, int>{};
    var total = 0;
    for (final it in items) {
      final m = it! as Map<String, Object?>;
      for (final e in m.entries) {
        final n = jsonEncode(e.value).length + e.key.length + 4;
        fields[e.key] = (fields[e.key] ?? 0) + n;
        total += n;
      }
    }
    final sorted = fields.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      // ignore: avoid_print
      print('  ${e.key.padRight(20)} ${e.value.toString().padLeft(6)}B '
          '${(e.value * 100 / total).toStringAsFixed(1).padLeft(5)}%');
    }
    // 详情页独占字段
    const detailOnly = ['summary', 'tags', 'vip'];
    final cut = detailOnly.fold<int>(0, (s, k) => s + (fields[k] ?? 0));
    // ignore: avoid_print
    print('详情独占字段合计=${cut}B '
        '(${(cut * 100 / total).toStringAsFixed(0)}% of items)');
    // ignore: avoid_print
    print('砍掉后 items 体积 ≈ ${total - cut}B '
        '→ 边际省 ≈ ${((cut / 1024) * 34.4).toStringAsFixed(0)}µs');

    core.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));
}
