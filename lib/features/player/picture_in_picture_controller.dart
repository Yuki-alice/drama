import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:duanju_app/app/app_layout.dart';

/// 画中画的状态机与平台调用。
///
/// 从 `_PlayerScreenState` 抽出的部分只做三件事：状态迁移、平台通道调用、
/// 以及"退出画中画要延迟 700ms 再决定是否暂停"的时序。是否可见/是否支持
/// 之外的副作用（暂停播放、刷新弹幕、清预载）由屏幕通过回调接入——
/// 这些依赖播放器实例，放在这里会把控制器变成第二个 State。
class PictureInPictureController extends ChangeNotifier {
  PictureInPictureController({
    required this.onVisibilityChanged,
    this.exitGrace = const Duration(milliseconds: 700),
    this.confirmGrace = const Duration(seconds: 2),
  });

  /// 可见性变化回调：参数表示"是否应视为前台可见"。
  final void Function({required bool delayHiddenPause}) onVisibilityChanged;

  /// 系统上报退出后等待多久再判定"确实退出了"。
  final Duration exitGrace;

  /// 请求进入但一直没变 active 时，多久后清掉 requested 标记。
  final Duration confirmGrace;

  bool _supported = false;
  bool _active = false;
  bool _requested = false;
  bool _handlerInstalled = false;
  bool _disposed = false;
  Timer? _exitTimer;
  Timer? _confirmTimer;

  bool get supported => _supported;
  bool get active => _active;
  bool get requested => _requested;

  /// 画中画正在（或即将）占据屏幕时，播放器仍需保持前台语义。
  bool get visible => _active || _requested;

  /// 是否应展示画中画入口。
  bool get canUse =>
      defaultTargetPlatform == TargetPlatform.android && _supported;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _exitTimer?.cancel();
    _confirmTimer?.cancel();
    super.dispose();
  }

  /// 安装平台回调并读取初始状态；非 Android 直接返回。
  Future<void> install() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    AppDevice.channel.setMethodCallHandler((call) async {
      if (call.method != 'pictureInPictureChanged') return;
      final arguments = call.arguments;
      final isActive = arguments is Map && arguments['active'] == true;
      updateStatus(active: isActive, delayHiddenPause: !isActive);
    });
    await refresh();
  }

  /// 重新向平台查询状态；插件缺失时按"不支持"处理。
  Future<void> refresh() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (_disposed) return;
      updateStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (!_disposed) updateStatus(supported: false, active: false);
    } on MissingPluginException {
      if (!_disposed) updateStatus(supported: false, active: false);
    }
  }

  /// 合并一次状态更新。未显式给出的字段沿用旧值；
  /// active 变为 true 时自动清掉 requested（已生效，无需再等）。
  void updateStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _supported;
    final nextActive = active ?? _active;
    final nextRequested = requested ?? (nextActive ? false : _requested);
    if (nextSupported == _supported &&
        nextActive == _active &&
        nextRequested == _requested) {
      // 状态没变也要让屏幕重新评估可见性（例如从后台回到前台）。
      onVisibilityChanged(delayHiddenPause: delayHiddenPause);
      return;
    }
    _supported = nextSupported;
    _active = nextActive;
    _requested = nextRequested;
    notifyListeners();
    if (visible) {
      _exitTimer?.cancel();
      onVisibilityChanged(delayHiddenPause: false);
      return;
    }
    _exitTimer?.cancel();
    onVisibilityChanged(delayHiddenPause: delayHiddenPause);
    if (delayHiddenPause) {
      _exitTimer = Timer(exitGrace, () {
        if (!_disposed && !visible) {
          onVisibilityChanged(delayHiddenPause: true);
        }
      });
    }
  }

  /// 请求进入画中画。返回值表示调用后是否仍处于"待确认"。
  ///
  /// [width]/[height]/[sourceRect] 由屏幕按当前画面比例算出——那依赖
  /// RenderBox，控制器不碰布局。
  Future<bool> enter({
    required int width,
    required int height,
    Map<String, int>? sourceRect,
    required void Function(String message) onNotice,
  }) async {
    updateStatus(requested: true);
    final arguments = <String, int>{'width': width, 'height': height};
    if (sourceRect != null) arguments.addAll(sourceRect);
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      if (_disposed) return false;
      final isSupported = status?['supported'] == true;
      final isActive = status?['active'] == true;
      final isRequested = status?['requested'] == true;
      updateStatus(
        supported: isSupported,
        active: isActive,
        requested: isRequested && !isActive,
      );
      if (!isSupported || (!isActive && !isRequested)) {
        onNotice('当前设备不支持画中画');
        return false;
      }
      if (isRequested && !isActive) {
        _confirmTimer?.cancel();
        _confirmTimer = Timer(confirmGrace, () {
          if (!_disposed && _requested && !_active) {
            updateStatus(requested: false);
          }
        });
        return true;
      }
      return false;
    } on PlatformException {
      updateStatus(requested: false);
      onNotice('无法进入画中画，请检查系统权限');
      return false;
    } on MissingPluginException {
      updateStatus(supported: false, requested: false);
      onNotice('当前平台不支持画中画');
      return false;
    }
  }
}
