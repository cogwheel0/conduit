import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Gap between the button and the composer's top edge.
const double kChatScrollToLatestComposerGap = 12;

/// Clear space around the button that the page background fades across.
const double kChatScrollToLatestHaloInset = 12;

/// Soft strip above the button where the deepened scroll edge eases out.
const double kChatScrollToLatestEdgeSoftHeight = 24;

/// Floating "jump to the latest message" control that rests just above the
/// composer.
///
/// It springs in and out with a fade and a short rise, critically damped so
/// it never overshoots, and from wherever it is when [visible] flips, so a
/// quick scroll back and forth reverses it smoothly. Reduce Motion keeps
/// only the fade.
///
/// Place it full width with its bottom on the composer's top edge. While it
/// shows, the scroll edge above the composer deepens to hold it: opaque to
/// the button's middle, then easing out just above it, so the transcript
/// fades away behind the button rather than running under it. A soft disc of
/// the page background sits right under the button, so its Liquid Glass
/// shows a clean surface instead of refracting text.
///
/// With [presence], the host draws that deeper edge itself (for example by
/// raising its own soft scroll edge by the button's height), and the widget
/// reports how far in the button is, from 0 to 1, on every frame.
class ChatScrollToLatestButton extends StatefulWidget {
  const ChatScrollToLatestButton({
    super.key,
    required this.visible,
    required this.dimension,
    required this.child,
    this.presence,
  });

  /// Whether the button is wanted. The widget animates toward this.
  final bool visible;

  /// The button's diameter.
  final double dimension;

  /// The button itself.
  final Widget child;

  /// Receives the button's presence, 0 (gone) to 1 (resting), each frame.
  /// When given, the widget leaves the deeper scroll edge to the host.
  final ValueNotifier<double>? presence;

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
  )..addListener(_reportPresence);

  @override
  void initState() {
    super.initState();
    _reportPresence();
  }

  /// Runs while the spring ticks, before the frame builds, so the host may
  /// rebuild from it in the same frame.
  void _reportPresence() {
    widget.presence?.value = _presence.value.clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant ChatScrollToLatestButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.presence, widget.presence)) {
      oldWidget.presence?.value = 0;
      _reportPresence();
    }
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

  /// The deepened edge: opaque from the composer to the button's middle,
  /// then a cosine ease to clear above the button.
  LinearGradient _edgeGradient(Color background, double height) {
    final solidStop =
        (kChatScrollToLatestComposerGap + widget.dimension / 2) / height;
    const steps = 8;
    return LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        background,
        background,
        for (var i = 1; i <= steps; i++)
          background.withValues(
            alpha: background.a * 0.5 * (1 + math.cos(math.pi * i / steps)),
          ),
      ],
      stops: [
        0,
        solidStop,
        for (var i = 1; i <= steps; i++)
          solidStop + (1 - solidStop) * i / steps,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final haloExtent = widget.dimension + kChatScrollToLatestHaloInset * 2;
    final edgeHeight =
        kChatScrollToLatestComposerGap +
        widget.dimension +
        kChatScrollToLatestEdgeSoftHeight;
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

    final button = SizedBox.square(
      dimension: haloExtent,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: IgnorePointer(child: halo)),
          widget.child,
        ],
      ),
    );
    final edge = IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: _edgeGradient(background, edgeHeight),
        ),
      ),
    );

    return SizedBox(
      height: edgeHeight,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _presence,
        builder: (context, _) {
          final presence = _presence.value.clamp(0.0, 1.0);
          if (presence <= 0.001 && !widget.visible) {
            // Fully gone: drop the native button rather than keep an
            // invisible platform view in the scene.
            return const SizedBox.shrink();
          }
          final rise = context.reduceMotion
              ? 0.0
              : (1 - presence) * ChatScrollToLatestButton.riseDistance;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (widget.presence == null)
                Positioned.fill(
                  child: Opacity(opacity: presence, child: edge),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom:
                    kChatScrollToLatestComposerGap -
                    kChatScrollToLatestHaloInset,
                child: Center(
                  child: IgnorePointer(
                    ignoring: !widget.visible,
                    child: Opacity(
                      opacity: presence,
                      child: Transform.translate(
                        offset: Offset(0, rise),
                        child: button,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
