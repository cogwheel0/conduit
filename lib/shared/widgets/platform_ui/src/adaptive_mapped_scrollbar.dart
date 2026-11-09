import 'dart:ui' show SemanticsAction;

import 'platform_ui_capabilities.dart';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

/// Maps native scrollbar painting and gestures onto caller-provided metrics.
/// The content keeps its own pixel position, gestures, and accessibility.
class AdaptiveMappedScrollbar extends StatefulWidget {
  const AdaptiveMappedScrollbar({
    required this.ownerGeneration,
    required this.metrics,
    required this.onSeek,
    required this.onDragStart,
    required this.onDragEnd,
    required this.child,
    super.key,
  });

  final int ownerGeneration;
  final FixedScrollMetrics? Function() metrics;
  final ValueChanged<double> onSeek;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final Widget child;

  @override
  State<AdaptiveMappedScrollbar> createState() =>
      _AdaptiveMappedScrollbarState();
}

class _AdaptiveMappedScrollbarState extends State<AdaptiveMappedScrollbar>
    with TickerProviderStateMixin
    implements ScrollContext {
  final _controller = ScrollController(keepScrollOffset: false);
  late final ScrollPositionWithSingleContext _position;
  BuildContext? _notificationContext;
  BuildContext? _scrollableContext;
  final _notifications = <ScrollNotification>[];
  bool _updateScheduled = false;
  bool _metricsChanged = false;

  @override
  void initState() {
    super.initState();
    _position = ScrollPositionWithSingleContext(
      physics: const ClampingScrollPhysics(),
      context: this,
      keepScrollOffset: false,
    );
    _controller.attach(_position);
    _position.addListener(_seek);
    _position.isScrollingNotifier.addListener(_activityChanged);
  }

  @override
  void didUpdateWidget(covariant AdaptiveMappedScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerGeneration != widget.ownerGeneration) {
      _position.goIdle();
      _notifications.clear();
      _metricsChanged = true;
      _scheduleUpdate();
    }
  }

  void _seek() => widget.onSeek(_position.pixels);

  void _activityChanged() {
    if (_position.isScrollingNotifier.value) {
      widget.onDragStart();
    } else {
      widget.onDragEnd();
    }
  }

  FixedScrollMetrics? _syncMetrics() {
    final metrics = widget.metrics();
    if (metrics == null) return null;
    _position.correctPixels(metrics.pixels);
    _position.applyViewportDimension(metrics.viewportDimension);
    _position.applyContentDimensions(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    return metrics;
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    _scrollableContext = notification.context;
    if (notification is UserScrollNotification) {
      // Keep ancestor keyboard-dismiss listeners informed without sending
      // physical content metrics through the mapped scrollbar.
      notification.dispatch(context);
      return true;
    }
    _notifications.add(notification);
    _scheduleUpdate();
    return true;
  }

  bool _metricsNotification(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    _scrollableContext = notification.context;
    _metricsChanged = true;
    _scheduleUpdate();
    return true;
  }

  void _scheduleUpdate() {
    if (_updateScheduled) return;
    _updateScheduled = true;
    // Scroll activities can change during layout. Read row transforms only
    // after the entire render tree has finished laying out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted) return;
      final metrics = _syncMetrics();
      final target = _notificationContext;
      final notifications = List<ScrollNotification>.of(_notifications);
      _notifications.clear();
      final metricsChanged = _metricsChanged;
      _metricsChanged = false;
      if (metrics == null || target == null) return;
      if (metricsChanged) {
        ScrollMetricsNotification(
          metrics: metrics,
          context: target,
        ).dispatch(target);
      }
      for (final notification in notifications) {
        final translated = switch (notification) {
          ScrollStartNotification() => ScrollStartNotification(
            metrics: metrics,
            context: target,
            dragDetails: notification.dragDetails,
          ),
          ScrollEndNotification() => ScrollEndNotification(
            metrics: metrics,
            context: target,
            dragDetails: notification.dragDetails,
          ),
          _ => ScrollUpdateNotification(metrics: metrics, context: target),
        };
        translated.dispatch(target);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final content = Builder(
      builder: (context) {
        _notificationContext = context;
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: _metricsNotification,
          child: NotificationListener<ScrollNotification>(
            onNotification: _scrollNotification,
            child: Listener(
              onPointerDown: (_) => _position.goIdle(),
              child: widget.child,
            ),
          ),
        );
      },
    );
    return PlatformInfo.isIOS
        ? CupertinoScrollbar(controller: _controller, child: content)
        : Scrollbar(controller: _controller, interactive: true, child: content);
  }

  @override
  void dispose() {
    _position.removeListener(_seek);
    _position.isScrollingNotifier.removeListener(_activityChanged);
    _controller.detach(_position);
    _position.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  // Native track taps resolve the content Scrollable for page increments.
  BuildContext? get notificationContext => _scrollableContext?.mounted == true
      ? _scrollableContext
      : _notificationContext;
  @override
  BuildContext get storageContext => context;
  @override
  TickerProvider get vsync => this;
  @override
  AxisDirection get axisDirection => AxisDirection.down;
  @override
  double get devicePixelRatio => MediaQuery.devicePixelRatioOf(context);

  // The content Scrollable owns hit testing, drag recognition, semantics,
  // and restoration. This position only serves the platform scrollbar's own
  // gestures; its mapped coordinates must never replace those pixel values.
  @override
  void setIgnorePointer(bool value) {}
  @override
  void setCanDrag(bool value) {}
  @override
  void setSemanticsActions(Set<SemanticsAction> actions) {}
  @override
  void saveOffset(double offset) {}
}
