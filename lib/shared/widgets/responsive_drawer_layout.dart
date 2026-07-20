import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart'
    show RenderBox, RenderEditable, RenderProxyBoxWithHitTestBehavior;
import 'package:flutter/services.dart';

import '../../core/services/performance_profiler.dart';
import '../../shared/theme/theme_extensions.dart';
import 'drawer_slot.dart';

const double _kSidebarNativeBottomBarContentHeight = 50.0;

enum _DrawerSettleEndpoint { open, closed }

class _HorizontalScrollableHit {
  const _HorizontalScrollableHit({required this.isAtOpenGestureLeadingEdge});

  final bool isAtOpenGestureLeadingEdge;
}

class _DrawerOpenHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _DrawerOpenHorizontalDragGestureRecognizer({super.debugOwner});

  double minimumLocalX = 0.0;
  double maximumLocalX = double.infinity;
  double axisBias = 1.0;
  bool Function(PointerEvent event)? isPositionAllowed;
  int? _trackedPointer;
  Offset? _pointerOrigin;
  double _verticalDistance = 0.0;
  bool _directionDisqualified = false;

  @override
  bool isPointerAllowed(PointerEvent event) {
    final dx = event.localPosition.dx;
    if (dx < minimumLocalX ||
        dx >= maximumLocalX ||
        (_trackedPointer != null && _trackedPointer != event.pointer) ||
        isPositionAllowed?.call(event) == false) {
      return false;
    }
    return super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _trackedPointer = event.pointer;
    _pointerOrigin = event.position;
    _verticalDistance = 0.0;
    _directionDisqualified = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer == _trackedPointer && event is PointerMoveEvent) {
      final delta = event.position - _pointerOrigin!;
      final dxAbs = delta.dx.abs();
      _verticalDistance = delta.dy.abs();
      final touchSlop = computeHitSlop(event.kind, gestureSettings);
      if ((_verticalDistance > touchSlop && _verticalDistance > dxAbs) ||
          (delta.dx < -touchSlop && dxAbs > _verticalDistance)) {
        _directionDisqualified = true;
      }
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _trackedPointer = null;
    _pointerOrigin = null;
    _verticalDistance = 0.0;
    _directionDisqualified = false;
  }

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    return !_directionDisqualified &&
        globalDistanceMoved >
            computeHitSlop(pointerDeviceKind, gestureSettings) &&
        globalDistanceMoved > _verticalDistance * axisBias;
  }

  @override
  String get debugDescription => 'drawer open horizontal drag';
}

/// Prevents the full-width drawer-open recognizer from competing with a
/// descendant that owns non-scroll horizontal gestures, such as rich-text
/// selection or a document editor.
class DrawerOpenGestureExclusion extends SingleChildRenderObjectWidget {
  const DrawerOpenGestureExclusion({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDrawerOpenGestureExclusion();
}

class _RenderDrawerOpenGestureExclusion
    extends RenderProxyBoxWithHitTestBehavior {
  _RenderDrawerOpenGestureExclusion()
    : super(behavior: HitTestBehavior.translucent);
}

/// Gives a quick rightward drawer drag priority inside an otherwise excluded
/// gesture owner while still allowing that owner to win gestures such as a
/// stationary long press.
///
/// Place this below the owner's recognizer in the widget tree. For example,
/// putting it around the child of a [SelectionArea] lets the drawer win an
/// immediate horizontal drag on every platform, while the selection area's
/// long-press recognizer still wins before any horizontal movement begins.
class DrawerOpenGesturePriority extends StatelessWidget {
  const DrawerOpenGesturePriority({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final layout = ResponsiveDrawerLayout.of(context);
    return layout?._buildPrioritizedDrawerGestureArena(child) ?? child;
  }
}

class DrawerChromeCompositionScope extends InheritedWidget {
  const DrawerChromeCompositionScope({
    super.key,
    required this.composeNativeChrome,
    required super.child,
  });

  final bool composeNativeChrome;

  static bool shouldCompose(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<DrawerChromeCompositionScope>()
            ?.composeNativeChrome ??
        true;
  }

  @override
  bool updateShouldNotify(DrawerChromeCompositionScope oldWidget) =>
      composeNativeChrome != oldWidget.composeNativeChrome;
}

bool _usesNativeSidebarChrome(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.iOS;

/// Top inset so sidebar tab content starts below native sidebar chrome.
double sidebarTabContentTopPadding(BuildContext context) {
  if (!_usesNativeSidebarChrome(context)) {
    return Spacing.sm;
  }

  return MediaQuery.viewPaddingOf(context).top + kTextTabBarHeight + Spacing.sm;
}

/// Edge offset so pull-to-refresh indicators appear below sidebar chrome.
double sidebarRefreshIndicatorEdgeOffset(BuildContext context) {
  if (!_usesNativeSidebarChrome(context)) {
    return 0.0;
  }

  return MediaQuery.viewPaddingOf(context).top + kTextTabBarHeight;
}

/// Bottom inset so sidebar tab content clears native sidebar chrome.
double sidebarTabContentBottomPadding(
  BuildContext context, {
  bool includeNativeBottomBar = true,
}) {
  if (!_usesNativeSidebarChrome(context)) {
    return Spacing.md;
  }

  final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
  final navigationBarHeight = includeNativeBottomBar
      ? _kSidebarNativeBottomBarContentHeight
      : 0.0;
  return bottomPadding + navigationBarHeight + Spacing.md;
}

/// Height excluded from drawer drag gestures above the native sidebar tab bar.
double sidebarBottomBarGestureExclusionHeight(BuildContext context) {
  if (!_usesNativeSidebarChrome(context)) {
    return 0.0;
  }

  return sidebarTabContentBottomPadding(context);
}

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
  // Matches Flutter's default Material drawer edge width.
  static const double _kDrawerEdgeDragWidth = 20.0;
  static const double _kEdgeOpenTouchSlop = kTouchSlop;
  static const double _kHorizontalScrollableOpenThreshold = 45.0;
  static const double _kEdgeOpenAxisBias = 1.0;

  late final AnimationController _controller;
  late bool _isTabletDocked = widget.tabletInitiallyDocked;
  late bool _composeTabletDrawerChrome =
      !widget.tabletDismissible || widget.tabletInitiallyDocked;

  /// Cached tablet state to avoid accessing context when unmounted.
  bool _cachedIsTablet = false;
  _DrawerSettleEndpoint? _lastSettledEndpoint;
  _DrawerSettleEndpoint? _pendingSettledEndpoint;
  bool _composeMobileDrawerChrome = false;
  bool _isDragging = false;
  _DrawerSettleEndpoint? _dragTerminalEndpoint;
  int? _edgePointer;
  Offset? _edgePointerOrigin;
  VelocityTracker? _edgeVelocityTracker;
  bool _edgePointerSuppressedByHorizontalScrollable = false;
  double _edgePointerActivationThreshold = _kEdgeOpenTouchSlop;

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

  void _setComposeMobileDrawerChrome(bool value) {
    if (_composeMobileDrawerChrome == value || !mounted) return;
    setState(() => _composeMobileDrawerChrome = value);
    _recordChromeComposition(value);
  }

  void _setComposeTabletDrawerChrome(bool value) {
    if (_composeTabletDrawerChrome == value || !mounted) return;
    setState(() => _composeTabletDrawerChrome = value);
    _recordChromeComposition(value);
  }

  void _recordChromeComposition(bool value) {
    PerformanceProfiler.instance.instant(
      'sidebar_chrome_composition',
      scope: 'platform_views',
      data: <String, Object?>{'composeNativeChrome': value},
    );
  }

  Widget _scopeDrawer(Widget child, {required bool composeNativeChrome}) {
    return DrawerChromeCompositionScope(
      composeNativeChrome: composeNativeChrome,
      child: child,
    );
  }

  double get _panelWidth {
    final w = MediaQuery.of(context).size.width;
    final raw = w * widget.maxFraction;
    final maxClamp = widget.maxFraction >= 1.0 ? w : 520.0;
    return raw.clamp(280.0, maxClamp);
  }

  double get _edgeWidth =>
      MediaQuery.of(context).size.width * widget.edgeFraction;

  double get _drawerEdgeDragWidth =>
      _kDrawerEdgeDragWidth + MediaQuery.paddingOf(context).left;

  double get _rawDrawerEdgeWidth =>
      _drawerEdgeDragWidth.clamp(0.0, _edgeWidth).toDouble();

  bool _contentDrawerGestureCanStart(PointerEvent event) {
    if (_controller.value > 0.001) {
      return false;
    }

    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    return !result.path.any(
      (entry) =>
          entry.target is _RenderDrawerOpenGestureExclusion ||
          entry.target is RenderEditable,
    );
  }

  bool _prioritizedDrawerGestureCanStart(PointerEvent event) {
    if (_isTablet(context) || _controller.value > 0.001) {
      return false;
    }

    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return false;
    }

    final localPosition = renderObject.globalToLocal(event.position);
    return localPosition.dx >= _rawDrawerEdgeWidth &&
        localPosition.dx < _edgeWidth;
  }

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
    final wasTablet = _cachedIsTablet;
    final isTablet = _isTablet(context);
    if (wasTablet == isTablet) return;

    final shouldComposeTabletChrome =
        !widget.tabletDismissible || _isTabletDocked;
    if (_composeTabletDrawerChrome != shouldComposeTabletChrome) {
      _composeTabletDrawerChrome = shouldComposeTabletChrome;
      _recordChromeComposition(shouldComposeTabletChrome);
    }
  }

  @override
  void didUpdateWidget(covariant ResponsiveDrawerLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.tabletDismissible) {
      final compositionChanged = !_composeTabletDrawerChrome;
      if (!_isTabletDocked || compositionChanged) {
        setState(() {
          _isTabletDocked = true;
          _composeTabletDrawerChrome = true;
        });
        if (compositionChanged) _recordChromeComposition(true);
      }
    } else if (widget.tabletInitiallyDocked !=
            oldWidget.tabletInitiallyDocked &&
        _isTablet(context)) {
      final compositionChanged =
          _composeTabletDrawerChrome != widget.tabletInitiallyDocked;
      setState(() {
        _isTabletDocked = widget.tabletInitiallyDocked;
        _composeTabletDrawerChrome = widget.tabletInitiallyDocked;
      });
      if (compositionChanged) {
        _recordChromeComposition(widget.tabletInitiallyDocked);
      }
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
    _setComposeMobileDrawerChrome(endpoint != _DrawerSettleEndpoint.closed);
    if (_pendingSettledEndpoint != endpoint) {
      return;
    }

    _pendingSettledEndpoint = null;
    _lastSettledEndpoint = endpoint;
  }

  void open({double velocity = 0.0}) {
    if (_isTablet(context)) {
      final compositionChanged = !_composeTabletDrawerChrome;
      if (!_isTabletDocked || compositionChanged) {
        setState(() {
          _isTabletDocked = true;
          _composeTabletDrawerChrome = true;
        });
        if (compositionChanged) _recordChromeComposition(true);
      }
      return;
    }
    if (_controller.isCompleted) return;
    _pendingSettledEndpoint = _lastSettledEndpoint == _DrawerSettleEndpoint.open
        ? null
        : _DrawerSettleEndpoint.open;
    _setComposeMobileDrawerChrome(true);

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
    if (_controller.isDismissed) {
      _setComposeMobileDrawerChrome(false);
      return;
    }
    _pendingSettledEndpoint =
        _lastSettledEndpoint == _DrawerSettleEndpoint.closed
        ? null
        : _DrawerSettleEndpoint.closed;

    _springTo(0.0, velocity: -velocity.abs());
  }

  void toggle() {
    if (_isTablet(context)) {
      if (!widget.tabletDismissible) return;
      _isTabletDocked ? close() : open();
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

  void _resetEdgePointerState() {
    _edgePointer = null;
    _edgePointerOrigin = null;
    _edgeVelocityTracker = null;
    _edgePointerSuppressedByHorizontalScrollable = false;
    _edgePointerActivationThreshold = _kEdgeOpenTouchSlop;
  }

  void _beginDrawerDrag() {
    _resetDragState();
    _isDragging = true;
    _setComposeMobileDrawerChrome(true);
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

  void _updateDrawerDragFromTotalDelta(double totalDelta) {
    _dragCumulativeDelta = totalDelta;
    final next = (_dragStartControllerValue + totalDelta / _panelWidth).clamp(
      0.0,
      1.0,
    );
    _controller.value = next;
    if (_settledEndpointForValue(next) != _dragTerminalEndpoint) {
      _dragTerminalEndpoint = null;
    }
  }

  void _endDrawerDragWithVelocity(double velocity) {
    final vx = velocity;
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

  bool _isHorizontalAxisDirection(AxisDirection direction) =>
      direction == AxisDirection.left || direction == AxisDirection.right;

  bool _isAtLeadingEdgeForOpenGesture(
    ScrollPosition position,
    AxisDirection axisDirection,
  ) {
    const epsilon = 0.5;
    return switch (axisDirection) {
      AxisDirection.right =>
        position.pixels <= position.minScrollExtent + epsilon,
      AxisDirection.left =>
        position.pixels >= position.maxScrollExtent - epsilon,
      AxisDirection.up || AxisDirection.down => true,
    };
  }

  _HorizontalScrollableHit? _detectHorizontalScrollableHit(
    Offset globalPosition,
    int viewId,
  ) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, globalPosition, viewId);
    var foundHorizontalTarget = false;

    for (final entry in result.path) {
      final dynamic target = entry.target;

      // Scrollable's opaque gesture handler remains in the hit-test path even
      // when blank space inside its viewport has no hit-testable descendant.
      // Its surrounding scroll-semantics render object exposes the position,
      // which lets us recognize those otherwise invisible scrollable regions.
      try {
        final maybePosition = target.position;
        if (maybePosition is ScrollPosition &&
            _isHorizontalAxisDirection(maybePosition.axisDirection)) {
          return _HorizontalScrollableHit(
            isAtOpenGestureLeadingEdge: _isAtLeadingEdgeForOpenGesture(
              maybePosition,
              maybePosition.axisDirection,
            ),
          );
        }
      } catch (_) {}

      AxisDirection? axisDirection;
      try {
        final maybeAxisDirection = target.axisDirection;
        if (maybeAxisDirection is AxisDirection) {
          axisDirection = maybeAxisDirection;
        }
      } catch (_) {}

      if (axisDirection == null || !_isHorizontalAxisDirection(axisDirection)) {
        continue;
      }
      foundHorizontalTarget = true;

      try {
        final offset = target.offset;
        if (offset is ScrollPosition) {
          return _HorizontalScrollableHit(
            isAtOpenGestureLeadingEdge: _isAtLeadingEdgeForOpenGesture(
              offset,
              axisDirection,
            ),
          );
        }
      } catch (_) {}
    }

    return foundHorizontalTarget
        ? const _HorizontalScrollableHit(isAtOpenGestureLeadingEdge: true)
        : null;
  }

  void _onEdgePointerDown(PointerDownEvent event) {
    if (_isTablet(context) || _controller.value > 0.001) return;

    _resetEdgePointerState();
    _edgePointer = event.pointer;
    _edgePointerOrigin = event.position;
    _edgeVelocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);

    final horizontalHit = _detectHorizontalScrollableHit(
      event.position,
      event.viewId,
    );
    if (horizontalHit == null) {
      return;
    }

    if (horizontalHit.isAtOpenGestureLeadingEdge &&
        event.localPosition.dx <= _drawerEdgeDragWidth) {
      _edgePointerActivationThreshold = _kHorizontalScrollableOpenThreshold;
    } else {
      _edgePointerSuppressedByHorizontalScrollable = true;
    }
  }

  void _onEdgePointerMove(PointerMoveEvent event) {
    if (_isTablet(context) ||
        _edgePointer != event.pointer ||
        _edgePointerOrigin == null) {
      return;
    }

    _edgeVelocityTracker?.addPosition(event.timeStamp, event.position);
    if (_edgePointerSuppressedByHorizontalScrollable) {
      return;
    }

    final delta = event.position - _edgePointerOrigin!;
    final dx = delta.dx;
    final dyAbs = delta.dy.abs();

    if (!_isDragging) {
      if (dyAbs > _kEdgeOpenTouchSlop && dyAbs > dx.abs()) {
        _resetEdgePointerState();
        return;
      }
      if (dx <= 0.0) {
        if (dx.abs() > _kEdgeOpenTouchSlop && dx.abs() > dyAbs) {
          _resetEdgePointerState();
        }
        return;
      }
      if (dx <= _edgePointerActivationThreshold ||
          dx <= dyAbs * _kEdgeOpenAxisBias) {
        return;
      }

      _beginDrawerDrag();
    }

    final effectiveDx = (dx - _edgePointerActivationThreshold).clamp(
      0.0,
      double.infinity,
    );
    _updateDrawerDragFromTotalDelta(effectiveDx);
  }

  void _onEdgePointerUp(PointerUpEvent event) {
    if (_edgePointer != event.pointer) return;

    _edgeVelocityTracker?.addPosition(event.timeStamp, event.position);
    if (_isDragging) {
      final estimate = _edgeVelocityTracker?.getVelocity();
      _endDrawerDragWithVelocity(estimate?.pixelsPerSecond.dx ?? 0.0);
    }
    _resetEdgePointerState();
  }

  void _onEdgePointerCancel(PointerCancelEvent event) {
    if (_edgePointer != event.pointer) return;

    if (_isDragging) {
      _resetDragState();
      if (_controller.isDismissed) {
        _setComposeMobileDrawerChrome(false);
      }
    }
    _resetEdgePointerState();
  }

  void _onDragStart(DragStartDetails d) {
    if (_isTablet(context)) return;
    _beginDrawerDrag();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_isTablet(context)) return;
    _updateDrawerDragFromTotalDelta(
      _dragCumulativeDelta + (d.primaryDelta ?? 0.0),
    );
  }

  void _onDragEnd(DragEndDetails d) {
    if (_isTablet(context)) return;
    _endDrawerDragWithVelocity(d.primaryVelocity ?? 0.0);
  }

  void _onDragCancel() {
    if (_isTablet(context)) return;
    _resetDragState();
    if (_controller.isDismissed) {
      _setComposeMobileDrawerChrome(false);
    }
  }

  Widget _buildMobileContentGestureArena(Widget child) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: <Type, GestureRecognizerFactory>{
        _DrawerOpenHorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _DrawerOpenHorizontalDragGestureRecognizer
            >(
              () =>
                  _DrawerOpenHorizontalDragGestureRecognizer(debugOwner: this),
              (recognizer) {
                recognizer
                  ..minimumLocalX = _rawDrawerEdgeWidth
                  ..maximumLocalX = _edgeWidth
                  ..axisBias = _kEdgeOpenAxisBias
                  ..isPositionAllowed = _contentDrawerGestureCanStart
                  ..onlyAcceptDragOnThreshold = true
                  ..dragStartBehavior = DragStartBehavior.down
                  ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                  ..onStart = _onDragStart
                  ..onUpdate = _onDragUpdate
                  ..onEnd = _onDragEnd
                  ..onCancel = _onDragCancel;
              },
            ),
      },
      child: child,
    );
  }

  Widget _buildPrioritizedDrawerGestureArena(Widget child) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: <Type, GestureRecognizerFactory>{
        _DrawerOpenHorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _DrawerOpenHorizontalDragGestureRecognizer
            >(
              () =>
                  _DrawerOpenHorizontalDragGestureRecognizer(debugOwner: this),
              (recognizer) {
                recognizer
                  ..minimumLocalX = -double.infinity
                  ..maximumLocalX = double.infinity
                  ..axisBias = _kEdgeOpenAxisBias
                  ..isPositionAllowed = _prioritizedDrawerGestureCanStart
                  ..onlyAcceptDragOnThreshold = true
                  ..dragStartBehavior = DragStartBehavior.down
                  ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                  ..onStart = _onDragStart
                  ..onUpdate = _onDragUpdate
                  ..onEnd = _onDragEnd
                  ..onCancel = _onDragCancel;
              },
            ),
      },
      child: child,
    );
  }

  Widget _buildTabletDrawerSlot(ConduitThemeExtension theme, DrawerSlot slot) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ColoredBox(
            color: theme.surfaceBackground,
            child: slot.mainPanel,
          ),
        ),
        ColoredBox(color: theme.surfaceBackground, child: slot.footerPanel),
      ],
    );
  }

  BoxDecoration _drawerPanelDecoration(ConduitThemeExtension theme) {
    return BoxDecoration(color: theme.surfaceBackground);
  }

  Widget _buildMobileDrawerSlotPanel(
    ConduitThemeExtension theme,
    DrawerSlot slot,
  ) {
    return Container(
      decoration: _drawerPanelDecoration(theme),
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
              child: ColoredBox(
                color: theme.surfaceBackground,
                child: slot.mainPanel,
              ),
            ),
          ),
          ColoredBox(color: theme.surfaceBackground, child: slot.footerPanel),
        ],
      ),
    );
  }

  Widget _buildMobileDrawerPanel(ConduitThemeExtension theme) {
    final drawerPanel = RepaintBoundary(
      child: Container(
        decoration: _drawerPanelDecoration(theme),
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

  void _handleTabletDrawerAnimationEnd() {
    _setComposeTabletDrawerChrome(!widget.tabletDismissible || _isTabletDocked);
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
          onEnd: _handleTabletDrawerAnimationEnd,
          width: targetWidth,
          decoration: BoxDecoration(color: theme.surfaceBackground),
          child: ClipRect(
            child: IgnorePointer(
              ignoring: widget.tabletDismissible && !_isTabletDocked,
              child: _scopeDrawer(
                widget.drawer is DrawerSlot
                    ? _buildTabletDrawerSlot(theme, widget.drawer as DrawerSlot)
                    : ColoredBox(
                        color: theme.surfaceBackground,
                        child: widget.drawer,
                      ),
                composeNativeChrome: _composeTabletDrawerChrome,
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
              child: _buildMobileContentGestureArena(widget.child),
            ),
          ),
        ),

        // The true screen edge intentionally overrides a horizontal scroller
        // only at its opening edge. Everywhere else, the ancestor recognizer
        // above participates in the gesture arena so descendant interactions
        // such as selection, editing, and platform views retain ownership.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _rawDrawerEdgeWidth,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onEdgePointerDown,
            onPointerMove: _onEdgePointerMove,
            onPointerUp: _onEdgePointerUp,
            onPointerCancel: _onEdgePointerCancel,
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
                    child: _scopeDrawer(
                      widget.drawer is DrawerSlot
                          ? RepaintBoundary(
                              child: _buildMobileDrawerSlotPanel(
                                theme,
                                widget.drawer as DrawerSlot,
                              ),
                            )
                          : _buildMobileDrawerPanel(theme),
                      composeNativeChrome: _composeMobileDrawerChrome,
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
    _controller.removeStatusListener(_onControllerStatusChanged);
    _controller.dispose();
    super.dispose();
  }
}
