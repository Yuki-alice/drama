
import 'package:drama_app/data/services/rust_core.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 联网端到端：黄果 AI（`huangguoai`，现为规则源）catalog → detail → play。
///
/// 规则源的 caps 由规则包声明：黄果 AI 包只声明 catalog/detail/playback
/// （源站没有稳定的 recommend/ranking/search 接口），所以本测试不再对
/// search/recommend/ranking 断言——能力协商按「未声明即隐藏」的口径走。
///
/// 判定“规则化源链路是否跑通”：搜索有条目、详情有选集、取流拿到可播地址。
/// 只断言结构与字段存在，不打印任何站点内容。默认跳过（需联网）。
void main() {
  test('LIVE: huangguoai catalog → detail → play', () async {
    final core = await RustCore.spawn();
    try {
      final dataDir = '/tmp/drama-hg-chain';
      await core.call('init', params: {'dataDir': dataDir});

      // 规则源必须先安装（黄果AI 现在是规则包，不在编译期源表里）。
      // 仓库根 rust/sources/ 是规则包的唯一真源；找不到时提示先跑安装。
      var manifestFile = File('../rust/sources/huangguoai.yaml');
      if (!manifestFile.existsSync()) {
        manifestFile = File('rust/sources/huangguoai.yaml');
      }
      expect(
        manifestFile.existsSync(),
        true,
        reason: '找不到规则包 rust/sources/huangguoai.yaml（cwd=${Directory.current.path}）',
      );
      await core.call('sourceInstall', params: {
        'manifest': manifestFile.readAsStringSync(),
        'origin': 'local',
      });

      final catalog = await core.call(
        'catalog',
        source: 'huangguoai',
        params: {'page': 0},
      );
      expect(catalog['ok'], true);
      final items = ((catalog['data'] as Map)['items'] as List);
      expect(items.isNotEmpty, true);
      final first = items.first as Map;
      expect((first['id'] as String).isNotEmpty, true);
      expect((first['title'] as String).isNotEmpty, true);

      final detail = await core.call(
        'detail',
        source: 'huangguoai',
        params: {'id': first['id']},
      );
      expect(detail['ok'], true);
      final episodes = (((detail['data'] as Map))['episodes'] as List);
      expect(episodes.isNotEmpty, true);
      // ignore: avoid_print
      print('HUANGUO_EPISODES=${episodes.length}');

      final play = await core.call(
        'play',
        source: 'huangguoai',
        params: {'id': first['id'], 'episode': 1},
      );
      expect(play['ok'], true);
      final url = ((play['data'] as Map)['url'] as String);
      expect(url.contains('.m3u8'), true);
      // ignore: avoid_print
      print('HUANGUO_PLAY_OK');
    } finally {
      core.dispose();
    }
  });

}
