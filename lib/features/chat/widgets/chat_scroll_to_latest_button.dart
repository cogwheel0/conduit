import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Gap between the button and the composer's top edge.
const double kChatScrollToLatestComposerGap = 12;

/// Clear space around the button that the page background fades across.
const double kChatScrollToLatestHaloInset = 12;

/// Floating "jump to the latest message" control that rests just above the
/// composer.
///
/// It springs in and out with a fade and a short rise, critically damped so
/// it never overshoots, and from wherever it is when [visible] flips, so a
/// quick scroll back and forth reverses it smoothly. Reduce Motion keeps
/// only the fade.
///
/// A soft disc of the page background sits under the button, so its Liquid
/// Glass shows a clean surface instead of refracting the transcript, and
/// nearby text fades out rather than running into its edge.
class ChatScrollToLatestButton extends StatefulWidget {
  const ChatScrollToLatestButton({
    super.key,
    required this.visible,
    required this.dimension,
    required this.child,
  });

  /// Whether the button is wanted. The widget animates toward this.
  final bool visible;

  /// The button's diameter.
  final double dimension;

  /// The button itself.
  final Widget child;

  /// Critically damped, settling in roughly a third of a second.
  static final SpringDescription spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 380,
    ratio: 1,
  );

  /// How far below its resting place the button starts its rise.
  static const double riseDistance = 10;

  @override
  State<ChatScrollToLatestButton> createState() =>
      _ChatScrollToLatestButtonState();
}

class _ChatScrollToLatestButtonState extends State<ChatScrollToLatestButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _presence = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant ChatScrollToLatestButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    final target = widget.visible ? 1.0 : 0.0;
    if (context.reduceMotion) {
      _presence.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
      return;
    }
    _presence
        .animateWith(
          SpringSimulation(
            ChatScrollToLatestButton.spring,
            _presence.value,
            target,
            _presence.velocity,
          ),
        )
        // A spring stops within its tolerance; land exactly on the target.
        .then((_) {
          if (mounted && widget.visible == (target == 1)) {
            _presence.value = target;
          }
        });
  }

  @override
  void dispose() {
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final haloExtent = widget.dimension + kChatScrollToLatestHaloInset * 2;
    final background = context.conduitTheme.surfaceBackground;
    final halo = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            background,
            background,
            background.withValues(alpha: background.a * 0.6),
            background.withValues(alpha: 0),
          ],
          stops: [0, (widget.dimension / 2 + 2) / (haloExtent / 2), 0.84, 1],
        ),
      ),
    );

    return AnimatedBuilder(
      animation: _presence,
      child: SizedBox.square(
        dimension: haloExtent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(child: IgnorePointer(child: halo)),
            widget.child,
          ],
        ),
      ),
      builder: (context, child) {
        final presence = _presence.value.clamp(0.0, 1.0);
        if (presence <= 0.001 && !widget.visible) {
          // Fully gone: drop the native button rather than keep an invisible
          // platform view in the scene.
          return SizedBox.square(dimension: haloExtent);
        }
        final rise = context.reduceMotion
            ? 0.0
            : (1 - presence) * ChatScrollToLatestButton.riseDistance;
        return IgnorePointer(
          ignoring: !widget.visible,
          child: Opacity(
            opacity: presence,
            child: Transform.translate(offset: Offset(0, rise), child: child),
          ),
        );
      },
    );
  }
}
