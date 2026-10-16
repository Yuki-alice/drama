import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rust 核心最小加载冒烟：native asset 可加载 + 信封往返正常。
///
/// 只用无网络 op（`ping` / `version`），离线可跑；网络 op 的覆盖由
/// Rust 侧单测与 `LIVE` 诊断测试负责。
void main() {
  test('Rust 核心 ping/version 冒烟', () async {
    final core = await RustCore.spawn();
    try {
      expect(await core.ping(), 'pong');

      final envelope = await core.call('version');
      expect(envelope['ok'], true);
      final data = envelope['data']! as Map<String, Object?>;
      expect((data['core'] as String?)?.isNotEmpty, true);
      final sources = data['sources']! as List<Object?>;
      expect(
        sources.any(
          (s) => (s as Map<String, Object?>)['id'] == 'hongguo',
        ),
        true,
      );
    } finally {
      core.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
