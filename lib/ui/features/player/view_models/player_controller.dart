import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../data/repositories/playback_repository.dart';
import '../../../../data/repositories/progress_repository.dart';
import '../../../core/playback/playback_settings.dart';
import '../../detail/view_models/detail_view_model.dart';

/// 播放页的**引擎侧**状态与动作（不含任何 UI）。
///
/// **为什么要有这一层**：此前 `_PlayerViewState` 同时管引擎与版式，
/// 一个 State 八百多行——打开、续播定位、切集、换档、连播、进度上报
/// 全混在 `build` 旁边，既测不了也改不动。现在：
///
/// - 本类只管「播哪一集、放到哪、上报什么」，纯逻辑，可用 fake 依赖单测；
/// - 视图只管「怎么画」，两个版式（竖屏 / 横屏）共用同一个控制器。
///
/// 生命周期：由 `PlayerView` 的 State 创建与 `dispose`，
/// 因此 [Player] 的释放时机与页面一致（离页即释放，不留后台播放）。
class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.ref,
    required this.seriesId,
    required this.source,
    required int? initialEpisode,
    this.onFirstFrameReady,
  }) : _episode = initialEpisode ?? 1;

  /// 视图侧的 `ref`。
  ///
  /// 传 `WidgetRef` 而不是 `Ref`：本类由 ConsumerState 持有，
  /// 且需要 `read` 现有的 provider（与 `progressActions` 同一约定）。
  final WidgetRef ref;

  final String seriesId;
  final String source;

  /// 首次成功打开媒体后的回调（视图用它记一次诊断日志 / 收起 loading）。
  final VoidCallback? onFirstFrameReady;

  /// media_kit 播放器。视图把它交给 `VideoController` 渲染。
  final Player player = Player();
  late final VideoController videoController = VideoController(player);

  int _episode;
  int _openedEpisode = 0;

  /// 是否已按续播记录定位过（每集只跳一次，避免与用户拖动打架）。
  bool _resumeApplied = false;

  /// 播放中换档的目标高度；`null` = 跟随设置页的清晰度偏好。
  ///
  /// 换档是**本集**的选择，不该反向改写全局偏好（那是设置页的事）。
  int? _qualityOverride;

  /// 是否正在换档（禁用菜单、避免连点）。
  bool _switchingQuality = false;

  /// 上一次上报错误（用于视图提示一次，不弹窗反复打扰）。
  String? _lastError;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;

  /// 当前集号（1-based）。
  int get episode => _episode;

  /// 当前已真正打开（有媒体在播放器里）的集号；`0` = 尚未打开。
  ///
  /// 切集后到新媒体打开前，位置流仍会推旧视频的位置——据 [episode] 上报
  /// 会把「旧集的位置」记成「新集的进度」。故只在两者一致时上报。
  int get openedEpisode => _openedEpisode;

  bool get hasOpened => _openedEpisode > 0;

  int? get qualityOverride => _qualityOverride;

  bool get switchingQuality => _switchingQuality;

  String? get lastError => _lastError;

  /// 总集数：优先用 Rust 分组结果（与选集区同一口径），未就绪时回落详情。
  int get episodeCount {
    final fromGroups = ref
        .read(episodeGroupsProvider((id: seriesId, source: source)))
        .value
        ?.total;
    if (fromGroups != null && fromGroups > 0) return fromGroups;
    return ref
            .read(detailProvider((id: seriesId, source: source)))
            .value
            ?.episodes
            .length ??
        0;
  }

  bool get hasPrevious => _episode > 1;

  bool get hasNext => episodeCount > 0 && _episode < episodeCount;

  /// 开始监听播放器事件。构造后必须调用一次。
  void attach() {
    _positionSub = player.stream.position.listen(_onPosition);
    // 播放自然结束 → 自动连播下一集（受设置开关约束）。
    _completedSub = player.stream.completed.listen((completed) {
      if (completed) _playNextIfAny();
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _completedSub?.cancel();
    player.dispose();
    super.dispose();
  }

  /// 播放位置回调：节流后上报进度（`historyPut` 同时刷新追剧条目与历史）。
  ///
  /// 上报失败**静默忽略**——播放不应因持久化失败而中断；下次回调会重试。
  void _onPosition(Duration position) {
    if (_openedEpisode != _episode) return;
    final actions = ref.read(progressActionsProvider);
    final now = DateTime.now();
    if (actions.shouldThrottle(seriesId, now, source: source)) return;
    final duration = player.state.duration;
    actions.markReported(seriesId, now, source: source);
    unawaited(
      actions
          .reportProgress(
            ref,
            id: seriesId,
            episode: _episode,
            position: position,
            duration: duration,
            source: source,
          )
          .catchError((Object _) {}),
    );
  }

  /// 自动连播：受设置开关约束，且仅当当前集不是最后一集时前进。
  void _playNextIfAny() {
    if (!ref.read(playbackSettingsProvider).autoPlayNext) return;
    if (!hasNext) return;
    goToEpisode(_episode + 1);
  }

  /// 切集。
  ///
  /// 重置续播标记（新集需按该集记录重新定位），并让 [openedEpisode]
  /// 与 [episode] 脱钩——新媒体打开前收到的位置一律不上报。
  void goToEpisode(int episode) {
    if (episode < 1) return;
    final total = episodeCount;
    if (total > 0 && episode > total) return;
    _episode = episode;
    _resumeApplied = false;
    _openedEpisode = 0;
    // 换档是每集的选择：切集后回到跟随全局偏好。
    _qualityOverride = null;
    notifyListeners();
  }

  void next() {
    if (hasNext) goToEpisode(_episode + 1);
  }

  void previous() {
    if (hasPrevious) goToEpisode(_episode - 1);
  }

  /// 拖动定位：松手即 seek 并立即上报进度（不等节流窗口）。
  void seek(Duration target) {
    unawaited(player.seek(target));
    final actions = ref.read(progressActionsProvider);
    unawaited(
      actions
          .reportProgress(
            ref,
            id: seriesId,
            episode: _episode,
            position: target,
            duration: player.state.duration,
            source: source,
          )
          .catchError((Object _) {}),
    );
  }

  void togglePlay() =>
      player.state.playing ? unawaited(player.pause()) : unawaited(player.play());

  void setSpeed(double speed) => unawaited(player.setRate(speed));

  double get speed => player.state.rate;

  /// 换档：走 `playQuality` 复用已解析候选线路，不重跑签名链。
  ///
  /// 需要当前集的 `vid`（Rust 侧用它命中候选线路缓存），所以由视图把
  /// 当前 plan 传进来。换档**不改**全局清晰度偏好——那是设置页的事。
  Future<void> switchQuality(PlaybackPlan current, int height) async {
    if (_switchingQuality || current.vid.isEmpty) return;
    _switchingQuality = true;
    _lastError = null;
    notifyListeners();
    try {
      final plan = await ref.read(playbackRepositoryProvider).switchQuality(
        seriesId: seriesId,
        vid: current.vid,
        quality: height,
        source: source,
      );
      // 换档会换掉代理地址，必须重开媒体；保留当前播放位置。
      final resumeAt = player.state.position;
      _qualityOverride = height;
      await _open(plan, resumeAt: resumeAt);
    } catch (error) {
      _lastError = _describe(error);
    } finally {
      _switchingQuality = false;
      notifyListeners();
    }
  }

  /// 用一份播放计划打开媒体；[resumeAt] 非空时定位到该位置（换档路径）。
  Future<void> open(
    PlaybackPlan plan, {
    bool applyResume = true,
  }) async {
    if (plan.proxyUrl.isEmpty) {
      _lastError = '取流失败：地址为空';
      notifyListeners();
      return;
    }
    Duration? resumeAt;
    if (applyResume && !_resumeApplied) {
      // 续播定位只做一次；位置为 0 的记录不算「看过一部分」。
      final saved = ref
          .read(resumeProvider((id: seriesId, source: source)))
          .value;
      if (saved != null &&
          saved.episode == _episode &&
          saved.position > Duration.zero) {
        resumeAt = saved.position;
      }
      _resumeApplied = true;
    }
    await _open(plan, resumeAt: resumeAt);
  }

  Future<void> _open(PlaybackPlan plan, {Duration? resumeAt}) async {
    try {
      await player.open(Media(plan.proxyUrl), play: _shouldAutoPlay);
      // 只有打开的是「当前集」才算打开成功——
      // 快速连点切集时，先发的 open 可能后完成。
      _openedEpisode = _episode;
      if (resumeAt != null && resumeAt > Duration.zero) {
        await player.seek(resumeAt);
      }
      onFirstFrameReady?.call();
      notifyListeners();
    } catch (error) {
      _lastError = _describe(error);
      notifyListeners();
    }
  }

  /// 进入即播开关：关掉时打开媒体但暂停在第一帧。
  bool get _shouldAutoPlay =>
      ref.read(playbackSettingsProvider).autoPlayOnOpen;

  /// 取一次错误文案并清除（视图提示一次即可，不反复弹）。
  String? takeError() {
    final error = _lastError;
    _lastError = null;
    return error;
  }

  static String _describe(Object error) =>
      error is Exception ? error.toString() : '$error';
}
