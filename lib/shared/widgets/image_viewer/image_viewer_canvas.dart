import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';

import 'package:material_ui/material_ui.dart';

import '../../theme/theme_extensions.dart';

/// One scale recognizer owns pinch, pan, paging, and dismissal. Paging and
/// dismissal are enabled only at the fitted scale, so they cannot steal a pan.
class ImageViewerCanvas extends StatefulWidget {
  const ImageViewerCanvas({
    super.key,
    required this.child,
    required this.onTap,
    required this.onDismiss,
    required this.onPage,
    required this.onZoomSettled,
    required this.zoomLabel,
    required this.resetLabel,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  final ValueChanged<int> onPage;
  final ValueChanged<double> onZoomSettled;
  final String zoomLabel;
  final String resetLabel;

  @override
  State<ImageViewerCanvas> createState() => _ImageViewerCanvasState();
}

class _ImageViewerCanvasState extends State<ImageViewerCanvas>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _animation = AnimationController.unbounded(
    vsync: this,
    duration: AnimationDuration.fast,
  )..addListener(_animate);
  Matrix4Tween? _zoomTween;
  Tween<Offset>? _dragTween;
  Offset _drag = Offset.zero;
  Offset _tap = Offset.zero;
  Offset _startFocal = Offset.zero;
  Offset _startDrag = Offset.zero;
  bool _springing = false;
  Size _size = Size.zero;
  bool _pinching = false;
  bool _startedFitted = true;
  Axis? _axis;

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  void _animate() {
    final t = _springing
        ? _animation.value
        : Curves.easeOutCubic.transform(
            _animation.value.clamp(0.0, 1.0).toDouble(),
          );
    if (_zoomTween case final tween?) _transform.value = tween.transform(t);
    if (_dragTween case final tween?) {
      setState(() => _drag = tween.transform(t));
    }
  }

  void toggleZoom() {
    _animation.stop();
    _springing = false;
    setState(() => _drag = Offset.zero);
    _dragTween = null;
    final target = Matrix4.identity();
    if (!_zoomed) {
      final focal = _tap == Offset.zero ? _size.center(Offset.zero) : _tap;
      target
        ..setEntry(0, 0, 2.5)
        ..setEntry(1, 1, 2.5)
        ..setTranslationRaw(-focal.dx * 1.5, -focal.dy * 1.5, 0);
    }
    if (context.reduceMotion) {
      _transform.value = target;
      setState(() {});
      widget.onZoomSettled(target.getMaxScaleOnAxis());
    } else {
      _zoomTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
      _animation.value = 0;
      _animation
          .animateTo(1, duration: AnimationDuration.fast)
          .whenCompleteOrCancel(() {
            if (!mounted) return;
            setState(() {});
            widget.onZoomSettled(_transform.value.getMaxScaleOnAxis());
          });
    }
  }

  void _snapBack([Offset velocity = Offset.zero]) {
    if (_drag == Offset.zero) return;
    _zoomTween = null;
    if (context.reduceMotion) {
      setState(() => _drag = Offset.zero);
    } else {
      _springing = true;
      _dragTween = Tween(begin: _drag, end: Offset.zero);
      final distance = _axis == Axis.horizontal ? _drag.dx : _drag.dy;
      final speed = _axis == Axis.horizontal ? velocity.dx : velocity.dy;
      _animation.animateWith(
        SpringSimulation(
          SpringDescription.withDurationAndBounce(
            duration: AnimationDuration.slow,
            bounce: .2,
          ),
          0,
          1,
          distance.abs() < 1
              ? 0.0
              : (-speed / distance).clamp(-5.0, 5.0).toDouble(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_size != constraints.biggest) {
          _size = constraints.biggest;
          _animation.stop();
          _transform.value = Matrix4.identity();
          _drag = Offset.zero;
        }
        return Semantics(
          image: true,
          customSemanticsActions: {
            CustomSemanticsAction(label: widget.zoomLabel): toggleZoom,
            CustomSemanticsAction(label: widget.resetLabel): () {
              _animation.stop();
              _transform.value = Matrix4.identity();
              setState(() => _drag = Offset.zero);
              widget.onZoomSettled(1);
            },
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onDoubleTapDown: (details) => _tap = details.localPosition,
            onDoubleTap: toggleZoom,
            child: Transform.translate(
              offset: _drag,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 5,
                panEnabled: _zoomed,
                onInteractionStart: (details) {
                  _animation.stop();
                  _zoomTween = null;
                  _dragTween = null;
                  _startedFitted = !_zoomed;
                  _pinching = details.pointerCount > 1;
                  _startFocal = details.focalPoint;
                  _startDrag = _drag;
                  _axis = null;
                },
                onInteractionUpdate: (details) {
                  if (details.pointerCount > 1 ||
                      (details.scale - 1).abs() > .01) {
                    _pinching = true;
                    setState(() => _drag = Offset.zero);
                    return;
                  }
                  if (!_startedFitted || _pinching) return;
                  final delta = details.focalPoint - _startFocal + _startDrag;
                  if (_axis == null && delta.distance > 12) {
                    _axis = delta.dx.abs() > delta.dy.abs()
                        ? Axis.horizontal
                        : Axis.vertical;
                  }
                  setState(() {
                    _drag = switch (_axis) {
                      Axis.horizontal => Offset(delta.dx, 0),
                      Axis.vertical => Offset(0, delta.dy),
                      null => Offset.zero,
                    };
                  });
                },
                onInteractionEnd: (details) {
                  if (_startedFitted && !_pinching) {
                    final velocity = details.velocity.pixelsPerSecond;
                    if (_axis == Axis.vertical &&
                        (_drag.dy.abs() > math.min(140, _size.height * .18) ||
                            (_drag.dy.abs() > 32 && velocity.dy.abs() > 900))) {
                      widget.onDismiss();
                      return;
                    }
                    if (_axis == Axis.horizontal &&
                        (_drag.dx.abs() > math.min(100, _size.width * .25) ||
                            (_drag.dx.abs() > 32 && velocity.dx.abs() > 700))) {
                      widget.onPage(_drag.dx < 0 ? 1 : -1);
                    }
                  }
                  _snapBack(details.velocity.pixelsPerSecond);
                  setState(() {});
                  widget.onZoomSettled(_transform.value.getMaxScaleOnAxis());
                },
                child: SizedBox.fromSize(size: _size, child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}
