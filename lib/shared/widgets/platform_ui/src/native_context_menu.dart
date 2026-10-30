import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/services/haptic_service.dart';
import '../../../../core/services/ios_native_dropdown_bridge.dart';
import 'adaptive_layout.dart';

/// The unobscured part of a viewport containing floating controls.
class NativeContextMenuViewport extends InheritedWidget {
  const NativeContextMenuViewport({
    super.key,
    required this.padding,
    required super.child,
  });

  final EdgeInsets padding;

  static Rect? boundsOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<NativeContextMenuViewport>();
    final box = element?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final scope = element!.widget as NativeContextMenuViewport;
    return scope.padding.deflateRect(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  bool updateShouldNotify(NativeContextMenuViewport oldWidget) =>
      padding != oldWidget.padding;
}

/// Shows UIKit's floating menu without rebuilding or relaying out the child.
/// Flutter's gesture arena continues to own normal taps and scrolling.
class NativeContextMenu extends StatefulWidget {
  const NativeContextMenu({
    super.key,
    required this.actions,
    required this.child,
    required this.fallbackBuilder,
  });

  final List<AdaptiveContextMenuAction> actions;
  final Widget child;
  final WidgetBuilder fallbackBuilder;

  @override
  State<NativeContextMenu> createState() => _NativeContextMenuState();
}

class _NativeContextMenuState extends State<NativeContextMenu> {
  static int _nextRequestId = 0;
  final _bridge = IosNativeDropdownBridge.instance;
  final _boundaryKey = GlobalKey();
  late final Future<bool> _ready;
  int? _requestId;
  OverlayEntry? _focusOverlay;
  bool _fallback = false;

  @override
  void initState() {
    super.initState();
    _ready = _bridge.initializeContextMenu();
    unawaited(
      _ready.then((ready) {
        if (!ready && mounted) setState(() => _fallback = true);
      }),
    );
  }

  @override
  void dispose() {
    _clearFocus();
    final requestId = _requestId;
    if (requestId != null) {
      unawaited(_bridge.cancelContextMenu(requestId));
    }
    super.dispose();
  }

  Future<void> _show() async {
    _clearFocus();
    final previous = _requestId;
    if (previous != null) unawaited(_bridge.cancelContextMenu(previous));
    final requestId = _requestId = ++_nextRequestId;
    try {
      await _captureAndShow(requestId);
    } catch (_) {
      if (!mounted) return;
      setState(() => _fallback = true);
    } finally {
      if (mounted && _requestId == requestId) {
        _requestId = null;
      }
    }
  }

  void _clearFocus([OverlayEntry? expected]) {
    final entry = _focusOverlay;
    if (entry == null || (expected != null && !identical(entry, expected))) {
      return;
    }
    _focusOverlay = null;
    entry.remove();
    entry.dispose();
  }

  Future<void> _captureAndShow(int requestId) async {
    final actions = List.of(widget.actions);
    final ready = await _ready;
    if (!mounted || !ready || _requestId != requestId) {
      return;
    }
    unawaited(ConduitHaptics.heavyImpact());
    // Capture the latest paint with the same child and constraints.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _requestId != requestId) return;
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! _PreviewBoundary || !boundary.hasSize) return;
    final bounds = boundary.localToGlobal(Offset.zero) & boundary.size;
    var rect = bounds;
    final viewport = RenderAbstractViewport.maybeOf(boundary);
    if (viewport case final RenderBox box) {
      rect = rect.intersect(box.localToGlobal(Offset.zero) & box.size);
    }
    if (NativeContextMenuViewport.boundsOf(context) case final visibleBounds?) {
      rect = rect.intersect(visibleBounds);
    }
    rect = rect.intersect(Offset.zero & MediaQuery.sizeOf(context));
    if (rect.isEmpty) return;
    // UIKit needs a visible preview to anchor its menu. Capture only the
    // visible pixels; never rebuild the bubble under different constraints.
    final image = await boundary.capture(
      rect.shift(-bounds.topLeft),
      pixelRatio: math.min(View.of(context).devicePixelRatio, 3),
    );
    OverlayEntry? focus;
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted || _requestId != requestId || bytes == null) return;
      final overlay = Overlay.of(context, rootOverlay: true);
      final box = overlay.context.findRenderObject()! as RenderBox;
      final previewRect = Rect.fromPoints(
        box.globalToLocal(rect.topLeft),
        box.globalToLocal(rect.bottomRight),
      );
      // Match context-menu focus without rebuilding the selected message.
      // Only its visible pixels stay bright above the dimmed background.
      focus = OverlayEntry(
        builder: (_) => Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: ModalBarrier(
                color: const Color(0x33000000),
                onDismiss: () =>
                    unawaited(_bridge.cancelContextMenu(requestId)),
              ),
            ),
            Positioned.fromRect(
              rect: previewRect,
              child: IgnorePointer(
                child: RawImage(image: image, fit: BoxFit.fill),
              ),
            ),
          ],
        ),
      );
      _focusOverlay = focus;
      overlay.insert(focus);
      // UIKit snapshots the host view when presenting its menu. Paint the
      // focus treatment first so that snapshot includes it.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _requestId != requestId) return;
      final selected = await _bridge.showContextMenu(
        requestId: requestId,
        sourceRect: rect,
        previewPng: bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
        options: [
          for (var i = 0; i < actions.length; i++)
            IosNativeDropdownOption(
              id: '$i',
              label: actions[i].title,
              sfSymbol: actions[i].iosSymbol,
              enabled: !actions[i].isDisabled,
              destructive: actions[i].isDestructive,
            ),
        ],
      );
      if (!mounted || _requestId != requestId) return;
      final index = int.tryParse(selected ?? '');
      if (index != null &&
          index >= 0 &&
          index < actions.length &&
          !actions[index].isDisabled) {
        actions[index].onPressed();
      }
    } finally {
      if (focus != null) _clearFocus(focus);
      image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => _fallback
      ? widget.fallbackBuilder(context)
      : Semantics(
          container: true,
          customSemanticsActions: {
            for (final action in widget.actions)
              if (!action.isDisabled)
                CustomSemanticsAction(label: action.title): action.onPressed,
          },
          child: GestureDetector(
            onLongPress: () => unawaited(_show()),
            child: _Preview(key: _boundaryKey, child: widget.child),
          ),
        );
}

class _Preview extends SingleChildRenderObjectWidget {
  const _Preview({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _PreviewBoundary();
}

class _PreviewBoundary extends RenderRepaintBoundary {
  Future<ui.Image> capture(Rect bounds, {required double pixelRatio}) {
    assert(!debugNeedsPaint);
    final currentLayer = layer;
    if (currentLayer is! OffsetLayer) {
      throw StateError('The message has not been painted');
    }
    return currentLayer.toImage(bounds, pixelRatio: pixelRatio);
  }
}
