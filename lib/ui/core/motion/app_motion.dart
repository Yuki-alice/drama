import 'package:flutter/material.dart';

import '../tokens/app_tokens.dart';

/// 按下缩放（Apple 的控件在所有可点内容上都有这个微缩放）。
///
/// **为什么不用 `InkWell`**：墨水扩散在玻璃面上是噪点（主题已设 `NoSplash`），
/// 而内容层要的是**尺度**反馈——卡片「陷进去一点」而不是「弹一下」。
/// 这个包装同时承担了项目里唯一一致的按下反馈。
///
/// **可访问性**：包一层 [Semantics]（`button: true` + `label`），
/// 读屏器才会把内容层卡片识别成可点。此前裸 `GestureDetector` 的卡片
/// 对 VoiceOver 是完全透明的。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.borderRadius,
    this.semanticLabel,
    this.semanticHint,
    this.excludeSemantics = false,
  });

  final Widget child;

  /// 为 null 时只做视觉包装，不响应点击（也不注册语义按钮）。
  final VoidCallback? onTap;

  final VoidCallback? onLongPress;

  /// 按下时的目标缩放。0.97 对应「陷进去一点」；小图块用 0.94–0.96。
  final double scale;

  /// 裁切圆角（连续曲率）。为 null 时不裁切。
  final double? borderRadius;

  /// 读屏器朗读的标签；为 null 时由子树文字合成。
  final String? semanticLabel;

  /// 读屏器补充提示（例如「双击查看详情」）。
  final String? semanticHint;

  /// 子树已有自己的语义（例如内部是 [ListTile]）时置 true，
  /// 避免出现两层嵌套的按钮语义。
  final bool excludeSemantics;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value || !mounted) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final target = (_down && !reduce && enabled) ? widget.scale : 1.0;

    Widget child = widget.child;
    if (widget.borderRadius != null) {
      child = AppRadii.clip(radius: widget.borderRadius!, child: child);
    }

    child = AnimatedScale(
      scale: target,
      duration: AppMotion.fast,
      curve: AppMotion.settle,
      child: child,
    );

    if (!enabled) return child;

    return Semantics(
      button: true,
      enabled: true,
      label: widget.semanticLabel,
      hint: widget.semanticHint,
      excludeSemantics: widget.excludeSemantics,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapCancel: () => _set(false),
        onTapUp: (_) => _set(false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: child,
      ),
    );
  }
}

/// 首屏元素逐个浮起（货架入场）。
///
/// 只在**第一次出现**时播放；同一 State 里播过之后直接渲染终态，
/// 避免滚动来回时反复重播变成噪音。
///
/// `disableAnimations`（减弱动效）下**完全不建动画**，直接交子树——
/// 这是 HIG `motion.md`「动效永远是可选的」的落地，不是可有可无的优化。
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.index = 0,
    this.step = 40,
    this.maxStagger = 6,
  });

  final Widget child;

  /// 序号决定延迟（毫秒 = index * step）。
  final int index;
  final int step;

  /// 超过这个序号不再延迟（长列表尾部不该等 3 秒）。
  final int maxStagger;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  int get _delayMs => widget.index.clamp(0, widget.maxStagger) * widget.step;

  /// 首帧不透明度/位移在整段动画里从哪个比例开始——把「等多久」折进同一条
  /// 动画，省掉一个需要手动管理的定时器。
  double get _lead {
    final total = _delayMs + AppMotion.slow.inMilliseconds;
    return total == 0 ? 0 : _delayMs / total;
  }

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _delayMs + AppMotion.slow.inMilliseconds),
    value: 0,
  );

  /// 只建一次：`CurvedAnimation` 每次构造都会往父动画挂一个监听。
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Interval(_lead, 1, curve: AppMotion.settle),
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, .04),
    end: Offset.zero,
  ).animate(_curved);

  bool _decided = false;
  bool _played = false;

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_decided) {
      _decided = true;
      // 减弱动效的判断放在首帧 build 而不是 initState：Reveal 会被塞进
      // sliver 的布局回调里，那时候还没登记 MediaQuery 依赖，读它会抛断言。
      final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      if (!reduce) {
        _played = true;
        _controller.forward();
      }
    }
    if (!_played) return widget.child;
    return FadeTransition(
      opacity: _curved,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// 发丝进度线。
///
/// 规格来自设计规范：**2px 轨道 + 墨色填充**（画面之上的进度用白）。
/// 不是 4px 圆头胶囊——圆头把「一条线」变成「一根管子」，
/// 在密集列表里会显重。
///
/// 支持两种用法：
/// - [fraction] 给定比例（追剧行 / 卡片角标）；
/// - 拖拽交互（播放器）由外层传入 [fraction] 与手势包装。
class HairlineProgress extends StatelessWidget {
  const HairlineProgress({
    super.key,
    required this.fraction,
    this.color,
    this.track,
    this.height = 2,
  });

  final double fraction;

  /// 已完成段颜色；默认取 [AppColors.textPrimary]（墨——进度即状态，
  /// 无彩色色板下状态用灰度与字重表达）。
  final Color? color;

  /// 未完成段底色；默认取 [AppColors.divider]（发丝线）。
  final Color? track;

  /// 线宽。规范值 2；播放器按住拖拽时加到 4 以示「可拖」。
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: track ?? colors.divider),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: fraction.clamp(0.0, 1.0),
              child: ColoredBox(color: color ?? colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
