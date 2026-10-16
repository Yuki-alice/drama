import 'package:drama_app/data/repositories/playback_repository.dart';
import 'package:drama_app/data/repositories/source_catalog_repository.dart';
import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 播放链路**真机验证**（需联网）。
///
/// 为什么必须放在 `integration_test/`：`flutter test` 的宿主进程没有
/// `Mpv.framework`，`Player()` 构造会直接抛「Cannot find Mpv.framework/Mpv」。
/// 只有跑在真实 app bundle 里才能验证真解码。
///
/// 跑法：`flutter test integration_test/playback_test.dart -d macos`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('取流 → 本机代理 → media_kit 真解码并推进播放', (tester) async {
    MediaKit.ensureInitialized();

    final core = await RustCore.spawn();
    await core.call('init', params: {'dataDir': '/tmp/drama-it-probe'});
    final repo = SourceCatalogRepository(core);
    final page = await repo.catalog(categoryId: 'real-drama', page: 0);
    expect(page.items, isNotEmpty, reason: '目录为空，无法继续');
    final id = page.items.first.id;

    final plan = await PlaybackRepository(
      SeriesCoreShim(core),
    ).resolve(seriesId: id, episode: 1);
    // ignore: avoid_print
    print('IT proxy=${plan.proxyUrl} encrypted=${plan.encrypted} q=${plan.quality}');
    expect(plan.proxyUrl, startsWith('http://127.0.0.1:'));

    final player = Player();
    // 与真实播放页一致：挂上 VideoController（无它则不走视频输出，
    // videoParams 不会回填，也无法验证画面真的在解）。
    final controller = VideoController(player);
    addTearDown(() async {
      await player.dispose();
      core.dispose();
    });

    // 把 Video 挂到真实 widget 树上（离屏渲染需要它参与管线）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 640,
              child: Video(controller: controller),
            ),
          ),
        ),
      ),
    );

    await player.open(Media(plan.proxyUrl), play: true);

    var width = 0;
    var duration = Duration.zero;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      duration = player.state.duration;
      width = player.state.width ?? 0;
      if (duration > Duration.zero && width > 0) break;
    }
    // ignore: avoid_print
    print('IT decoded ${width}x${player.state.height} duration=$duration');
    expect(duration, greaterThan(Duration.zero), reason: '未解析出时长');
    expect(width, greaterThan(0), reason: '未解析出视频宽度（只解出音频轨？）');

    // 位置推进 = 真的在播放。
    final p0 = player.state.position;
    final end = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final p1 = player.state.position;
    // ignore: avoid_print
    print('IT position $p0 -> $p1 playing=${player.state.playing} '
        'size=${player.state.width}x${player.state.height}');
    expect(p1, greaterThan(p0), reason: '播放位置未推进，视频没有真正播放');
  }, timeout: const Timeout(Duration(seconds: 240)));
}
