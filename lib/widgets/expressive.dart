import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// M3 Expressive 基础件：形状图标、按压形变卡片与自适应双列。
/// 参照 Kazumi 的 `my_space_view.dart`，动效遵守 disableAnimations。
class ShapeKind {
  const ShapeKind(this._path);

  final Path _path;

  static final sun = ShapeKind(MaterialShapes.sunny.toPath());
  static final clover = ShapeKind(MaterialShapes.clover4Leaf.toPath());
  static final cookie = ShapeKind(MaterialShapes.cookie7Sided.toPath());
  static final flower = ShapeKind(MaterialShapes.flower.toPath());
}

/// 用 Material 表达性形状裁切的图标块，纯装饰，对读屏隐藏。
class ShapeIcon extends StatelessWidget {
  const ShapeIcon({
    super.key,
    required this.shape,
    required this.icon,
    required this.size,
    required this.color,
    required this.foreground,
  });

  final ShapeKind shape;
  final IconData icon;
  final double size;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipPath(
      clipper: _ShapeClipper(shape),
      child: ColoredBox(
        color: color,
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, color: foreground, size: size * .44),
        ),
      ),
    ),
  );
}

class _ShapeClipper extends CustomClipper<Path> {
  const _ShapeClipper(this.shape);
  final ShapeKind shape;

  @override
  Path getClip(Size size) => shape._path.transform(
    Matrix4.diagonal3Values(size.width, size.height, 1).storage,
  );

  @override
  bool shouldReclip(_ShapeClipper oldClipper) => oldClipper.shape != shape;
}

/// 表达性按压缩放（scale .97 + 圆角 28→16），整块可点。
class ExpressiveAction extends StatefulWidget {
  const ExpressiveAction({
    super.key,
    required this.color,
    required this.foreground,
    required this.onTap,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(28)),
  });

  final Color color;
  final Color foreground;
  final VoidCallback? onTap;
  final Widget child;
  final BorderRadius radius;

  @override
  State<ExpressiveAction> createState() => _ExpressiveActionState();
}

class _ExpressiveActionState extends State<ExpressiveAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reducedMotion
        ? Duration.zero
        : Duration(milliseconds: _pressed ? 150 : 300);
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      child: AnimatedScale(
        scale: _pressed && !reducedMotion ? .97 : 1,
        duration: duration,
        curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: _pressed
                ? BorderRadius.circular(16)
                : widget.radius,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              onHighlightChanged: (value) => setState(() => _pressed = value),
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return widget.foreground.withValues(alpha: .10);
                }
                if (states.contains(WidgetState.focused)) {
                  return widget.foreground.withValues(alpha: .12);
                }
                if (states.contains(WidgetState.hovered)) {
                  return widget.foreground.withValues(alpha: .08);
                }
                return null;
              }),
              child: IconTheme.merge(
                data: IconThemeData(color: widget.foreground),
                child: DefaultTextStyle.merge(
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: widget.foreground),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽屏左右并排、窄屏上下堆叠。
class AdaptivePair extends StatelessWidget {
  const AdaptivePair({
    super.key,
    required this.first,
    required this.second,
    required this.stack,
    required this.gap,
  });

  final Widget first;
  final Widget second;
  final bool stack;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (stack) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [first, SizedBox(height: gap), second],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: first),
          SizedBox(width: gap),
          Expanded(child: second),
        ],
      ),
    );
  }
}
