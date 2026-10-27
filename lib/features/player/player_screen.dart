import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'package:duanju_app/app/app_layout.dart';
import 'package:duanju_app/app/app_orientation.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/core/app_platform.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/diary_service.dart';
import 'package:duanju_app/features/player/playback_diagnostics.dart';
import 'package:duanju_app/features/player/luna_exo_player.dart';
import 'package:duanju_app/features/player/danmaku_controller.dart';
import 'package:duanju_app/features/player/danmaku_overlay.dart';
import 'package:duanju_app/features/detail/download_picker.dart';
import 'package:duanju_app/features/downloads/downloads_screen.dart';
import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/responsive/window_type.dart';
import 'package:duanju_app/features/player/playback_loader.dart';
import 'package:duanju_app/features/player/playback_preloader.dart';
import 'package:duanju_app/features/player/playback_health_controller.dart';
import 'package:duanju_app/features/player/playback_progress_controller.dart';
import 'package:duanju_app/features/player/playback_recovery_scheduler.dart';
import 'package:duanju_app/core/playback_preferences.dart';
import 'package:duanju_app/features/player/player_controls.dart';
import 'package:duanju_app/features/player/player_interactions.dart';
import 'package:duanju_app/features/player/player_session_controller.dart';
import 'package:duanju_app/features/player/player_menu.dart';
import 'package:duanju_app/widgets/drama_labels.dart';
import 'package:duanju_app/widgets/widgets.dart';
import 'package:duanju_app/features/sources/sources_screen.dart';
import 'package:duanju_app/features/lan/lan_controller.dart';
import 'package:duanju_app/features/lan/lan_screen.dart';
import 'package:duanju_app/features/player/video_enhancement.dart';
import 'package:duanju_app/features/player/video_output_size.dart';

part 'player_layout.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.handoff,
    this.lan,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  final LanController? lan;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver
    implements PlayerPlaybackHost {
  late final Player _player;
  late final VideoController? _video;
  late final VideoEnhancementController _enhancement;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  late final DanmakuController _danmaku;
  int _seekSequence = 0;
  late final PlayerInteractions _interactions;
  late final PlaybackProgressController _progress;
  late final PlaybackRecoveryScheduler _recoveryScheduler;
  int get _openedIndex => _progress.openedIndex;
  String? get _saveWarning => _progress.warning;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _videoPaneKey = GlobalKey();
  final _menuRevision = ValueNotifier<int>(0);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  double? _lanFirstPosition;
  late final PlaybackHealthController _health;
  Timer? _saveTimer;
  Timer? _pictureInPictureExitTimer;
  bool _fullscreen = false;
  bool _automaticFullscreenSuppressed = false;
  bool _panelOpen = false;
  int _mobileTab = 0;
  bool? _systemFullscreen;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _foreground = true;
  bool _pictureInPictureSupported = false;
  bool _pictureInPictureActive = false;
  bool _pictureInPictureRequested = false;
  bool _pictureInPictureHandlerInstalled = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  double _aspectRatio = 9 / 16;
  bool _rotating = false;
  AppOrientationController? _orientationController;
  late final PlayerSessionController _session;

  int get _index => _session.index;
  int get _generation => _session.generation;
  PlaybackPlan? get _plan => _session.plan;
  bool get _loading => _session.loading;
  String get _loadingMessage => _session.loadingMessage;
  String? get _error => _session.error;
  bool get _localFailure => _session.localFailure;
  int get _requestedQuality => _session.requestedQuality;
  set _requestedQuality(int value) => _session.requestedQuality = value;
  double get _speed => _session.speed;
  set _speed(double value) => _session.speed = value;
  bool get _autoAdvance => _session.autoAdvance;
  set _autoAdvance(bool value) => _session.autoAdvance = value;
  bool get _danmakuEnabled => _session.danmakuEnabled;
  set _danmakuEnabled(bool value) => _session.danmakuEnabled = value;
  bool get _preloadEnabled => _session.preloadEnabled;
  set _preloadEnabled(bool value) => _session.preloadEnabled = value;
  bool get _acceptErrors => _session.acceptErrors;
  bool get _playIntent => _session.playIntent;
  set _playIntent(bool value) => _session.playIntent = value;
  double get _resumePosition => _session.resumePosition;
  set _resumePosition(double value) => _session.resumePosition = value;
  bool get _showControlsOnPlaybackReady => _session.showControlsOnPlaybackReady;

  bool get _handoffOwned => _session.handoffOwned;
  set _handoffOwned(bool value) => _session.handoffOwned = value;
  bool get _pictureInPictureVisible =>
      _pictureInPictureActive || _pictureInPictureRequested;
  bool get _canUsePictureInPicture =>
      defaultTargetPlatform == TargetPlatform.android &&
      _pictureInPictureSupported;
  bool get _mobile => isMobilePlatform;
  bool get _desktop => isDesktopPlatform;
  VideoEnhancementController? get _enhancementForUi =>
      _enhancement.supported ? _enhancement : null;
  PlaybackPreferences get _preferences => PlaybackPreferences(
    speed: _speed,
    quality: _requestedQuality,
    autoAdvance: _autoAdvance,
    danmaku: _danmakuEnabled,
    preload: _preloadEnabled,
    enhancement: _enhancement.preferences,
  );
  String get _qualityLabel => _plan?.local == true
      ? '本地原画'
      : _requestedQuality == 0
      ? '自动'
      : '${_requestedQuality}P';
  double get _currentPosition =>
      _openedIndex == _index && _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _resumePosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final preferences = widget.store.playbackPreferences;
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);
    _danmaku = DanmakuController(widget.repository)
      ..setEnabled(_danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _player =
        widget.playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
            logLevel: MPVLogLevel.error,
          ),
        );
    _video = widget.videoBuilder == null
        ? VideoController(
            _player,
            configuration: VideoControllerConfiguration(
              enableHardwareAcceleration: !isIOSPlatform,
            ),
          )
        : null;
    _enhancement = VideoEnhancementController(
      player: _player,
      video: _video,
      preferences: preferences.enhancement,
      category: widget.detail.drama.category,
      tags: widget.detail.drama.tags,
    );
    _interactions = PlayerInteractions(
      player: _player,
      available: () =>
          !_closed && !_loading && _error == null && _foreground && !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: _rotate,
      onEpisode: (direction) {
        final next = _index + direction;
        if (next < 0) return '已经是第一集';
        if (next >= widget.detail.episodes.length) return '已经是最后一集';
        unawaited(_session.play(next));
        return '第 ${widget.detail.episodes[next].number} 集';
      },
    );
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _progress = PlaybackProgressController(
      store: widget.store,
      repository: widget.repository,
      detail: widget.detail,
      mediaId: widget.mediaId,
      flushLan: () => widget.lan?.flush(),
    )..addListener(_progressChanged);
    _recoveryScheduler = PlaybackRecoveryScheduler(
      recover: (reason) => unawaited(_recover(reason: reason)),
      canRecover: () => !_closed && _acceptErrors && _error == null,
      isForeground: () => _foreground,
      generation: () => _generation,
      position: () => _player.state.position,
      playerState: () {
        final state = _player.state;
        return (
          playing: state.playing,
          buffering: state.buffering,
          width: state.width ?? 0,
          position: state.position,
        );
      },
    );
    _session = PlayerSessionController(
      repository: widget.repository,
      detail: widget.detail,
      loader: _loader,
      preloader: _preloader,
      progress: _progress,
      host: this,
      initialIndex: widget.initialIndex,
      preferences: preferences,
      handoff: widget.handoff,
    )..addListener(_sessionChanged);
    _configurePictureInPicture();
    _subscriptions.add(
      _player.stream.error.listen((error) {
        DiaryService.add(
          '[Recovery] player_error error=${playbackDiagnosticError(error)} generation=$_generation accepted=$_acceptErrors',
        );
        if (_enhancement.handlePlaybackError(error)) return;
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _queueRecovery(reason: 'player_error');
        }
      }),
    );
    _subscriptions.add(
      _player.stream.log.listen((log) {
        if (_closed ||
            !playbackDiagnosticLogRelevant(
              level: log.level,
              prefix: log.prefix,
              text: log.text,
            )) {
          return;
        }
        final text = playbackDiagnosticLogText(log.text);
        if (text.isEmpty) return;
        DiaryService.add(
          '[MPV] level=${log.level} prefix=${playbackDiagnosticLogText(log.prefix)} generation=$_generation text=$text',
        );
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          if (duration <= Duration.zero ||
              _player.state.position < duration - const Duration(seconds: 2)) {
            _queueRecovery(reason: 'early_completion');
          } else if (_autoAdvance &&
              _foreground &&
              !_panelOpen &&
              _index + 1 < widget.detail.episodes.length) {
            _session.play(_index + 1, showControlsOnReady: false);
          } else {
            _playIntent = false;
            _interactions.cancel();
            unawaited(_player.pause());
            unawaited(_saveProgress(flush: true));
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
        _syncDanmaku();
        _syncPreload();
        _acknowledgeHandoff();
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          _syncDanmaku();
          _syncPreload();
          _acknowledgeHandoff();
        }),
      );
    }
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size != null && mounted && !_closed) {
          setState(() {
            _aspectRatio = size.width / size.height;
          });
          _scheduleSystemUi();
        }
        unawaited(_logVideoOutput(parameters));
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _health = PlaybackHealthController(
      recover: (reason) => unawaited(_recover(reason: reason)),
      snapshot: () => PlaybackHealthSnapshot(
        closed: _closed,
        acceptErrors: _acceptErrors,
        loading: _loading,
        failed: _error != null,
        position: _player.state.position,
        playing: _player.state.playing && _playIntent,
        foreground: _foreground,
      ),
    )..start();
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (handoff?.cancelled == true) {
      handoff?.fail('接收用户已变更，推送已取消');
      if (handoff != null) {
        unawaited(_releasePlayback(handoff.plan.session, 'handoff_discarded'));
      }
      _session.markHandoffCancelled('播放接收已取消');
    } else {
      _session.play(
        _index,
        position: widget.initialPosition,
        handoffPlan: handoff?.plan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
      }
    });
  }

  void _progressChanged() {
    if (mounted && !_closed) setState(() {});
  }

  void _sessionChanged() {
    if (mounted && !_closed) setState(() {});
  }

  void _accessChanged() {
    if (!_closed && widget.store.locked) {
      _preloader.clear();
      _enhancement.suspend();
      _handoffOwned = false;
      _playIntent = false;
      widget.handoff?.fail('接收端配置已锁定');
      unawaited(_player.pause());
    }
    if (!_closed && !widget.store.allowsSource('hongguo')) {
      _danmaku.setPlan(null);
    }
  }

  void _configurePictureInPicture() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _pictureInPictureHandlerInstalled = true;
    AppDevice.channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureInPictureChanged') {
        final arguments = call.arguments;
        final active = arguments is Map && arguments['active'] == true;
        _setPictureInPictureStatus(active: active, delayHiddenPause: !active);
      }
    });
    unawaited(_refreshPictureInPictureStatus());
  }

  Future<void> _refreshPictureInPictureStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (!mounted || _closed) return;
      _setPictureInPictureStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    } on MissingPluginException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    }
  }

  void _setPictureInPictureStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _pictureInPictureSupported;
    final nextActive = active ?? _pictureInPictureActive;
    final nextRequested =
        requested ?? (nextActive ? false : _pictureInPictureRequested);
    void assign() {
      _pictureInPictureSupported = nextSupported;
      _pictureInPictureActive = nextActive;
      _pictureInPictureRequested = nextRequested;
    }

    if (mounted && !_closed) {
      setState(assign);
    } else {
      assign();
    }
    if (_pictureInPictureVisible ||
        _lifecycleState == AppLifecycleState.resumed) {
      _pictureInPictureExitTimer?.cancel();
      _applyLifecycleVisibility(pauseWhenHidden: false);
      return;
    }
    _pictureInPictureExitTimer?.cancel();
    _applyLifecycleVisibility(pauseWhenHidden: !delayHiddenPause);
    if (delayHiddenPause) {
      _pictureInPictureExitTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_closed &&
            !_pictureInPictureVisible &&
            _lifecycleState != AppLifecycleState.resumed) {
          _applyLifecycleVisibility();
        }
      });
    }
  }

  void _applyLifecycleVisibility({bool pauseWhenHidden = true}) {
    final treatAsVisible = _desktop
        ? (AppLifecycleState.resumed == _lifecycleState ||
              AppLifecycleState.inactive == _lifecycleState)
        : _lifecycleState == AppLifecycleState.resumed;
    final visible = treatAsVisible || _pictureInPictureVisible;
    _foreground = visible;
    _enhancement.setForeground(_foreground);
    _syncDanmaku();
    _syncPreload();
    _health.reset();
    if (!visible) _interactions.cancel();
    if (pauseWhenHidden &&
        !visible &&
        (_lifecycleState == AppLifecycleState.paused ||
            (!_desktop && _lifecycleState == AppLifecycleState.inactive) ||
            _lifecycleState == AppLifecycleState.hidden)) {
      _playIntent = false;
      unawaited(_player.pause());
      unawaited(_saveProgress(flush: true));
    }
    if (visible && _recoveryScheduler.pending) {
      _queueRecovery(reason: 'foreground_pending_error');
    }
  }

  Future<void> _enterPictureInPicture() async {
    if (!_canUsePictureInPicture ||
        _closed ||
        _loading ||
        _error != null ||
        _panelOpen) {
      return;
    }
    _interactions.cancel();
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    _setPictureInPictureStatus(requested: true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _closed) return;
    final sourceRect = _pictureInPictureSourceRect();
    final arguments = <String, int>{'width': width, 'height': height};
    if (sourceRect != null) arguments.addAll(sourceRect);
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      if (!mounted || _closed) return;
      final supported = status?['supported'] == true;
      final active = status?['active'] == true;
      final requested = status?['requested'] == true;
      _setPictureInPictureStatus(
        supported: supported,
        active: active,
        requested: requested && !active,
      );
      if (!supported || (!active && !requested)) {
        _notice('当前设备不支持画中画');
      } else if (requested && !active) {
        _pictureInPictureExitTimer?.cancel();
        _pictureInPictureExitTimer = Timer(const Duration(seconds: 2), () {
          if (!_closed &&
              _pictureInPictureRequested &&
              !_pictureInPictureActive) {
            _setPictureInPictureStatus(requested: false);
          }
        });
      }
    } on PlatformException {
      _setPictureInPictureStatus(requested: false);
      _notice('无法进入画中画，请检查系统权限');
    } on MissingPluginException {
      _setPictureInPictureStatus(supported: false, requested: false);
      _notice('当前平台不支持画中画');
    }
  }

  Map<String, int>? _pictureInPictureSourceRect() {
    final paneContext = _videoPaneKey.currentContext;
    final renderObject = paneContext?.findRenderObject();
    if (paneContext == null ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final ratio =
        MediaQuery.maybeOf(paneContext)?.devicePixelRatio ??
        View.of(paneContext).devicePixelRatio;
    final left = (topLeft.dx * ratio).round().clamp(0, 100000);
    final top = (topLeft.dy * ratio).round().clamp(0, 100000);
    final right = ((topLeft.dx + size.width) * ratio).round().clamp(0, 100000);
    final bottom = ((topLeft.dy + size.height) * ratio).round().clamp(
      0,
      100000,
    );
    if (right <= left || bottom <= top) return null;
    return {'left': left, 'top': top, 'right': right, 'bottom': bottom};
  }

  void _attachLanPlayback(PlayerSessionController controller) {
    widget.lan?.attachPlayback(
      LanPlaybackHost(
        identity: controller.lanIdentity,
        title:
            '${widget.detail.drama.title} · 第 ${widget.detail.episodes[controller.index].number} 集',
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        _index != widget.initialIndex) {
      return;
    }
    final state = _player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20) {
      return;
    }
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    final generation = _generation;
    await _serialize(() async {
      if (_closed || generation != _generation) {
        return;
      }
      _playIntent = false;
      _interactions.cancel();
      _enhancement.suspend();
      _health.reset();
      await _player.pause();
      await _saveProgress(flush: true);
    });
  }

  Future<void> _pushToDevice() async {
    final link = widget.lan;
    if (link == null ||
        _panelOpen ||
        _closed ||
        _loading ||
        _error != null ||
        widget.mediaId != null) {
      return;
    }
    final generation = _generation;
    final index = _index;
    bool current() =>
        mounted && !_closed && generation == _generation && index == _index;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: widget.detail.drama,
          episodeID: widget.detail.episodes[index].id,
          episode: widget.detail.episodes[index].number,
          position: _currentPosition,
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          await _stopForLan();
          if (!current()) throw StateError('本机播放内容已变更');
        },
      );
    } catch (error) {
      if (mounted && !_closed) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_preloadEnabled ||
        !_foreground ||
        widget.localOnly ||
        _plan?.local == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      _preloader.clear();
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    if (duration <= 0 ||
        position < 2000 ||
        (position < duration ~/ 2 && duration - position > 45000) ||
        state.buffer.inMilliseconds - position < 5000) {
      return;
    }
    _preloader.prepare(
      widget.detail.drama,
      widget.detail.episodes[_index + 1],
      quality: _requestedQuality,
    );
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          !_loading &&
          _error == null &&
          _openedIndex == _index &&
          !widget.store.locked &&
          widget.store.allowsSource('hongguo'),
      discontinuity: discontinuity,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orientationController = AppOrientationScope.maybeOf(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || !_mobile) return;
      final fullscreen = _showFullscreen;
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _applyLifecycleVisibility();
  }

  Future<void> _releasePlayback(String session, String reason) =>
      _session.release(session, reason);

  void _queueRecovery({required String reason}) {
    DiaryService.add(
      '[Recovery] queued reason=$reason generation=$_generation',
    );
    _recoveryScheduler.queue(reason);
  }

  Future<void> _recover({required String reason}) =>
      _session.recover(reason: reason);

  void _togglePlayback() {
    unawaited(_session.togglePlayback());
  }

  Future<void> _saveProgress({bool flush = false}) => _progress.save(
    position: _player.state.position,
    duration: _player.state.duration,
    flush: flush,
  );

  Future<void> _serialize(Future<void> Function() operation) =>
      _session.serialize(operation);

  Future<void> _logVideoOutput(VideoParams parameters) async {
    final platform = _player.platform;
    if (_closed ||
        parameters.pixelformat == null ||
        platform is! NativePlayer) {
      return;
    }
    final generation = _generation;
    try {
      final hwdec = await platform.getProperty('hwdec-current');
      final vo = await platform.getProperty('current-vo');
      if (_closed) return;
      DiaryService.add(
        '[Video] generation=$generation hwdec=$hwdec vo=$vo format=${parameters.pixelformat} hw_format=${parameters.hwPixelformat} size=${parameters.w}x${parameters.h}',
      );
    } catch (_) {}
  }

  Future<void> _switchOnline() => _session.switchOnline();

  Future<void> _retry({int? quality}) => _session.retry(quality: quality);

  bool get _showFullscreen =>
      _fullscreen ||
      (_mobile &&
          !_automaticFullscreenSuppressed &&
          _aspectRatio >= 1 &&
          MediaQuery.orientationOf(context) == Orientation.landscape);

  Future<void> _rotate() async {
    if (_rotating) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      if (_desktop) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        await (_orientationController?.setPlayback(
              this,
              fullscreen: fullscreen,
              aspectRatio: _aspectRatio,
            ) ??
            SystemChrome.setPreferredOrientations(
              AppOrientationController.orientations(
                fullscreen: fullscreen,
                aspectRatio: _aspectRatio,
              ),
            ));
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed) {
      throw StateError('当前用户已变更');
    }
    _interactions.cancel();
    final nextPreferences = preferences.copyWith(
      autoAdvance: true,
      preload: true,
    );
    await widget.store.setPlaybackPreferences(nextPreferences);
    if (!mounted || _closed) {
      return;
    }
    final qualityChanged = nextPreferences.quality != _requestedQuality;
    _enhancement.setPreferences(nextPreferences.enhancement);
    setState(() {
      _speed = nextPreferences.speed;
      _requestedQuality = nextPreferences.quality;
      _autoAdvance = true;
      _danmakuEnabled = nextPreferences.danmaku;
      _preloadEnabled = true;
    });
    _danmaku.setEnabled(_danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (qualityChanged && _plan?.local != true) {
      await _retry(quality: nextPreferences.quality);
    }
  }

  Future<void> _toggleDanmaku() async {
    if (widget.detail.drama.source != 'hongguo') return;
    try {
      await _setPreferences(_preferences.copyWith(danmaku: !_danmakuEnabled));
    } catch (_) {
      _notice('弹幕偏好未能保存，请重试');
    }
  }

  Future<void> _retryDanmakuFromControls() async {
    try {
      _danmaku.retry();
      _menuRevision.value++;
    } catch (_) {
      _notice('弹幕重试失败，请稍后再试');
    }
  }

  Future<void> _submitDownloadSelection(DownloadSelection selection) async {
    if (!widget.repository.supportsDownloads ||
        !widget.store.canDownload ||
        widget.mediaId != null) {
      return;
    }
    final added = await widget.repository.enqueueDownloads(
      widget.detail,
      selection.episodes,
      quality: selection.quality,
    );
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DownloadsScreen(
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    final menuTheme = _showFullscreen ? AppTheme.dark : Theme.of(context);
    try {
      final index = await showDialog<int>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([
            _menuRevision,
            widget.store,
            _danmaku,
            _preloader,
          ]),
          builder: (_, _) => Theme(
            data: menuTheme,
            child: PlayerMenu(
              section: section,
              episodes: widget.detail.episodes,
              currentIndex: _index,
              preferences: _preferences,
              qualities: _plan?.qualities ?? [],
              actualQuality: _plan?.quality ?? 0,
              local: _plan?.local == true,
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              mobile: _mobile,
              onEpisode: (index) => Navigator.pop(menuContext, index),
              onPreferences: _setPreferences,
              showDanmaku: widget.detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preloadStatus: _preloader.status,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
              onFavorite: () =>
                  widget.store.toggleFavorite(widget.detail.drama),
            ),
          ),
        ),
      );
      if (mounted && !_closed && index != null && index != _index) {
        await _session.play(index);
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已调整播放位置');
    final ticket = ++_seekSequence;
    final generation = _generation;
    _danmaku.beginSeek();
    _enhancement.ignorePerformance();
    var succeeded = false;
    try {
      await _player.seek(target);
      succeeded = true;
    } catch (_) {
      _notice('跳转失败，请重试');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        _danmaku.endSeek(succeeded ? target : _player.state.position);
      }
    }
  }

  @override
  bool get closed => _closed;

  @override
  bool get foreground => _foreground;

  @override
  bool get localOnly => widget.localOnly;

  @override
  bool get allowOnlineFallback => widget.allowOnlineFallback;

  @override
  bool get playerPlaying => _player.state.playing;

  @override
  bool get playerCompleted => _player.state.completed;

  @override
  double get playheadSeconds => _player.state.position.inMilliseconds / 1000;

  @override
  Future<void> saveProgress({bool flush = false}) =>
      _saveProgress(flush: flush);

  @override
  void cancelInteractions() => _interactions.cancel();

  @override
  void resetSeekSequence() => _seekSequence++;

  @override
  void suspendEnhancement() => _enhancement.suspend();

  @override
  Future<void> beforeMedia() => _enhancement.beforeMedia();

  @override
  Future<void> stopPlayer() => _player.stop();

  @override
  Future<void> openPlan(
    PlaybackPlan plan, {
    required double position,
    required bool play,
  }) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      if (isAndroidPlatform) {
        await platform.setProperty('hwdec', 'auto-safe');
        await platform.setProperty('hwdec-codecs', 'all');
        await platform.setProperty('vd-lavc-skiploopfilter', 'nonkey');
        await platform.setProperty('vd-lavc-threads', '4');
        await platform.setProperty('vd-lavc-fast', 'yes');
        await platform.setProperty('video-sync', 'audio');
        await platform.setProperty('framedrop', 'vo');
      } else if (isWindowsPlatform) {
        await platform.setProperty('hwdec', 'd3d11va-copy');
      }
      await platform.setProperty(
        'demuxer-lavf-o',
        [
          'seg_max_retry=3',
          'strict=experimental',
          'allowed_extensions=ALL',
          plan.local
              ? 'protocol_whitelist=[file,crypto,data]'
              : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
          if (plan.decryptionKey.isNotEmpty)
            'decryption_key=${plan.decryptionKey}',
        ].join(','),
      );
      await platform.setProperty('network-timeout', '20');
    }
    await _player.open(
      Media(
        plan.url,
        httpHeaders: plan.headers,
        start: position > 0
            ? Duration(milliseconds: (position * 1000).round())
            : null,
      ),
      play: play,
    );
  }

  @override
  void mediaReady() => _enhancement.mediaReady();

  @override
  Future<void> applySpeed() => _interactions.applySpeed();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  void setDanmakuPlan(PlaybackPlan? plan) => _danmaku.setPlan(plan);

  @override
  void syncDanmaku() => _syncDanmaku();

  @override
  void acknowledgeHandoff() => _acknowledgeHandoff();

  @override
  void bumpMenu() => _menuRevision.value++;

  @override
  void attachLan(PlayerSessionController controller) =>
      _attachLanPlayback(controller);

  @override
  void detachLan() {
    widget.lan?.detachPlayback(_session.lanIdentity);
  }

  @override
  void resetHealth() => _health.reset();

  @override
  void queueRecovery(String reason) => _queueRecovery(reason: reason);

  @override
  void cancelPendingRecovery() {
    _recoveryScheduler.cancel();
    _recoveryScheduler.clearPending();
  }

  @override
  void failHandoff(String message) => widget.handoff?.fail(message);

  @override
  void releaseHandoffOwnership() => _handoffOwned = false;

  @override
  void dispose() {
    _closed = true;
    final enhancementClosed = _enhancement.close();
    _session.removeListener(_sessionChanged);
    _session.dispose();
    widget.lan?.detachPlayback(_session.lanIdentity);
    widget.handoff?.fail('接收端已退出播放');
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _health.dispose();
    _recoveryScheduler.dispose();
    _pictureInPictureExitTimer?.cancel();
    if (_pictureInPictureHandlerInstalled) {
      AppDevice.channel.setMethodCallHandler(null);
    }
    _interactions.dispose();
    _playerFocus.dispose();
    _menuRevision.dispose();
    _progress.removeListener(_progressChanged);
    unawaited(_saveProgress(flush: true).whenComplete(_progress.dispose));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(_session.releaseSession('screen_dispose'));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _session.operations.catchError((Object _) {}).then((_) async {
        await _interactions.pendingRates.catchError((Object _) {});
        await enhancementClosed.catchError((Object _) {});
        await _player.dispose();
      }),
    );
    if (_desktop) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(),
                ))
            .catchError((Object _) {}),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  void _back() {
    if (_showFullscreen) {
      _rotate();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final fullscreen = _showFullscreen;
          final overlayBrightness = fullscreen
              ? Brightness.dark
              : Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(overlayBrightness),
            child: _buildPlayer(context),
          );
        },
      ),
    );
  }

  // —— 布局（player_layout.dart）与底部面板（player_panel.dart）
  // 通过同库 extension 提供组件方法 ——

  /// 播放页信息栏：宽屏贴在播放器右侧，紧凑端落在视频下方。
  /// 底色与 Animeko 侧栏一致（surfaceContainerLow + 分隔线）。
  Widget _sidePanel() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _sideTabs(),
            Divider(height: 1, thickness: 1, color: colors.outlineVariant),
            Expanded(
              child: switch (_mobileTab) {
                0 => _episodePanel(compact: false),
                1 => _mobileSynopsis(),
                _ => _mobileDownload(),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideTabs() => SizedBox(
    height: 46,
    child: Row(
      children: [
        _mobileTabButton(0, '选集'),
        _mobileTabButton(1, '简介'),
        _mobileTabButton(2, '下载'),
      ],
    ),
  );

  Widget _mobileTabButton(int value, String label) {
    final selected = _mobileTab == value;
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _mobileTab = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onSurface : colors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileSynopsis() {
    final drama = widget.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        releaseLabelOf(drama.releaseStatus),
      if (drama.category.isNotEmpty) drama.category,
    ];
    final body = drama.description.trim().isEmpty ? '暂无简介' : drama.description;
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                height: 123,
                child: DramaCover(drama: drama, repository: widget.repository),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta.join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                    if (drama.onlineDate.isNotEmpty ||
                        drama.heat.isNotEmpty ||
                        drama.views.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (drama.onlineDate.isNotEmpty)
                            '${drama.onlineDate} 上线',
                          if (drama.heat.isNotEmpty) '热度 ${drama.heat}',
                          if (drama.views.isNotEmpty) '播放 ${drama.views}',
                        ].join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _mobileFollowControl(drama),
          if (drama.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in drama.tags.take(12))
                  Chip(label: Text(tag), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(height: 1.55)),
          if (widget.detail.warning.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(widget.detail.warning, style: TextStyle(color: colors.error)),
          ],
        ],
      ),
    );
  }

  Widget _mobileFollowControl(Drama drama) {
    final state = widget.store.following(drama.id);
    return PopupMenuButton<String>(
      key: const ValueKey('player-follow-status'),
      tooltip: '追剧与观看状态',
      onSelected: (value) async {
        if (value == 'remove') {
          await saveUserChange(
            context,
            () => widget.store.toggleFavorite(drama),
          );
        } else {
          final status = FollowStatus.values.firstWhere(
            (status) => status.name == value,
          );
          await saveUserChange(
            context,
            () => widget.store.setFollowStatus(drama, status),
          );
        }
        if (mounted && !_closed) setState(() {});
      },
      itemBuilder: (_) => [
        for (final status in FollowStatus.values)
          CheckedPopupMenuItem(
            value: status.name,
            checked: state?.status == status,
            child: Text(status.label),
          ),
        if (state != null)
          const PopupMenuItem(value: 'remove', child: Text('取消追剧')),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: state == null
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              state == null
                  ? Icons.bookmark_add_outlined
                  : Icons.bookmark_rounded,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(state?.label ?? '加入追剧'),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _mobileDownload() {
    final colors = Theme.of(context).colorScheme;
    if (!widget.repository.supportsDownloads || !widget.store.canDownload) {
      return ColoredBox(
        color: colors.surfaceContainerLow,
        child: const StatusPanel(
          title: '下载不可用',
          message: '当前用户或当前环境未开放本地下载。',
          icon: Icons.download_outlined,
        ),
      );
    }
    return DownloadPicker(
      detail: widget.detail,
      preferences: widget.store.downloadPreferences,
      embedded: true,
      onSubmit: _submitDownloadSelection,
    );
  }

  Widget _episodePanel({bool compact = false}) => ColoredBox(
    color: Colors.transparent,
    child: PlayerEpisodeGrid(
      episodes: widget.detail.episodes,
      currentIndex: _index,
      compact: compact,
      title: compact ? '剧集' : '选集',
      note:
          widget.detail.drama.releaseStatus.isNotEmpty &&
              widget.detail.drama.releaseStatus != 'unknown'
          ? releaseLabelOf(widget.detail.drama.releaseStatus)
          : '',
      onSelected: (index) => _session.play(index),
    ),
  );
}
