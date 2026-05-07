import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';

import '../../shared/theme/theme_extensions.dart';
import 'drawer_slot.dart';

enum _DrawerSettleEndpoint { open, closed }

/// A responsive layout that shows a persistent drawer on tablets (side-by-side)
/// and an overlay drawer on mobile devices.
///
/// When the [drawer] is a [DrawerSlot], horizontal swipe-to-close gestures on
/// mobile apply only to [DrawerSlot.mainPanel], not [DrawerSlot.footerPanel]
/// (e.g. a bottom tab bar with platform views).
///
/// On tablets (shortestSide >= 600), the drawer is always visible alongside
/// the content. On mobile, it behaves like a standard slide drawer.
/// Tablets can optionally dismiss the docked drawer to reclaim space.
class ResponsiveDrawerLayout extends StatefulWidget {
  final Widget child;
  final Widget drawer;

  // Mobile-specific configuration
  final double maxFraction; // 0..1 of screen width for mobile drawer
  final double edgeFraction; // 0..1 active edge width for open gesture
  final double settleFraction; // threshold to settle open on release
  final Color? scrimColor;
  final bool pushContent;
  final double contentScaleDelta;
  final VoidCallback? onOpenStart;
  final double mobileBottomDragGestureExclusion;

  // Tablet-specific configuration
  final double tabletDrawerWidth; // Fixed width for tablet drawer
  final bool tabletDismissible;
  final bool tabletInitiallyDocked;

  const ResponsiveDrawerLayout({
    super.key,
    required this.child,
    required this.drawer,
    this.maxFraction = 0.84,
    this.edgeFraction = 0.5,
    this.settleFraction = 0.12,
    this.scrimColor,
    this.pushContent = true,
    this.contentScaleDelta = 0.02,
    this.onOpenStart,
    this.mobileBottomDragGestureExclusion = 0.0,
    this.tabletDrawerWidth = 320.0,
    this.tabletDismissible = true,
    this.tabletInitiallyDocked = true,
  });

  static ResponsiveDrawerLayoutState? of(BuildContext context) =>
      context.findAncestorStateOfType<ResponsiveDrawerLayoutState>();

  @override
  State<ResponsiveDrawerLayout> createState() => ResponsiveDrawerLayoutState();
}

class ResponsiveDrawerLayoutState extends State<ResponsiveDrawerLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late bool _isTabletDocked = widget.tabletInitiallyDocked;

  /// Cached tablet state to avoid accessing context when unmounted.
  bool _cachedIsTablet = false;
  _DrawerSettleEndpoint? _lastSettledEndpoint;
  _DrawerSettleEndpoint? _pendingSettledEndpoint;
  bool _isDragging = false;
  _DrawerSettleEndpoint? _dragTerminalEndpoint;

  /// Spring description matching iOS navigation drawer physics.
  static final SpringDescription _spring = SpringDescription(
    mass: 1.0,
    stiffness: 600.0,
    damping: 44.0,
  );

  /// Duration for tablet animated container transitions.
  static const Duration _tabletDuration = Duration(milliseconds: 250);

  bool _isTablet(BuildContext context) {
    final size = MediaQuery.of(context).size;
    _cachedIsTablet = size.shortestSide >= 600;
    return _cachedIsTablet;
  }

  double get _panelWidth {
    final w = MediaQuery.of(context).size.width;
    final raw = w * widget.maxFraction;
    final maxClamp = widget.maxFraction >= 1.0 ? w : 520.0;
    return raw.clamp(280.0, maxClamp);
  }

  double get _edgeWidth =>
      MediaQuery.of(context).size.width * widget.edgeFraction;

  /// Returns whether the drawer is currently open.
  /// Uses cached tablet state to avoid context access issues when unmounted.
  bool get isOpen =>
      _cachedIsTablet ? _isTabletDocked : _controller.value == 1.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: 0.0);
    _lastSettledEndpoint = _settledEndpointForValue(_controller.value);
    _controller.addStatusListener(_onControllerStatusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Update cached tablet state when MediaQuery changes
    _isTablet(context);
  }

  @override
  void didUpdateWidget(covariant ResponsiveDrawerLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.tabletDismissible && !_isTabletDocked) {
      setState(() => _isTabletDocked = true);
    } else if (widget.tabletInitiallyDocked !=
            oldWidget.tabletInitiallyDocked &&
        _isTablet(context)) {
      setState(() => _isTabletDocked = widget.tabletInitiallyDocked);
    }
  }

  /// Animate to [target] using iOS-style spring physics.
  ///
  /// [velocity] is in pixels/sec from the drag gesture, converted to
  /// the 0..1 animation range.
  void _springTo(double target, {double velocity = 0.0}) {
    final panelPx = _panelWidth;
    // Convert px/s velocity to animation-units/s
    final unitVelocity = panelPx > 0 ? velocity / panelPx : 0.0;

    final simulation = SpringSimulation(
      _spring,
      _controller.value,
      target,
      unitVelocity,
    );
    final ticker = _controller.animateWith(simulation);
    unawaited(
      ticker.orCancel
          .then((_) {
            if (!mounted) return;
            if (target == 0.0 && !_controller.isDismissed) {
              _controller.value = 0.0;
            } else if (target == 1.0 && !_controller.isCompleted) {
              _controller.value = 1.0;
            }
          })
          .catchError((Object _) {}),
    );
  }

  _DrawerSettleEndpoint? _settledEndpointForValue(double value) {
    if (value <= 0.0) return _DrawerSettleEndpoint.closed;
    if (value >= 1.0) return _DrawerSettleEndpoint.open;
    return null;
  }

  void _onControllerStatusChanged(AnimationStatus status) {
    if (mounted) {
      _isTablet(context);
    }
    if (_cachedIsTablet) return;

    final endpoint = switch (status) {
      AnimationStatus.completed => _DrawerSettleEndpoint.open,
      AnimationStatus.dismissed => _DrawerSettleEndpoint.closed,
      _ => null,
    };
    if (endpoint == null) {
      return;
    }
    if (_isDragging) {
      _dragTerminalEndpoint = endpoint;
      return;
    }
    if (_pendingSettledEndpoint != endpoint) {
      return;
    }

    _pendingSettledEndpoint = null;
    _lastSettledEndpoint = endpoint;
    ConduitHaptics.mediumImpact();
  }

  void open({double velocity = 0.0}) {
    if (_isTablet(context)) {
      if (!_isTabletDocked) {
        setState(() => _isTabletDocked = true);
      }
      return;
    }
    if (_controller.isCompleted) return;
    _pendingSettledEndpoint = _lastSettledEndpoint == _DrawerSettleEndpoint.open
        ? null
        : _DrawerSettleEndpoint.open;

    try {
      widget.onOpenStart?.call();
    } catch (_) {}
    _dismissKeyboard();
    _springTo(1.0, velocity: velocity);
  }

  void close({double velocity = 0.0}) {
    if (_isTablet(context)) {
      if (!widget.tabletDismissible) return;
      if (_isTabletDocked) {
        setState(() => _isTabletDocked = false);
      }
      return;
    }
    if (_controller.isDismissed) return;
    _pendingSettledEndpoint =
        _lastSettledEndpoint == _DrawerSettleEndpoint.closed
        ? null
        : _DrawerSettleEndpoint.closed;

    _springTo(0.0, velocity: -velocity.abs());
  }

  void toggle() {
    if (_isTablet(context)) {
      if (!widget.tabletDismissible) return;
      setState(() => _isTabletDocked = !_isTabletDocked);
      return;
    }

    isOpen ? close() : open();
  }

  void _dismissKeyboard() {
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
  }

  double _dragStartControllerValue = 0.0;
  double _dragCumulativeDelta = 0.0;

  void _resetDragState() {
    _isDragging = false;
    _dragTerminalEndpoint = null;
  }

  void _onDragStart(DragStartDetails d) {
    if (_isTablet(context)) return;

    _resetDragState();
    _isDragging = true;
    if (_controller.value <= 0.001) {
      try {
        widget.onOpenStart?.call();
      } catch (_) {}
      _dismissKeyboard();
    }
    _controller.stop();
    _dragStartControllerValue = _controller.value;
    _dragCumulativeDelta = 0.0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_isTablet(context)) return;

    _dragCumulativeDelta += d.primaryDelta ?? 0.0;
    final next =
        (_dragStartControllerValue + _dragCumulativeDelta / _panelWidth).clamp(
          0.0,
          1.0,
        );
    _controller.value = next;
    if (_settledEndpointForValue(next) != _dragTerminalEndpoint) {
      _dragTerminalEndpoint = null;
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (_isTablet(context)) return;

    final vx = d.primaryVelocity ?? 0.0;
    final vMag = vx.abs();
    final endpoint = vMag > 300.0
        ? (vx > 0.0 ? _DrawerSettleEndpoint.open : _DrawerSettleEndpoint.closed)
        : (_controller.value >= widget.settleFraction
              ? _DrawerSettleEndpoint.open
              : _DrawerSettleEndpoint.closed);

    _isDragging = false;
    if (_dragTerminalEndpoint == endpoint && _lastSettledEndpoint != endpoint) {
      _pendingSettledEndpoint = endpoint;
      _onControllerStatusChanged(
        endpoint == _DrawerSettleEndpoint.open
            ? AnimationStatus.completed
            : AnimationStatus.dismissed,
      );
      _dragTerminalEndpoint = null;
      return;
    }

    _dragTerminalEndpoint = null;
    if (endpoint == _DrawerSettleEndpoint.open) {
      open(velocity: vMag);
    } else {
      close(velocity: vMag);
    }
  }

  void _onDragCancel() {
    if (_isTablet(context)) return;
    _resetDragState();
  }

  Widget _buildTabletDrawerSlot(ConduitThemeExtension theme, DrawerSlot slot) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Material(
            color: theme.surfaceBackground,
            child: slot.mainPanel,
          ),
        ),
        Material(color: theme.surfaceBackground, child: slot.footerPanel),
      ],
    );
  }

  Widget _buildMobileDrawerSlotPanel(
    ConduitThemeExtension theme,
    DrawerSlot slot,
  ) {
    return Material(
      elevation: 8,
      color: theme.surfaceBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              onHorizontalDragCancel: _onDragCancel,
              child: Material(
                color: theme.surfaceBackground,
                child: slot.mainPanel,
              ),
            ),
          ),
          Material(color: theme.surfaceBackground, child: slot.footerPanel),
        ],
      ),
    );
  }

  Widget _buildMobileDrawerPanel(ConduitThemeExtension theme) {
    final drawerPanel = RepaintBoundary(
      child: Material(
        color: theme.surfaceBackground,
        elevation: 8,
        child: widget.drawer,
      ),
    );

    final excludedHeight = widget.mobileBottomDragGestureExclusion.clamp(
      0.0,
      MediaQuery.of(context).size.height,
    );

    return Stack(
      children: [
        drawerPanel,
        if (excludedHeight < MediaQuery.of(context).size.height)
          Positioned.fill(
            bottom: excludedHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              onHorizontalDragCancel: _onDragCancel,
            ),
          ),
      ],
    );
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
    final targetWidth = widget.tabletDismissible && !_isTabletDocked
        ? 0.0
        : widget.tabletDrawerWidth;
    return Row(
      children: [
        // Persistent drawer
        AnimatedContainer(
          duration: _tabletDuration,
          curve: Curves.easeOutCubic,
          width: targetWidth,
          decoration: BoxDecoration(
            color: theme.surfaceBackground,
            border: Border(
              right: BorderSide(color: theme.dividerColor, width: 1),
            ),
          ),
          child: ClipRect(
            child: IgnorePointer(
              ignoring: widget.tabletDismissible && !_isTabletDocked,
              child: widget.drawer is DrawerSlot
                  ? _buildTabletDrawerSlot(theme, widget.drawer as DrawerSlot)
                  : Material(
                      color: theme.surfaceBackground,
                      child: widget.drawer,
                    ),
            ),
          ),
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
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final t = _controller.value;
                final dx = (widget.pushContent ? _panelWidth * t : 0.0)
                    .roundToDouble();
                final scaleDelta = widget.pushContent
                    ? widget.contentScaleDelta.clamp(0.0, 0.2) * t
                    : 0.0;
                final scale = 1.0 - scaleDelta;

                final matrix = Matrix4.identity()
                  ..setEntry(0, 3, dx)
                  ..setEntry(0, 0, scale)
                  ..setEntry(1, 1, scale);

                return Transform(
                  transform: matrix,
                  alignment: Alignment.centerLeft,
                  child: child,
                );
              },
              child: widget.child,
            ),
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
            onHorizontalDragCancel: _onDragCancel,
          ),
        ),

        // Scrim + panel when animating or open
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
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
                      onHorizontalDragCancel: _onDragCancel,
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
                    child: widget.drawer is DrawerSlot
                        ? RepaintBoundary(
                            child: _buildMobileDrawerSlotPanel(
                              theme,
                              widget.drawer as DrawerSlot,
                            ),
                          )
                        : _buildMobileDrawerPanel(theme),
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
    _controller.removeStatusListener(_onControllerStatusChanged);
    _controller.dispose();
    super.dispose();
  }
}
