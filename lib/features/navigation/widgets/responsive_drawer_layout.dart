import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart' show RenderBox, RenderEditable;
import 'package:flutter/services.dart';

import 'package:conduit_core/services/performance_profiler.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/horizontal_gesture_ownership.dart';
import '../../../shared/widgets/drawer_slot.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import 'drawer_open_drag_gesture_recognizer.dart';
import 'resizable_tablet_sidebar.dart';

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
  final Widget Function(Widget child)? layoutBuilder;

  // Mobile-specific configuration
  final double maxFraction; // 0..1 of screen width for mobile drawer
  final double edgeFraction; // 0..1 active edge width for open gesture
  final double settleFraction; // threshold to settle open on release
  final Color? scrimColor;
  final bool pushContent;
  final bool roundPushedContent;
  final double contentScaleDelta;

  /// Whether the mobile drawer taps once when it comes to rest fully open
  /// after being closed, or fully closed after being open.
  final bool settleHaptics;
  final VoidCallback? onOpenStart;
  final double mobileBottomDragGestureExclusion;

  // Tablet-specific configuration
  final double tabletDrawerWidth; // Fixed width for tablet drawer
  final double tabletDrawerMinWidth;
  final double tabletDrawerMaxWidth;
  final double tabletMinimumContentWidth;
  final bool tabletResizable;
  final ValueChanged<double>? onTabletDrawerWidthChanged;
  final String? tabletResizeSemanticsLabel;
  final String? tabletResizeSemanticsHint;
  final String Function(double width)? tabletResizeSemanticsValueBuilder;
  final bool tabletDismissible;
  final bool tabletInitiallyDocked;

  const ResponsiveDrawerLayout({
    super.key,
    required this.child,
    required this.drawer,
    this.layoutBuilder,
    this.maxFraction = 0.84,
    this.edgeFraction = 0.5,
    this.settleFraction = 0.12,
    this.scrimColor,
    this.pushContent = true,
    this.roundPushedContent = false,
    this.contentScaleDelta = 0.02,
    this.settleHaptics = false,
    this.onOpenStart,
    this.mobileBottomDragGestureExclusion = 0.0,
    this.tabletDrawerWidth = defaultSidebarTabletWidth,
    this.tabletDrawerMinWidth = minimumSidebarTabletWidth,
    this.tabletDrawerMaxWidth = maximumSidebarTabletWidth,
    this.tabletMinimumContentWidth = defaultSidebarTabletWidth,
    this.tabletResizable = false,
    this.onTabletDrawerWidthChanged,
    this.tabletResizeSemanticsLabel,
    this.tabletResizeSemanticsHint,
    this.tabletResizeSemanticsValueBuilder,
    this.tabletDismissible = true,
    this.tabletInitiallyDocked = true,
  }) : assert(tabletDrawerMinWidth > 0),
       assert(tabletDrawerMaxWidth >= tabletDrawerMinWidth),
       assert(tabletMinimumContentWidth >= 0);

  @override
  State<ResponsiveDrawerLayout> createState() => ResponsiveDrawerLayoutState();
}

class ResponsiveDrawerLayoutState extends State<ResponsiveDrawerLayout>
    with SingleTickerProviderStateMixin
    implements SidebarDrawerController {
  // Matches Flutter's default Material drawer edge width.
  static const double _kDrawerEdgeDragWidth = 20.0;

  /// Radius the pushed content's corners reach where the screen's is unknown.
  static const double _kPushedContentCornerRadius = 36.0;

  /// How far the pushed content fades, when the drawer is open, toward a
  /// grey [_kPushedContentVeilTone] of the way from the page to its text. The
  /// page turns grey beside the drawer while its text dims, rather than both
  /// sinking into black.
  static const double _kPushedContentVeilOpacity = 0.5;
  static const double _kPushedContentVeilTone = 0.16;

  /// A faint line in the text colour around the open pushed content, like the
  /// edge of a pane of glass.
  static const double _kPushedContentEdgeOpacity = 0.12;
  static const double _kPushedContentEdgeWidth = 1.0;
  static const double _kEdgeOpenAxisBias = 1.0;

  /// How near, in points, the settling drawer comes to an endpoint before it
  /// counts as there. [_spring] is within a point at about 230 ms but only
  /// comes to rest at about 490 ms, a lag a haptic on landing would show.
  static const double _kSettleLandingDistance = 1.0;

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

  /// Spring description matching iOS navigation drawer physics.
  static final SpringDescription _spring = SpringDescription(
    mass: 1.0,
    stiffness: 600.0,
    damping: 44.0,
  );

  /// Radius the pushed content's corners reach when the drawer is open: the
  /// screen's own, so the content follows the display's curve, when the app
  /// fills the screen and the system reports one.
  double _pushedContentCornerRadius(BuildContext context) {
    final device = PlatformUiCapabilities.displayCornerRadius;
    if (device == null || PlatformUiCapabilities.isIOSAppOnMac) {
      return _kPushedContentCornerRadius;
    }
    final display = View.of(context).display.size;
    final window =
        MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    // A window smaller than the screen has corners of its own.
    final fillsScreen =
        (display.longestSide - window.longestSide).abs() < 1 &&
        (display.shortestSide - window.shortestSide).abs() < 1;
    return fillsScreen ? device : _kPushedContentCornerRadius;
  }

  bool _isTablet(BuildContext context) {
    _cachedIsTablet = usesPersistentTabletSidebar(context);
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
    final maximum = widget.maxFraction >= 1.0
        ? w
        : (w - 48.0).clamp(0.0, 520.0);
    return (w * widget.maxFraction).clamp(maximum.clamp(0.0, 280.0), maximum);
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
          entry.target is RenderHorizontalGestureExclusion ||
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
  @override
  bool get isOpen =>
      _cachedIsTablet ? _isTabletDocked : _controller.value == 1.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: 0.0);
    _lastSettledEndpoint = _settledEndpointForValue(_controller.value);
    _controller.addListener(_onControllerValueChanged);
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
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = target;
      return;
    }
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
    _settle(endpoint);
  }

  /// Settles the drawer as soon as it lands within [_kSettleLandingDistance]
  /// of the endpoint it is heading for, before the spring comes to rest.
  void _onControllerValueChanged() {
    final endpoint = _pendingSettledEndpoint;
    if (endpoint == null || _isDragging || _cachedIsTablet || !mounted) return;
    final target = endpoint == _DrawerSettleEndpoint.open ? 1.0 : 0.0;
    final distance = (_controller.value - target).abs() * _panelWidth;
    if (distance > _kSettleLandingDistance) return;
    _settle(endpoint);
  }

  void _settle(_DrawerSettleEndpoint endpoint) {
    _pendingSettledEndpoint = null;
    _lastSettledEndpoint = endpoint;
    if (widget.settleHaptics) unawaited(ConduitHaptics.lightImpact());
  }

  @override
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

  @override
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

  @override
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

  bool? _horizontalScrollableLeadingEdge(Offset globalPosition, int viewId) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, globalPosition, viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderHorizontalScrollGestureBoundary) {
        return target.isAtLeadingEdge;
      }
    }
    return null;
  }

  bool _edgeDrawerGestureCanStart(PointerEvent event) =>
      _controller.value <= 0.001 &&
      _horizontalScrollableLeadingEdge(event.position, event.viewId) != false;

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

  Widget _buildMobileContentGestureArena(
    Widget child, {
    bool fromEdge = false,
  }) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: <Type, GestureRecognizerFactory>{
        DrawerOpenDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              DrawerOpenDragGestureRecognizer
            >(() => DrawerOpenDragGestureRecognizer(debugOwner: this), (
              recognizer,
            ) {
              recognizer
                ..minimumLocalX = fromEdge ? 0 : _rawDrawerEdgeWidth
                ..maximumLocalX = fromEdge ? _rawDrawerEdgeWidth : _edgeWidth
                ..axisBias = _kEdgeOpenAxisBias
                ..isPositionAllowed = fromEdge
                    ? _edgeDrawerGestureCanStart
                    : _contentDrawerGestureCanStart
                ..onlyAcceptDragOnThreshold = true
                ..dragStartBehavior = DragStartBehavior.down
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                ..onStart = _onDragStart
                ..onUpdate = _onDragUpdate
                ..onEnd = _onDragEnd
                ..onCancel = _onDragCancel;
            }),
      },
      child: child,
    );
  }

  Widget _buildPrioritizedDrawerGestureArena(Widget child) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: <Type, GestureRecognizerFactory>{
        DrawerOpenDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              DrawerOpenDragGestureRecognizer
            >(() => DrawerOpenDragGestureRecognizer(debugOwner: this), (
              recognizer,
            ) {
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
            }),
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

    final layout = isTablet
        ? _buildTabletLayout(theme)
        : _buildMobileLayout(theme, scrim);
    final scopedLayout = HorizontalGesturePriorityScope(
      buildPrioritizedGestureArena: _buildPrioritizedDrawerGestureArena,
      child: layout,
    );
    return SidebarDrawerControllerScope(
      controller: this,
      child: widget.layoutBuilder?.call(scopedLayout) ?? scopedLayout,
    );
  }

  void _handleTabletDrawerAnimationEnd() {
    _setComposeTabletDrawerChrome(!widget.tabletDismissible || _isTabletDocked);
  }

  Widget _buildTabletLayout(ConduitThemeExtension theme) {
    final drawer = _scopeDrawer(
      PersistentTabletSidebarScope(
        active: true,
        child: widget.drawer is DrawerSlot
            ? _buildTabletDrawerSlot(theme, widget.drawer as DrawerSlot)
            : ColoredBox(color: theme.surfaceBackground, child: widget.drawer),
      ),
      composeNativeChrome: _composeTabletDrawerChrome,
    );
    return ResizableTabletSidebar(
      drawer: drawer,
      content: widget.child,
      configuredWidth: widget.tabletDrawerWidth,
      minimumWidth: widget.tabletDrawerMinWidth,
      maximumWidth: widget.tabletDrawerMaxWidth,
      minimumContentWidth: widget.tabletMinimumContentWidth,
      resizable: widget.tabletResizable,
      dismissible: widget.tabletDismissible,
      docked: _isTabletDocked,
      composeDrawerChrome: _composeTabletDrawerChrome,
      drawerColor: theme.surfaceBackground,
      dividerColor: context.sidebarTheme.border,
      activeColor: theme.buttonPrimary,
      onDrawerAnimationEnd: _handleTabletDrawerAnimationEnd,
      onWidthChanged: widget.onTabletDrawerWidthChanged,
      resizeSemanticsLabel: widget.tabletResizeSemanticsLabel,
      resizeSemanticsHint: widget.tabletResizeSemanticsHint,
      resizeSemanticsValueBuilder: widget.tabletResizeSemanticsValueBuilder,
    );
  }

  Widget _buildMobileLayout(ConduitThemeExtension theme, Color scrim) {
    final roundContent = widget.pushContent && widget.roundPushedContent;
    // Fixed for the whole animation, so they are read once per build.
    final cornerRadius = roundContent
        ? _pushedContentCornerRadius(context)
        : 0.0;
    final veil = Color.lerp(
      theme.surfaceBackground,
      theme.textPrimary,
      _kPushedContentVeilTone,
    )!;
    return Stack(
      children: [
        // Shows at the pushed content's rounded corners, so it matches the
        // drawer beside them.
        Positioned.fill(child: ColoredBox(color: theme.surfaceBackground)),
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
                  child: ExcludeFocus(
                    excluding: t > 0,
                    child: ExcludeSemantics(
                      excluding: t > 0,
                      // Only a rectangular clip: see [PushedContentFrame].
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            child!,
                            if (roundContent)
                              PushedContentFrame(
                                radius: cornerRadius * t,
                                backdrop: theme.surfaceBackground,
                                veil: veil.withValues(
                                  alpha: _kPushedContentVeilOpacity * t,
                                ),
                                edge: theme.textPrimary.withValues(
                                  alpha: _kPushedContentEdgeOpacity * t,
                                ),
                                edgeWidth: _kPushedContentEdgeWidth,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: _buildMobileContentGestureArena(widget.child),
            ),
          ),
        ),

        // The edge must win the gesture arena too, so a diagonal opening
        // swipe cannot also drag the chat's vertical scrollable. Horizontal
        // scrollers keep ownership when they are away from their leading edge.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _rawDrawerEdgeWidth,
          child: _buildMobileContentGestureArena(
            const SizedBox.expand(),
            fromEdge: true,
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
                        // Rounded pushed content carries its own grey veil.
                        color: roundContent
                            ? Colors.transparent
                            : scrim.withValues(alpha: 0.6 * t),
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
    _controller.removeListener(_onControllerValueChanged);
    _controller.removeStatusListener(_onControllerStatusChanged);
    _controller.dispose();
    super.dispose();
  }
}

/// Covers the content an open mobile drawer pushes aside: a [veil] across it,
/// its corners rounded to [radius] in the [backdrop] colour around them, and
/// a glassy [edge] along them.
///
/// The corners are painted rather than clipped. On iOS, a rounded clip around
/// a platform view makes the engine keep what Flutter draws above that view
/// in the layer beneath as well as in its overlay, so a translucent veil came
/// out twice as strong across the bounds of the content's native controls.
@visibleForTesting
class PushedContentFrame extends StatelessWidget {
  const PushedContentFrame({
    super.key,
    required this.radius,
    required this.backdrop,
    required this.veil,
    required this.edge,
    required this.edgeWidth,
  });

  final double radius;
  final Color backdrop;
  final Color veil;
  final Color edge;
  final double edgeWidth;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _PushedContentFramePainter(this),
      ),
    );
  }
}

class _PushedContentFramePainter extends CustomPainter {
  const _PushedContentFramePainter(this.frame);

  final PushedContentFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    if (frame.veil.a > 0) {
      canvas.drawRect(bounds, Paint()..color = frame.veil);
    }
    if (frame.radius > 0) {
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(bounds)
          ..addRSuperellipse(
            RSuperellipse.fromRectAndRadius(
              bounds,
              Radius.circular(frame.radius),
            ),
          ),
        Paint()..color = frame.backdrop,
      );
    }
    if (frame.edge.a > 0 && frame.edgeWidth > 0) {
      // Stroked inside the corners, along the line between them.
      final inset = frame.edgeWidth / 2;
      canvas.drawRSuperellipse(
        RSuperellipse.fromRectAndRadius(
          bounds.deflate(inset),
          Radius.circular((frame.radius - inset).clamp(0.0, frame.radius)),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = frame.edgeWidth
          ..color = frame.edge,
      );
    }
  }

  @override
  bool shouldRepaint(_PushedContentFramePainter oldDelegate) {
    final old = oldDelegate.frame;
    return old.radius != frame.radius ||
        old.backdrop != frame.backdrop ||
        old.veil != frame.veil ||
        old.edge != frame.edge ||
        old.edgeWidth != frame.edgeWidth;
  }
}
