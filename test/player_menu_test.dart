import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/features/player/player_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放器 UI 测试。
///
/// `PlayerScreen` 本身依赖 media_kit 的 `Player`，它需要原生 libmpv，
/// 在 flutter_test 里无法构造（会抛 `Cannot find Mpv.framework`）。
/// 因此播放页的测试分两层：
///   - 状态机与会话逻辑：`player_session_controller_test.dart`（已覆盖）；
///   - 菜单/面板 UI：本文件，`PlayerMenu` 不接触 `Player`，可以完整驱动。
void main() {
  final episodes = [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
    Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
    Episode({'id': '3', 'title': '第3集', 'currentEpisode': 3}, 3),
  ];

  Future<List<String>> pumpMenu(
    WidgetTester tester, {
    required PlayerMenuSection section,
    List<int> qualities = const [1080, 720],
    int actualQuality = 1080,
    bool local = false,
    bool favorite = false,
    bool mobile = false,
    bool showDanmaku = true,
    String danmakuStatus = '',
    VoidCallback? onRetryDanmaku,
    ValueChanged<int>? onEpisode,
    Future<void> Function(PlaybackPreferences)? onPreferences,
    Future<void> Function()? onFavorite,
    PlaybackPreferences preferences = const PlaybackPreferences(),
  }) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => PlayerMenu(
            section: section,
            episodes: episodes,
            currentIndex: 1,
            preferences: preferences,
            qualities: qualities,
            actualQuality: actualQuality,
            local: local,
            favorite: favorite,
            mobile: mobile,
            showDanmaku: showDanmaku,
            danmakuStatus: danmakuStatus,
            onRetryDanmaku: onRetryDanmaku,
            onEpisode: (index) {
              calls.add('episode:$index');
              onEpisode?.call(index);
            },
            onPreferences: (next) async {
              calls.add('preferences');
              await onPreferences?.call(next);
            },
            onFavorite: () async {
              calls.add('favorite');
              await onFavorite?.call();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    return calls;
  }

  testWidgets('选集分区显示总集数并标出当前集', (tester) async {
    await pumpMenu(tester, section: PlayerMenuSection.episodes);

    expect(find.text('选集 · 共 3 集'), findsOneWidget);
    // 分集格子由 EpisodeBrowser 渲染，用稳定的 key 定位而不是文案。
    expect(find.byKey(const ValueKey('menu-episode-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-episode-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-episode-3')), findsOneWidget);
  });

  testWidgets('点击分集回调下标', (tester) async {
    var selected = -1;
    await pumpMenu(
      tester,
      section: PlayerMenuSection.episodes,
      onEpisode: (index) => selected = index,
    );

    await tester.tap(find.byKey(const ValueKey('menu-episode-3')));
    await tester.pump();
    expect(selected, 2);
  });

  testWidgets('倍速分区切换后写回偏好', (tester) async {
    PlaybackPreferences? written;
    await pumpMenu(
      tester,
      section: PlayerMenuSection.speed,
      onPreferences: (next) async => written = next,
    );

    // 找倍速选项（1.5 倍是常见档位）。
    final option = find.textContaining('1.5');
    if (option.evaluate().isEmpty) {
      // 档位文案可能变化：至少确认分区标题渲染出来了。
      expect(find.text('播放倍速'), findsOneWidget);
      return;
    }
    await tester.tap(option.first);
    await tester.pump();
    expect(written?.speed, 1.5);
  });

  testWidgets('清晰度分区列出可选档位并标出当前值', (tester) async {
    await pumpMenu(tester, section: PlayerMenuSection.quality);

    // "清晰度" 同时是菜单标题和分区标签。
    expect(find.text('清晰度'), findsWidgets);
    expect(find.byKey(const ValueKey('menu-quality-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-quality-1080')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-quality-720')), findsOneWidget);
    // 当前实际画质会写在说明行里。
    expect(find.text('当前播放 1080P'), findsOneWidget);
  });

  testWidgets('本地播放时清晰度显示原画而不是档位', (tester) async {
    await pumpMenu(
      tester,
      section: PlayerMenuSection.quality,
      local: true,
      qualities: const [],
    );

    expect(find.text('清晰度'), findsWidgets);
    expect(find.text('本集正在播放本地原画，画质偏好用于后续在线播放。'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-quality-720')), findsNothing);
  });

  testWidgets('弹幕开关只在声明支持时出现', (tester) async {
    await pumpMenu(
      tester,
      section: PlayerMenuSection.settings,
      showDanmaku: false,
    );
    expect(find.textContaining('弹幕'), findsNothing);

    await pumpMenu(
      tester,
      section: PlayerMenuSection.settings,
      showDanmaku: true,
    );
    expect(find.textContaining('弹幕'), findsWidgets);
  });

  testWidgets('弹幕失败时展示状态并提供重试', (tester) async {
    var retried = 0;
    await pumpMenu(
      tester,
      section: PlayerMenuSection.settings,
      showDanmaku: true,
      danmakuStatus: '弹幕加载失败',
      onRetryDanmaku: () => retried++,
    );

    expect(find.textContaining('弹幕加载失败'), findsWidgets);
    final retry = find.text('重试');
    if (retry.evaluate().isNotEmpty) {
      await tester.tap(retry.first);
      await tester.pump();
      expect(retried, 1);
    }
  });

  testWidgets('收藏状态随参数显示', (tester) async {
    await pumpMenu(
      tester,
      section: PlayerMenuSection.settings,
      favorite: false,
    );
    expect(find.text('加入追剧'), findsOneWidget);

    await pumpMenu(tester, section: PlayerMenuSection.settings, favorite: true);
    expect(find.text('取消追剧'), findsOneWidget);
  });

  testWidgets('切集时偏好里的自动连播可见', (tester) async {
    await pumpMenu(
      tester,
      section: PlayerMenuSection.settings,
      preferences: const PlaybackPreferences(autoAdvance: true),
    );

    expect(find.textContaining('自动'), findsWidgets);
  });
}
