import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Gap between the button and the composer's top edge.
const double kChatScrollToLatestComposerGap = 12;

/// Floating "jump to the latest message" control that rests just above the
/// composer.
///
/// It springs in and out with a fade and a short rise, critically damped so
/// it never overshoots, and from wherever it is when [visible] flips, so a
/// quick scroll back and forth reverses it smoothly. Reduce Motion keeps
/// only the fade.
///
/// Place it full width with its bottom on the composer's top edge. Like the
/// composer, it floats over the transcript, which keeps scrolling under its
/// glass.
class ChatScrollToLatestButton extends StatefulWidget {
  const ChatScrollToLatestButton({
    super.key,
    required this.visible,
    required this.dimension,
    required this.child,
    this.quickExit = false,
  });

  /// Whether the button is wanted. The widget animates toward this.
  final bool visible;

  /// Whether a hide happening now should be immediate rather than on the
  /// spring, for when the user has just sent a message and the transcript is
  /// about to move under the button to bring the new turn up. So it goes in
  /// the frame the send is shown in.
  final bool quickExit;

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

  /// A send took the button away at once (see
  /// [ChatScrollToLatestButton.quickExit]).
  bool _droppedForSend = false;

  @override
  void didUpdateWidget(covariant ChatScrollToLatestButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    final target = widget.visible ? 1.0 : 0.0;
    _droppedForSend = false;
    if (!widget.visible && widget.quickExit) {
      _presence.stop();
      _droppedForSend = true;
      // The host hears of it after this frame: never change its state from
      // inside a build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.visible) _presence.value = 0;
      });
      return;
    }
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
    return SizedBox(
      height: kChatScrollToLatestComposerGap + widget.dimension,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _presence,
        builder: (context, _) {
          final presence = _presence.value.clamp(0.0, 1.0);
          if ((presence <= 0.001 || _droppedForSend) && !widget.visible) {
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
              Positioned(
                left: 0,
                right: 0,
                bottom: kChatScrollToLatestComposerGap,
                child: Center(
                  child: IgnorePointer(
                    ignoring: !widget.visible,
                    child: Opacity(
                      opacity: presence,
                      child: Transform.translate(
                        offset: Offset(0, rise),
                        child: widget.child,
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
