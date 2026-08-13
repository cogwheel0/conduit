import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';

/// Owns the geometry and interaction state for a resizable tablet sidebar.
class ResizableTabletSidebar extends StatefulWidget {
  const ResizableTabletSidebar({
    super.key,
    required this.drawer,
    required this.content,
    required this.configuredWidth,
    required this.minimumWidth,
    required this.maximumWidth,
    required this.minimumContentWidth,
    required this.resizable,
    required this.dismissible,
    required this.docked,
    required this.composeDrawerChrome,
    required this.drawerColor,
    required this.dividerColor,
    required this.activeColor,
    required this.onDrawerAnimationEnd,
    this.onWidthChanged,
    this.resizeSemanticsLabel,
    this.resizeSemanticsHint,
    this.resizeSemanticsValueBuilder,
  });

  final Widget drawer;
  final Widget content;
  final double configuredWidth;
  final double minimumWidth;
  final double maximumWidth;
  final double minimumContentWidth;
  final bool resizable;
  final bool dismissible;
  final bool docked;
  final bool composeDrawerChrome;
  final Color drawerColor;
  final Color dividerColor;
  final Color activeColor;
  final VoidCallback onDrawerAnimationEnd;
  final ValueChanged<double>? onWidthChanged;
  final String? resizeSemanticsLabel;
  final String? resizeSemanticsHint;
  final String Function(double width)? resizeSemanticsValueBuilder;

  @override
  State<ResizableTabletSidebar> createState() => _ResizableTabletSidebarState();
}

enum _WidthTransition { idle, direct, reset }

class _ResizableTabletSidebarState extends State<ResizableTabletSidebar> {
  static const Duration _layoutDuration = Duration(milliseconds: 250);
  static const Duration _resetDuration = Duration(milliseconds: 200);
  static const double _resizeStep = 20;
  static const double _resizeHandleHitWidth = 44;

  late double _preferredWidth = _clampConfigured(widget.configuredWidth);
  double? _resizeStartPreferredWidth;
  double? _resizeAnchorWidth;
  double _resizeCumulativeDelta = 0;
  bool _resizing = false;
  Timer? _keyboardCommitTimer;
  _WidthTransition _transition = _WidthTransition.idle;

  @override
  void didUpdateWidget(covariant ResizableTabletSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_resizing && widget.configuredWidth != oldWidget.configuredWidth) {
      _preferredWidth = _clampConfigured(widget.configuredWidth);
    }
  }

  double _clampConfigured(double width) =>
      width.clamp(widget.minimumWidth, widget.maximumWidth).toDouble();

  double _effectiveMaximum(double viewportWidth) {
    final protectedContentMaximum = math.max(
      defaultSidebarTabletWidth,
      viewportWidth - widget.minimumContentWidth,
    );
    return math
        .min(widget.maximumWidth, protectedContentMaximum)
        .clamp(widget.minimumWidth, widget.maximumWidth)
        .toDouble();
  }

  double _effectiveWidth(double viewportWidth) => _preferredWidth
      .clamp(widget.minimumWidth, _effectiveMaximum(viewportWidth))
      .toDouble();

  void _handleAnimationEnd() {
    widget.onDrawerAnimationEnd();
    if (_transition == _WidthTransition.reset && mounted) {
      setState(() => _transition = _WidthTransition.idle);
    }
  }

  void _scheduleTransitionIdle() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resizing) return;
      if (_transition == _WidthTransition.direct) {
        setState(() => _transition = _WidthTransition.idle);
      }
    });
  }

  void _beginResize(double viewportWidth) {
    if (!widget.resizable || !widget.docked) return;
    _keyboardCommitTimer?.cancel();
    _keyboardCommitTimer = null;
    final effectiveWidth = _effectiveWidth(viewportWidth);
    setState(() {
      _resizeStartPreferredWidth = _preferredWidth;
      _resizeAnchorWidth = effectiveWidth;
      _resizeCumulativeDelta = 0;
      _preferredWidth = effectiveWidth;
      _resizing = true;
      _transition = _WidthTransition.direct;
    });
  }

  void _updateResize(double delta, double viewportWidth) {
    if (!_resizing) return;
    final anchorWidth = _resizeAnchorWidth ?? _preferredWidth;
    final effectiveMaximum = _effectiveMaximum(viewportWidth);
    _resizeCumulativeDelta = (_resizeCumulativeDelta + delta)
        .clamp(
          widget.minimumWidth - anchorWidth,
          effectiveMaximum - anchorWidth,
        )
        .toDouble();
    final nextWidth = anchorWidth + _resizeCumulativeDelta;
    if (nextWidth == _preferredWidth) return;
    setState(() => _preferredWidth = nextWidth);
  }

  void _endResize() {
    if (!_resizing) return;
    final committedWidth = _preferredWidth;
    setState(() {
      _resizing = false;
      _resizeStartPreferredWidth = null;
      _resizeAnchorWidth = null;
      _resizeCumulativeDelta = 0;
      _transition = _WidthTransition.direct;
    });
    widget.onWidthChanged?.call(committedWidth);
    _scheduleTransitionIdle();
  }

  void _cancelResize() {
    if (!_resizing) return;
    final restoredWidth = _resizeStartPreferredWidth;
    setState(() {
      if (restoredWidth != null) _preferredWidth = restoredWidth;
      _resizing = false;
      _resizeStartPreferredWidth = null;
      _resizeAnchorWidth = null;
      _resizeCumulativeDelta = 0;
      _transition = _WidthTransition.direct;
    });
    _scheduleTransitionIdle();
  }

  void _adjustWidth(double delta, double viewportWidth) {
    if (!widget.resizable || !widget.docked) return;
    final currentWidth = _effectiveWidth(viewportWidth);
    final nextWidth = (currentWidth + delta)
        .clamp(widget.minimumWidth, _effectiveMaximum(viewportWidth))
        .toDouble();
    if (nextWidth == currentWidth) return;
    setState(() {
      _preferredWidth = nextWidth;
      _transition = _WidthTransition.direct;
    });
    _keyboardCommitTimer?.cancel();
    _keyboardCommitTimer = Timer(
      const Duration(milliseconds: 200),
      () => widget.onWidthChanged?.call(nextWidth),
    );
    _scheduleTransitionIdle();
  }

  void _resetWidth(double viewportWidth) {
    if (!widget.resizable || !widget.docked) return;
    final resetWidth = _clampConfigured(defaultSidebarTabletWidth);
    if (resetWidth == _preferredWidth) return;
    final previousEffectiveWidth = _effectiveWidth(viewportWidth);
    setState(() {
      _preferredWidth = resetWidth;
      _transition = _WidthTransition.reset;
    });
    _keyboardCommitTimer?.cancel();
    widget.onWidthChanged?.call(resetWidth);
    if (MediaQuery.disableAnimationsOf(context) ||
        _effectiveWidth(viewportWidth) == previousEffectiveWidth) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _transition == _WidthTransition.reset) {
          setState(() => _transition = _WidthTransition.idle);
        }
      });
    }
  }

  Duration _duration(BuildContext context) {
    if (_resizing || _transition == _WidthTransition.direct) {
      return Duration.zero;
    }
    if (_transition == _WidthTransition.reset) {
      return MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : _resetDuration;
    }
    return _layoutDuration;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return _buildForWidth(context, viewportWidth);
      },
    );
  }

  Widget _buildForWidth(BuildContext context, double viewportWidth) {
    final effectiveWidth = _effectiveWidth(viewportWidth);
    final targetWidth = widget.dismissible && !widget.docked
        ? 0.0
        : effectiveWidth;
    final duration = _duration(context);
    final showResizeHandle =
        widget.resizable &&
        (!widget.dismissible || widget.docked) &&
        targetWidth > 0;
    final effectiveMaximum = _effectiveMaximum(viewportWidth);
    String semanticsValue(double width) =>
        widget.resizeSemanticsValueBuilder?.call(width) ??
        width.round().toString();

    return Stack(
      children: [
        Row(
          children: [
            AnimatedContainer(
              key: const ValueKey<String>('tablet-drawer-panel'),
              duration: duration,
              curve: Curves.easeOutCubic,
              onEnd: _handleAnimationEnd,
              width: targetWidth,
              decoration: BoxDecoration(
                color: widget.drawerColor,
                border: widget.composeDrawerChrome
                    ? BorderDirectional(
                        end: BorderSide(
                          color: widget.dividerColor,
                          width: BorderWidth.thin,
                        ),
                      )
                    : null,
              ),
              child: ClipRect(
                child: IgnorePointer(
                  ignoring: widget.dismissible && !widget.docked,
                  child: widget.drawer,
                ),
              ),
            ),
            Expanded(child: widget.content),
          ],
        ),
        if (showResizeHandle)
          AnimatedPositionedDirectional(
            key: const ValueKey<String>('tablet-sidebar-resize-position'),
            duration: duration,
            curve: Curves.easeOutCubic,
            start: targetWidth - (_resizeHandleHitWidth / 2),
            top: 0,
            bottom: 0,
            width: _resizeHandleHitWidth,
            child: _TabletSidebarResizeHandle(
              active: _resizing,
              dividerColor: widget.dividerColor,
              activeColor: widget.activeColor,
              semanticsLabel: widget.resizeSemanticsLabel,
              semanticsHint: widget.resizeSemanticsHint,
              semanticsValue: semanticsValue(effectiveWidth),
              semanticsIncreasedValue: semanticsValue(
                (effectiveWidth + _resizeStep)
                    .clamp(widget.minimumWidth, effectiveMaximum)
                    .toDouble(),
              ),
              semanticsDecreasedValue: semanticsValue(
                (effectiveWidth - _resizeStep)
                    .clamp(widget.minimumWidth, effectiveMaximum)
                    .toDouble(),
              ),
              onDragStart: () => _beginResize(viewportWidth),
              onDragUpdate: (delta) => _updateResize(delta, viewportWidth),
              onDragEnd: _endResize,
              onDragCancel: _cancelResize,
              onReset: () => _resetWidth(viewportWidth),
              onIncrease: () => _adjustWidth(_resizeStep, viewportWidth),
              onDecrease: () => _adjustWidth(-_resizeStep, viewportWidth),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _keyboardCommitTimer?.cancel();
    super.dispose();
  }
}

class _TabletSidebarResizeHandle extends StatefulWidget {
  const _TabletSidebarResizeHandle({
    required this.active,
    required this.dividerColor,
    required this.activeColor,
    required this.semanticsLabel,
    required this.semanticsHint,
    required this.semanticsValue,
    required this.semanticsIncreasedValue,
    required this.semanticsDecreasedValue,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.onReset,
    required this.onIncrease,
    required this.onDecrease,
  });

  final bool active;
  final Color dividerColor;
  final Color activeColor;
  final String? semanticsLabel;
  final String? semanticsHint;
  final String semanticsValue;
  final String semanticsIncreasedValue;
  final String semanticsDecreasedValue;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;
  final VoidCallback onReset;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;

  @override
  State<_TabletSidebarResizeHandle> createState() =>
      _TabletSidebarResizeHandleState();
}

class _TabletSidebarResizeHandleState
    extends State<_TabletSidebarResizeHandle> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.active || _hovered || _focused;
    final gripColor = highlighted
        ? widget.activeColor.withValues(alpha: 0.72)
        : widget.dividerColor;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AnimationDuration.microInteraction;
    final dragDirection = Directionality.of(context) == TextDirection.rtl
        ? -1.0
        : 1.0;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft): dragDirection < 0
            ? widget.onIncrease
            : widget.onDecrease,
        const SingleActivator(LogicalKeyboardKey.arrowRight): dragDirection < 0
            ? widget.onDecrease
            : widget.onIncrease,
      },
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.resizeColumn,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: Semantics(
          container: true,
          focusable: true,
          label: widget.semanticsLabel,
          hint: widget.semanticsHint,
          value: widget.semanticsValue,
          increasedValue: widget.semanticsIncreasedValue,
          decreasedValue: widget.semanticsDecreasedValue,
          onTap: widget.onReset,
          onIncrease: widget.onIncrease,
          onDecrease: widget.onDecrease,
          child: Listener(
            onPointerCancel: (_) => widget.onDragCancel(),
            child: GestureDetector(
              key: const ValueKey<String>('tablet-sidebar-resize-handle'),
              behavior: HitTestBehavior.translucent,
              dragStartBehavior: DragStartBehavior.down,
              onDoubleTap: widget.onReset,
              onHorizontalDragStart: (_) => widget.onDragStart(),
              onHorizontalDragUpdate: (details) => widget.onDragUpdate(
                (details.primaryDelta ?? 0) * dragDirection,
              ),
              onHorizontalDragEnd: (_) => widget.onDragEnd(),
              onHorizontalDragCancel: widget.onDragCancel,
              child: Center(
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  width: highlighted ? 3 : 2,
                  height: 36,
                  decoration: BoxDecoration(
                    color: gripColor,
                    borderRadius: BorderRadius.circular(AppBorderRadius.pill),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
