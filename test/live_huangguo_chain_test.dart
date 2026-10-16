import 'dart:convert';
import 'dart:io';

import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 联网端到端：黄果 AI（`huangguoai`）search → detail → play。
///
/// 判定“规则化源链路是否跑通”：搜索有条目、详情有选集、取流拿到可播地址。
/// 只断言结构与字段存在，不打印任何站点内容。默认跳过（需联网）。
void main() {
  test('LIVE: huangguoai search → detail → play', () async {
    final core = await RustCore.spawn();
    try {
      await core.call('init', params: {'dataDir': '/tmp/drama-hg-chain'});

      final search = await core.call(
        'search',
        source: 'huangguoai',
        params: {'keyword': '替嫁'},
      );
      expect(search['ok'], true);
      final items = ((search['data'] as Map)['items'] as List);
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
      final proxy = ((play['data'] as Map)['proxyUrl'] as String);
      expect(proxy.contains('.m3u8'), true);

      // 可播性：播放列表可取（含 EXT-X-KEY 加密标记）且密钥可取 16 字节。
      // 网关不中转 HLS（见契约源表），播放器直开此地址，由 media_kit 原生解密。
      final playlist = await _getText(proxy);
      expect(playlist.contains('#EXTM3U'), true);
      final keyMatch = RegExp(r'URI="([^"]+)"').firstMatch(playlist);
      expect(keyMatch, isNotNull);
      final keyBytes = await _getBytes(keyMatch!.group(1)!);
      expect(keyBytes.length, 16);
    } finally {
      core.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('LIVE: huangguoai catalog → recommend → ranking', () async {
    final core = await RustCore.spawn();
    try {
      await core.call('init', params: {'dataDir': '/tmp/drama-hg-browse'});

      final catalog = await core.call(
        'catalog',
        source: 'huangguoai',
        params: {'category': 'ai-manju', 'page': 0},
      );
      expect(catalog['ok'], true);
      final citems = (((catalog['data'] as Map))['items'] as List);
      expect(citems.isNotEmpty, true);
      expect(((catalog['data'] as Map))['page'], 0);
      // ignore: avoid_print
      print('HUANGUO_CATALOG=${citems.length}');

      final badcat = await core.call(
        'catalog',
        source: 'huangguoai',
        params: {'category': 'nope', 'page': 0},
      );
      expect((badcat['error'] as Map)['code'], 'NOT_FOUND');

      final rec = await core.call('recommend', source: 'huangguoai');
      expect(rec['ok'], true);
      expect((((rec['data'] as Map))['items'] as List).isNotEmpty, true);

      final rank = await core.call(
        'ranking',
        source: 'huangguoai',
        params: {'board': 'hot'},
      );
      expect(rank['ok'], true);
      expect((((rank['data'] as Map))['items'] as List).isNotEmpty, true);
    } finally {
      core.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 180)));
}

/// 简单 GET 取文本（LIVE 探针用；失败即抛，测试标红）。
Future<String> _getText(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw StateError('GET $url → ${resp.statusCode}');
    }
    final buf = StringBuffer();
    await for (final chunk in resp.transform(utf8.decoder)) {
      buf.write(chunk);
      if (buf.length > 512 * 1024) break;
    }
    return buf.toString();
  } finally {
    client.close();
  }
}

/// 简单 GET 取字节（LIVE 探针用）。
Future<List<int>> _getBytes(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw StateError('GET $url → ${resp.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
      if (bytes.length > 64 * 1024) break;
    }
    return bytes;
  } finally {
    client.close();
  }
}
