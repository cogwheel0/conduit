import 'package:flutter/material.dart';

import '../../../shared/widgets/middle_ellipsis_text.dart';

/// Displays a chat title that reveals characters with a streaming animation
/// whenever the title changes.
class StreamingTitleText extends StatefulWidget {
  const StreamingTitleText({
    super.key,
    required this.title,
    required this.style,
    this.cursorColor,
    this.cursorWidth = 2,
    this.cursorHeight,
    this.onAnimationComplete,
  });

  /// The title that should be rendered. When this value changes the widget
  /// replays the streaming animation.
  final String title;

  /// Text style used for the title.
  final TextStyle style;

  /// Optional cursor color while streaming. Defaults to the text color.
  final Color? cursorColor;

  /// Width of the animated cursor while the title is streaming.
  final double cursorWidth;

  /// Optional cursor height override. When null we use the font size's height.
  final double? cursorHeight;

  /// Optional callback fired after the streaming animation finishes.
  final VoidCallback? onAnimationComplete;

  @override
  State<StreamingTitleText> createState() => _StreamingTitleTextState();
}

class _StreamingTitleTextState extends State<StreamingTitleText>
    with TickerProviderStateMixin {
  late final AnimationController _revealController;
  late final AnimationController _cursorController;
  late Animation<double> _cursorOpacity;
  String _activeTitle = '';

  @override
  void initState() {
    super.initState();
    _activeTitle = widget.title;

    _revealController =
        AnimationController(vsync: this, duration: _durationFor(widget.title))
          ..addListener(() {
            setState(() {});
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _cursorController.stop();
              widget.onAnimationComplete?.call();
            }
          });

    _cursorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _cursorOpacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutQuart)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInQuart)),
        weight: 50,
      ),
    ]).animate(_cursorController);

    if (_activeTitle.isNotEmpty) {
      // Skip the animation when mounting with an existing title.
      _revealController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant StreamingTitleText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title) {
      _activeTitle = widget.title;
      _revealController.duration = _durationFor(widget.title);
      if (_activeTitle.isEmpty) {
        _revealController.value = 0.0;
        _cursorController.stop();
      } else {
        _cursorController
          ..reset()
          ..repeat(reverse: true);
        _revealController.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    _cursorController.dispose();
    _revealController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_activeTitle.isEmpty) {
      return const SizedBox.shrink();
    }

    final characters = _activeTitle.characters;
    final int totalGlyphs = characters.length;
    final double clampedProgress = _revealController.value.clamp(0.0, 1.0);
    int revealedGlyphs = (clampedProgress * totalGlyphs).floor();
    if (revealedGlyphs > totalGlyphs) {
      revealedGlyphs = totalGlyphs;
    }
    final String visibleText = characters.take(revealedGlyphs).toString();

    final bool isAnimating =
        _revealController.isAnimating && revealedGlyphs < totalGlyphs;

    final Color cursorColor =
        widget.cursorColor ??
        widget.style.color ??
        Theme.of(context).colorScheme.primary;

    final double cursorHeight =
        widget.cursorHeight ??
        (widget.style.fontSize != null
            ? widget.style.fontSize! * (widget.style.height ?? 1.1)
            : 18.0);

    // When animation is complete, use middle ellipsis for overflow.
    // During animation, show partial text with standard Text widget.
    final bool animationComplete = revealedGlyphs >= totalGlyphs;

    // Use middle ellipsis when animation is complete
    if (animationComplete) {
      return MiddleEllipsisText(
        _activeTitle,
        style: widget.style,
        textAlign: TextAlign.center,
        semanticsLabel: _activeTitle,
      );
    }

    // During animation, use IntrinsicWidth to size the row to the text,
    // then clip any overflow from the cursor
    return ClipRect(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              visibleText,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              textAlign: TextAlign.center,
              style: widget.style,
            ),
          ),
          if (isAnimating)
            FadeTransition(
              opacity: _cursorOpacity,
              child: Container(
                width: widget.cursorWidth,
                height: cursorHeight,
                margin: const EdgeInsets.only(left: 2),
                decoration: BoxDecoration(
                  color: cursorColor,
                  borderRadius: BorderRadius.circular(widget.cursorWidth),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Duration _durationFor(String value) {
    if (value.isEmpty) {
      return const Duration(milliseconds: 200);
    }
    final int glyphs = value.characters.length;
    final int millis = (glyphs * 28).clamp(360, 1400).toInt();
    return Duration(milliseconds: millis);
  }
}
