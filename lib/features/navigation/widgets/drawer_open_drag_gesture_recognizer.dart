import 'package:flutter/gestures.dart';

/// Horizontal drag recognizer used by the responsive drawer's prioritized
/// opening arenas.
final class DrawerOpenDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  DrawerOpenDragGestureRecognizer({super.debugOwner});

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
  ) =>
      !_directionDisqualified &&
      globalDistanceMoved >
          computeHitSlop(pointerDeviceKind, gestureSettings) &&
      globalDistanceMoved > _verticalDistance * axisBias;

  @override
  String get debugDescription => 'drawer open horizontal drag';
}
