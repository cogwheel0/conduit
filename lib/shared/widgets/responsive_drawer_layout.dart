import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import '../../shared/theme/theme_extensions.dart';

/// A responsive layout that shows a persistent drawer on tablets (side-by-side)
/// and an overlay drawer on mobile devices.
///
/// On tablets (shortestSide >= 600), the drawer is always visible alongside
/// the content. On mobile, it behaves like a standard slide drawer.
class ResponsiveDrawerLayout extends StatefulWidget {
  final Widget child;
  final Widget drawer;

  // Mobile-specific configuration
  final double maxFraction; // 0..1 of screen width for mobile drawer
  final double edgeFraction; // 0..1 active edge width for open gesture
  final double settleFraction; // threshold to settle open on release
  final Duration duration;
  final Curve curve;
  final Color? scrimColor;
  final bool pushContent;
  final double contentScaleDelta;
  final double contentBlurSigma;
  final VoidCallback? onOpenStart;

  // Tablet-specific configuration
  final double tabletDrawerWidth; // Fixed width for tablet drawer

  const ResponsiveDrawerLayout({
    super.key,
    required this.child,
    required this.drawer,
    this.maxFraction = 0.84,
    this.edgeFraction = 0.5,
    this.settleFraction = 0.12,
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.fastOutSlowIn,
    this.scrimColor,
    this.pushContent = true,
    this.contentScaleDelta = 0.02,
    this.contentBlurSigma = 2.0,
    this.onOpenStart,
    this.tabletDrawerWidth = 320.0,
  });

  static ResponsiveDrawerLayoutState? of(BuildContext context) =>
      context.findAncestorStateOfType<ResponsiveDrawerLayoutState>();

  @override
  State<ResponsiveDrawerLayout> createState() => ResponsiveDrawerLayoutState();
}

class ResponsiveDrawerLayoutState extends State<ResponsiveDrawerLayout>
    with SingleTickerProviderStateMixin {
  AnimationController? _controllerInstance;

  AnimationController get _controller {
    return _controllerInstance ??= AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 0.0,
    );
  }

  bool _isTablet(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return size.shortestSide >= 600;
  }

  double get _panelWidth =>
      (MediaQuery.of(context).size.width * widget.maxFraction).clamp(
        280.0,
        520.0,
      );

  double get _edgeWidth =>
      MediaQuery.of(context).size.width * widget.edgeFraction;

  bool get isOpen => _controller.value == 1.0;

  Future<void> _animateTo(
    double target, {
    double velocity = 0.0,
    bool? easeOut,
  }) async {
    final current = _controller.value;
    final distance = (current - target).abs().clamp(0.0, 1.0);
    final baseMs = widget.duration.inMilliseconds;
    final normSpeed = (velocity.abs() / (_panelWidth + 0.001)).clamp(0.0, 4.0);
    final ms = (baseMs * distance / (1.0 + 1.5 * normSpeed))
        .clamp(90, baseMs)
        .round();
    final bool useEaseOut = easeOut ?? (target > current);
    final curve = useEaseOut
        ? (normSpeed > 0.5 ? Curves.linearToEaseOut : Curves.easeOutCubic)
        : (normSpeed > 0.5 ? Curves.easeInToLinear : Curves.easeInCubic);
    await _controller.animateTo(
      target,
      duration: Duration(milliseconds: ms),
      curve: curve,
    );
  }

  void open({double velocity = 0.0}) {
    // Only animate on mobile; on tablet, drawer is always visible
    if (_isTablet(context)) return;

    try {
      widget.onOpenStart?.call();
    } catch (_) {}
    _dismissKeyboard();
    _animateTo(1.0, velocity: velocity);
  }

  void close({double velocity = 0.0}) {
    // Only animate on mobile; on tablet, drawer is always visible
    if (_isTablet(context)) return;

    _animateTo(0.0, velocity: velocity, easeOut: true);
  }

  void toggle() {
    // Only toggle on mobile; on tablet, drawer is always visible
    if (_isTablet(context)) return;

    isOpen ? close() : open();
  }

  void _dismissKeyboard() {
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
  }

  double _startValue = 0.0;

  void _onDragStart(DragStartDetails d) {
    if (_isTablet(context)) return;

    if (_controller.value <= 0.001) {
      try {
        widget.onOpenStart?.call();
      } catch (_) {}
      _dismissKeyboard();
    }
    _startValue = _controller.value;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_isTablet(context)) return;

    final delta = d.primaryDelta ?? 0.0;
    final next = (_startValue + delta / _panelWidth).clamp(0.0, 1.0);
    _controller.value = next;
    _startValue = next;
  }

  void _onDragEnd(DragEndDetails d) {
    if (_isTablet(context)) return;

    final vx = d.primaryVelocity ?? 0.0;
    final vMag = vx.abs();
    if (vMag > 300.0) {
      if (vx > 0) {
        open(velocity: vMag);
      } else {
        close(velocity: vMag);
      }
      return;
    }
    if (_controller.value >= widget.settleFraction) {
      open(velocity: vMag);
    } else {
      close(velocity: vMag);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final scrim = widget.scrimColor ?? context.colorTokens.overlayStrong;
    final isTablet = _isTablet(context);

    if (isTablet) {
      // Tablet layout: persistent side-by-side
      return _buildTabletLayout(theme);
    } else {
      // Mobile layout: overlay drawer
      return _buildMobileLayout(theme, scrim);
    }
  }

  Widget _buildTabletLayout(ConduitThemeExtension theme) {
    return Row(
      children: [
        // Persistent drawer
        Container(
          width: widget.tabletDrawerWidth,
          decoration: BoxDecoration(
            color: theme.surfaceBackground,
            border: Border(
              right: BorderSide(color: theme.dividerColor, width: 1),
            ),
          ),
          child: widget.drawer,
        ),
        // Content
        Expanded(child: widget.child),
      ],
    );
  }

  Widget _buildMobileLayout(ConduitThemeExtension theme, Color scrim) {
    return Stack(
      children: [
        // Content (optionally pushed by the drawer)
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              final dx = (widget.pushContent ? _panelWidth * t : 0.0)
                  .roundToDouble();
              final scale =
                  1.0 -
                  (widget.pushContent
                      ? (widget.contentScaleDelta.clamp(0.0, 0.2) * t)
                      : 0.0);
              final blurSigma =
                  (widget.pushContent
                          ? (widget.contentBlurSigma.clamp(0.0, 8.0) * t)
                          : 0.0)
                      .toDouble();
              Widget content = widget.child;
              if (blurSigma > 0.0) {
                content = ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                  ),
                  child: content,
                );
              }
              content = Transform.scale(
                scale: scale,
                alignment: Alignment.centerLeft,
                child: content,
              );
              content = Transform.translate(
                offset: Offset(dx, 0),
                child: content,
              );
              return content;
            },
          ),
        ),

        // Edge gesture region to open
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
          ),
        ),

        // Scrim + panel when animating or open
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            final ignoring = t == 0.0;
            return IgnorePointer(
              ignoring: ignoring,
              child: Stack(
                children: [
                  // Scrim
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: close,
                      onHorizontalDragStart: _onDragStart,
                      onHorizontalDragUpdate: _onDragUpdate,
                      onHorizontalDragEnd: _onDragEnd,
                      child: ColoredBox(
                        color: scrim.withValues(alpha: 0.6 * t),
                      ),
                    ),
                  ),
                  // Panel (capture horizontal drags to close)
                  Positioned(
                    left: -_panelWidth * (1.0 - t),
                    top: 0,
                    bottom: 0,
                    width: _panelWidth,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragStart: _onDragStart,
                      onHorizontalDragUpdate: _onDragUpdate,
                      onHorizontalDragEnd: _onDragEnd,
                      child: RepaintBoundary(
                        child: Material(
                          color: theme.surfaceBackground,
                          elevation: 8,
                          child: widget.drawer,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controllerInstance?.dispose();
    super.dispose();
  }
}
