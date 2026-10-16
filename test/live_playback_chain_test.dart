import 'dart:io';

import 'package:drama_app/data/repositories/playback_repository.dart';
import 'package:drama_app/data/repositories/source_catalog_repository.dart';
import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 联网端到端：Dart → FFI → Rust 取流 → 本机代理 → 真实媒体字节。
///
/// 这是「播放链路是否跑通」的判定用例：播放器要打开的 `proxyUrl` 必须真的
/// 吐出可播放的 MP4（ftyp/moov）。默认跳过（需联网）。
void main() {
  test('LIVE: play → proxy serves real MP4 bytes', () async {
    final core = await RustCore.spawn();
    await core.call('init', params: {'dataDir': '/tmp/drama-chain-probe'});
    final repo = SourceCatalogRepository(core);
    final page = await repo.catalog(categoryId: 'real-drama', page: 0);
    final id = page.items.first.id;

    final plan = await PlaybackRepository(
      SeriesCoreShim(core),
    ).resolve(seriesId: id, episode: 1);
    // ignore: avoid_print
    print('SERIES=$id');
    // ignore: avoid_print
    print('PROXY=${plan.proxyUrl}');
    // ignore: avoid_print
    print('ENCRYPTED=${plan.encrypted} QUALITY=${plan.quality}');

    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(plan.proxyUrl));
    req.headers.set('Range', 'bytes=0-131071');
    final resp = await req.close();
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
      if (bytes.length > 131072) break;
    }
    client.close();
    core.dispose();

    // ignore: avoid_print
    print('STATUS=${resp.statusCode} BYTES=${bytes.length}');
    expect(resp.statusCode, anyOf(200, 206));
    expect(bytes.length, greaterThan(10000), reason: '代理没吐出有效媒体');

    // MP4 顶层 box 校验：必须能找到 ftyp 与 moov。
    bool hasTag(String tag) {
      final t = tag.codeUnits;
      for (var i = 0; i + 4 <= bytes.length; i++) {
        if (bytes[i] == t[0] &&
            bytes[i + 1] == t[1] &&
            bytes[i + 2] == t[2] &&
            bytes[i + 3] == t[3]) {
          return true;
        }
      }
      return false;
    }

    expect(hasTag('ftyp'), isTrue, reason: '不是 MP4（缺 ftyp）');
    expect(hasTag('moov'), isTrue, reason: 'MP4 缺 moov，播放器无法起播');
  }, timeout: const Timeout(Duration(seconds: 180)));
}
