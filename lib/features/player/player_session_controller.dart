// ignore_for_file: unnecessary_getters_setters

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/diary_service.dart';
import 'package:duanju_app/core/lan_models.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/features/player/playback_diagnostics.dart';
import 'package:duanju_app/features/player/playback_loader.dart';
import 'package:duanju_app/features/player/playback_preloader.dart';
import 'package:duanju_app/features/player/playback_progress_controller.dart';
import 'package:duanju_app/features/player/playback_recovery.dart';

/// 播放页向控制器暴露的媒体与界面副作用；控制器不直接依赖 media_kit。
abstract interface class PlayerPlaybackHost {
  bool get closed;
  bool get foreground;
  bool get localOnly;
  bool get allowOnlineFallback;
  bool get playerPlaying;
  bool get playerCompleted;
  double get playheadSeconds;

  Future<void> saveProgress({bool flush = false});
  void cancelInteractions();
  void resetSeekSequence();
  void suspendEnhancement();
  Future<void> beforeMedia();
  Future<void> stopPlayer();
  Future<void> openPlan(
    PlaybackPlan plan, {
    required double position,
    required bool play,
  });
  void mediaReady();
  Future<void> applySpeed();
  Future<void> playOrPause();
  void setDanmakuPlan(PlaybackPlan? plan);
  void syncDanmaku();
  void acknowledgeHandoff();
  void bumpMenu();
  void attachLan(PlayerSessionController controller);
  void detachLan();
  void resetHealth();
  void queueRecovery(String reason);
  void cancelPendingRecovery();
  void failHandoff(String message);
  void releaseHandoffOwnership();
}

/// 播放会话状态机：分集切换、线路解析、恢复与重试。
class PlayerSessionController extends ChangeNotifier {
  PlayerSessionController({
    required this.repository,
    required this.detail,
    required this.loader,
    required this.preloader,
    required this.progress,
    required this.host,
    required this.initialIndex,
    required PlaybackPreferences preferences,
    this.handoff,
  }) : _index = initialIndex,
       _speed = preferences.speed,
       _requestedQuality = preferences.quality,
       _danmakuEnabled = preferences.danmaku;

  final AppRepository repository;
  final DramaDetail detail;
  final PlaybackLoader loader;
  final PlaybackPreloader preloader;
  final PlaybackProgressController progress;
  final PlayerPlaybackHost host;
  final int initialIndex;
  final LanIncomingPlayback? handoff;

  final _recovery = PlaybackRecovery();
  late Object lanIdentity = Object();
  Future<void> _operations = Future<void>.value();
  bool _disposed = false;

  int _index;
  int _generation = 0;
  PlaybackPlan? _plan;
  bool _loading = true;
  String _loadingMessage = '正在准备播放';
  String? _error;
  bool _localFailure = false;
  bool _forceOnline = false;
  int _requestedQuality;
  double _speed;
  bool _autoAdvance = true;
  bool _danmakuEnabled;
  bool _preloadEnabled = true;
  bool _acceptErrors = false;
  bool _playIntent = true;
  double _resumePosition = 0;
  bool _showControlsOnPlaybackReady = true;
  bool _handoffOwned = true;

  int get index => _index;
  int get generation => _generation;
  PlaybackPlan? get plan => _plan;
  bool get loading => _loading;
  String get loadingMessage => _loadingMessage;
  String? get error => _error;
  bool get localFailure => _localFailure;
  bool get forceOnline => _forceOnline;
  int get requestedQuality => _requestedQuality;
  double get speed => _speed;
  bool get autoAdvance => _autoAdvance;
  bool get danmakuEnabled => _danmakuEnabled;
  bool get preloadEnabled => _preloadEnabled;
  bool get acceptErrors => _acceptErrors;
  bool get playIntent => _playIntent;
  double get resumePosition => _resumePosition;
  bool get showControlsOnPlaybackReady => _showControlsOnPlaybackReady;
  bool get handoffOwned => _handoffOwned;
  String get session => _plan?.session ?? '';
  Future<void> get operations => _operations;
  String get qualityLabel => _plan?.local == true
      ? '本地原画'
      : _requestedQuality == 0
      ? '自动'
      : '${_requestedQuality}P';

  set speed(double value) => _speed = value;
  set requestedQuality(int value) => _requestedQuality = value;
  set autoAdvance(bool value) => _autoAdvance = value;
  set danmakuEnabled(bool value) => _danmakuEnabled = value;
  set preloadEnabled(bool value) => _preloadEnabled = value;
  set playIntent(bool value) => _playIntent = value;
  set handoffOwned(bool value) => _handoffOwned = value;
  set resumePosition(double value) => _resumePosition = value;

  double get currentPosition =>
      progress.openedIndex == _index && host.playheadSeconds > 0
      ? host.playheadSeconds
      : _resumePosition;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void markHandoffCancelled(String message) {
    _loading = false;
    _error = message;
    notifyListeners();
  }

  Future<void> play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
    bool showControlsOnReady = true,
  }) async {
    if (host.closed || index < 0 || index >= detail.episodes.length) return;
    host.cancelInteractions();
    if (handoff != null && handoffPlan == null && recoveryAction == null) {
      _handoffOwned = false;
      host.failHandoff('接收端已更换播放内容');
    }
    if (index != _index) _forceOnline = false;
    final warmed =
        handoffPlan ??
        (recoveryAction == null && _preloadEnabled && !host.localOnly
            ? preloader.take(
                detail.drama,
                detail.episodes[index],
                quality: _requestedQuality,
                online: _forceOnline,
              )
            : null);
    preloader.clear();
    final ticket = ++_generation;
    host.suspendEnhancement();
    host.resetSeekSequence();
    host.setDanmakuPlan(null);
    _acceptErrors = false;
    host.cancelPendingRecovery();
    host.resetHealth();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _showControlsOnPlaybackReady = showControlsOnReady;
    _index = index;
    _loading = true;
    _error = null;
    _localFailure = false;
    _loadingMessage = switch (recoveryAction) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      _ => '正在准备播放',
    };
    notifyListeners();
    host.detachLan();
    lanIdentity = Object();
    host.attachLan(this);
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      await _serialize(() async {
        if (host.closed || ticket != _generation) return;
        await host.saveProgress(flush: true);
        await host.beforeMedia();
        if (host.closed || ticket != _generation) return;
        progress.beginEpisode();
        await host.stopPlayer();
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          await _release(previous.session, 'replace_or_refresh');
        }
      });
      if (host.closed || ticket != _generation) return;
      prepared = retained != null
          ? await loader.fallback(retained!)
          : warmed != null
          ? await loader.use(warmed)
          : await loader.load(
              detail.drama,
              detail.episodes[index],
              quality: _requestedQuality,
              localOnly: host.localOnly,
              online: _forceOnline,
            );
      if (prepared == null) return;
      final plan = prepared;
      await _serialize(() async {
        if (host.closed || ticket != _generation) {
          await _release(plan.session, 'stale_generation');
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        DiaryService.add(
          '[Play] open generation=$ticket route=${plan.routeIndex}/${plan.routeCount} session=${playbackDiagnosticId(plan.session)} url=${playbackDiagnosticUrl(plan.url)} headers=${plan.headers.keys.toList()}',
        );
        await host.openPlan(
          plan,
          position: position,
          play: host.foreground && _playIntent,
        );
        if (host.closed || ticket != _generation) return;
        progress.markOpened(index);
        host.mediaReady();
        host.attachLan(this);
        host.resetHealth();
        await host.applySpeed();
        if (!host.closed && ticket == _generation) {
          _loading = false;
          notifyListeners();
          host.setDanmakuPlan(plan);
          host.syncDanmaku();
          host.acknowledgeHandoff();
          host.bumpMenu();
        }
      });
    } catch (error) {
      DiaryService.add(
        '[Play] flow_error generation=$ticket error=${playbackDiagnosticError(error)}',
      );
      if (!host.closed && ticket == _generation) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          host.queueRecovery('open_exception');
        } else {
          if (prepared != null) {
            await _release(prepared.session, 'failed_preparation');
          }
          if (!host.closed && ticket == _generation) {
            _loading = false;
            _localFailure =
                (error is AppFailure &&
                    error.kind == AppFailureKind.localMedia) ||
                (host.localOnly && !_forceOnline);
            _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
            notifyListeners();
            host.failHandoff(_error!);
          }
        }
      } else if (prepared != null && !installed) {
        await _release(prepared.session, 'failed_preparation');
      }
    } finally {
      if (warmed != null && !installed) {
        await _release(warmed.session, 'unused_preload');
      }
      if (retained != null) {
        await _release(retained!.session, 'fallback_previous');
      }
    }
  }

  Future<void> recover({required String reason}) async {
    final current = _plan;
    if (host.closed ||
        !_acceptErrors ||
        !host.foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    host.setDanmakuPlan(null);
    host.cancelPendingRecovery();
    final position = currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    DiaryService.add(
      '[Recovery] start reason=$reason action=${action.name} generation=$_generation route=${current.routeIndex}/${current.routeCount} session=${playbackDiagnosticId(current.session)} position=${(host.playheadSeconds * 1000).round()}',
    );
    if (action == PlaybackRecoveryAction.stop) {
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (host.closed || ticket != _generation) return;
          try {
            await host.saveProgress();
            progress.beginEpisode();
            await host.stopPlayer();
          } finally {
            await _release(current.session, 'recovery_stop');
          }
        });
      } catch (_) {}
      if (!host.closed && ticket == _generation) {
        _loading = false;
        _localFailure = current.local;
        _error = current.local
            ? host.allowOnlineFallback
                  ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                  : '本地成品读取失败，请重试或重新生成。'
            : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        notifyListeners();
      }
      return;
    }
    await play(_index, position: position, recoveryAction: action);
  }

  Future<void> togglePlayback() async {
    if (host.closed || _loading || _error != null) return;
    _handoffOwned = false;
    host.failHandoff('接收端已操作播放');
    host.cancelInteractions();
    _playIntent = !host.playerPlaying;
    if (_playIntent) host.mediaReady();
    host.resetHealth();
    if (_playIntent && host.playerCompleted) {
      await play(_index);
      return;
    }
    await host.playOrPause();
    if (!_playIntent) await host.saveProgress(flush: true);
    host.syncDanmaku();
    notifyListeners();
  }

  Future<void> retry({int? quality}) async {
    final position = currentPosition;
    if (quality != null) _requestedQuality = quality;
    await play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || host.playerPlaying,
    );
  }

  Future<void> switchOnline() async {
    _forceOnline = true;
    await retry();
  }

  Future<void> release(String session, String reason) =>
      _release(session, reason);

  Future<void> releaseSession(String reason) => _release(session, reason);

  Future<void> _release(String session, String reason) async {
    DiaryService.add(
      '[Recovery] release reason=$reason generation=$_generation session=${playbackDiagnosticId(session)}',
    );
    await repository.release(session);
  }

  Future<void> serialize(Future<void> Function() operation) =>
      _serialize(operation);

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
