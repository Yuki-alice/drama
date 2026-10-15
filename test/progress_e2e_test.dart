import 'dart:io';

import 'package:drama_app/data/repositories/playback_repository.dart';
import 'package:drama_app/data/repositories/progress_repository.dart';
import 'package:drama_app/data/services/rust_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 追剧 / 观看进度的**真实 FFI 端到端**测试（不需要网络）。
///
/// 与 `progress_repository_test.dart` 的纯函数单测互补：这里真正 spawn 常驻
/// worker 池、经过 C ABI 打到 Rust `store` 模块，再读回验证。
///
/// 之所以可行：native assets 在 `flutter test` 下同样会被构建并加载
/// （`hook/build.dart` 产出 `libdrama_core.dylib`），故宿主平台可直接跑。
void main() {
  late Directory tempDir;
  late RustCore core;
  late ProgressRepository repo;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('drama_progress_e2e_');
    core = await RustCore.spawn();
    // 把 Rust 的 dataDir 指到临时目录：进度文件写在那里，不碰用户真实数据。
    await core.call(
      'init',
      params: <String, Object?>{'dataDir': tempDir.path},
    );
    repo = ProgressRepository(SeriesCoreShim(core));
  });

  tearDownAll(() async {
    core.dispose();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    // 每个用例从干净状态开始（清空追剧与历史）。
    for (final entry in await repo.follows()) {
      await repo.unfollow(entry.id);
    }
    await repo.clearHistory();
  });

  test('追剧 → 列表 → 取消追剧 全链路', () async {
    expect(await repo.follows(), isEmpty);

    await repo.follow(id: 'd1', title: '某剧', totalEpisode: 80);
    final follows = await repo.follows();
    expect(follows, hasLength(1));
    expect(follows.single.id, 'd1');
    expect(follows.single.title, '某剧');
    expect(follows.single.totalEpisode, 80);

    await repo.unfollow('d1');
    expect(await repo.follows(), isEmpty);
  });

  test('进度上报写入历史，resumeFor 读回同一集与位置', () async {
    await repo.follow(id: 'd1', title: '某剧', totalEpisode: 80);
    await repo.reportProgress(
      id: 'd1',
      episode: 7,
      position: const Duration(seconds: 42),
      duration: const Duration(seconds: 90),
    );

    final resume = await repo.resumeFor('d1');
    expect(resume, isNotNull);
    expect(resume!.episode, 7);
    expect(resume.position, const Duration(seconds: 42));

    // 上报同时刷新追剧条目的观看位置（追剧页据此显示进度）。
    final follows = await repo.follows();
    expect(follows.single.episode, 7);
    expect(follows.single.position, const Duration(seconds: 42));
  });

  test('未看过的剧 resumeFor 返回 null（不臆造续播点）', () async {
    expect(await repo.resumeFor('never-watched'), isNull);
  });

  test('clearHistory 清历史但保留追剧', () async {
    await repo.follow(id: 'd1', title: '某剧', totalEpisode: 80);
    await repo.reportProgress(
      id: 'd1',
      episode: 3,
      position: const Duration(seconds: 10),
      duration: const Duration(seconds: 60),
    );
    expect(await repo.history(), hasLength(1));

    await repo.clearHistory();
    expect(await repo.history(), isEmpty);
    // 追剧表不受 clearHistory 影响。
    expect(await repo.follows(), hasLength(1));
  });

  test('重复上报同一部剧只保留一条历史（最近在前）', () async {
    await repo.follow(id: 'd1', title: '某剧', totalEpisode: 80);
    await repo.reportProgress(
      id: 'd1',
      episode: 1,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 60),
    );
    await repo.reportProgress(
      id: 'd1',
      episode: 2,
      position: const Duration(seconds: 8),
      duration: const Duration(seconds: 60),
    );
    final history = await repo.history();
    expect(history, hasLength(1));
    expect(history.single.episode, 2);
  });

  test('进度落盘到 progress.json（重启后可恢复）', () async {
    await repo.follow(id: 'd1', title: '某剧', totalEpisode: 80);
    await repo.reportProgress(
      id: 'd1',
      episode: 5,
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 60),
    );

    final file = File(p.join(tempDir.path, 'progress.json'));
    expect(file.existsSync(), isTrue, reason: '进度必须落盘，否则重启丢进度');
    final raw = await file.readAsString();
    expect(raw, contains('d1'));
    expect(raw, contains('"episode":5'));
  });

  test('totalEpisode 未知（0）时仍可正常追剧与上报', () async {
    await repo.follow(id: 'd2', title: '无集数剧');
    final follows = await repo.follows();
    expect(follows.single.totalEpisode, 0);

    await repo.reportProgress(
      id: 'd2',
      episode: 1,
      position: const Duration(seconds: 3),
      duration: Duration.zero,
    );
    final resume = await repo.resumeFor('d2');
    expect(resume!.episode, 1);
  });
}
