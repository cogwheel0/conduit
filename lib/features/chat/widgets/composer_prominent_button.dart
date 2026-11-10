import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';

import '../../../shared/theme/theme_extensions.dart';

/// The composer's prominent round action (Send, Stop, voice) on iOS: a
/// monochrome disc drawn in Flutter inside its full touch target.
///
/// UIKit's prominent glass button tints its highlighted state with the
/// system accent, which flashed blue on this monochrome control. This one
/// answers a touch the way a filled iOS button does without colour: the disc
/// shrinks slightly and its fill dims, on a critically damped spring that
/// follows the finger down and back up and can reverse at any point. Reduce
/// Motion keeps the dimming and drops the scale. It also costs no platform
/// view.
class ComposerProminentButton extends StatefulWidget {
  const ComposerProminentButton({
    super.key,
    required this.onPressed,
    required this.targetSize,
    required this.visualSize,
    required this.fill,
    required this.glyph,
    this.alignment = Alignment.center,
  });

  /// Null disables the button: a quiet grey disc that ignores touches.
  final VoidCallback? onPressed;

  /// The square touch target (44 pt or more).
  final double targetSize;

  /// The disc's diameter, drawn inside the target at [alignment].
  final double visualSize;

  /// The disc's colour while enabled.
  final Color fill;
  final Widget glyph;
  final AlignmentGeometry alignment;

  /// How far the disc shrinks while held, and how much of the page shows
  /// through its fill.
  static const double pressedScale = 0.9;
  static const double pressedDim = 0.2;

  /// Spring response for the press (critically damped).
  static const double pressResponse = 0.2;

  /// The disabled disc: a quiet tint of the label colour.
  static Color disabledFill(BuildContext context) =>
      context.conduitTheme.textPrimary.withValues(alpha: 0.1);

  @override
  State<ComposerProminentButton> createState() =>
      _ComposerProminentButtonState();
}

class _ComposerProminentButtonState extends State<ComposerProminentButton>
    with SingleTickerProviderStateMixin {
  /// 0 at rest, 1 fully pressed. Unbounded so the spring can carry it.
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );

  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: math
        .pow(2 * math.pi / ComposerProminentButton.pressResponse, 2)
        .toDouble(),
    ratio: 1,
  );

  bool get _enabled => widget.onPressed != null;

  void _setPressed(bool pressed) {
    final target = pressed ? 1.0 : 0.0;
    _press.animateWith(
      SpringSimulation(_spring, _press.value, target, _press.velocity),
    );
  }

  @override
  void didUpdateWidget(covariant ComposerProminentButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _press.value != 0) _press.value = 0;
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    final page = Theme.of(context).scaffoldBackgroundColor;
    final restFill = _enabled
        ? widget.fill
        : ComposerProminentButton.disabledFill(context);
    final disc = SizedBox.square(
      dimension: widget.visualSize,
      child: AnimatedBuilder(
        animation: _press,
        child: Center(child: widget.glyph),
        builder: (context, glyph) {
          final t = _press.value.clamp(0.0, 1.0);
          final fill = Color.lerp(
            restFill,
            page,
            ComposerProminentButton.pressedDim * t,
          )!;
          final scale = reduceMotion
              ? 1.0
              : 1 - (1 - ComposerProminentButton.pressedScale) * _press.value;
          return Transform.scale(
            scale: scale,
            child: DecoratedBox(
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              child: glyph,
            ),
          );
        },
      ),
    );
    // The press shows on touch-down, not after the tap recognizer's delay.
    return Listener(
      onPointerDown: _enabled ? (_) => _setPressed(true) : null,
      onPointerUp: _enabled ? (_) => _setPressed(false) : null,
      onPointerCancel: _enabled ? (_) => _setPressed(false) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: widget.targetSize,
          child: Align(alignment: widget.alignment, child: disc),
        ),
      ),
    );
  }
}
