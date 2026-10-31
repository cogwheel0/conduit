import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

/// Uses UIKit's loupe without replacing Flutter's text editing or gestures.
///
/// Install on iOS 26+ fields through [configuration]. UIKit owns the lens's
/// appearance, magnification and placement; older or unavailable hosts retain
/// the Cupertino magnifier.
class IosTextMagnifier extends StatefulWidget {
  const IosTextMagnifier({
    super.key,
    required this.controller,
    required this.magnifierInfo,
  });

  static final configuration = TextMagnifierConfiguration(
    magnifierBuilder: (context, controller, magnifierInfo) =>
        IosTextMagnifier(controller: controller, magnifierInfo: magnifierInfo),
  );

  final MagnifierController controller;
  final ValueNotifier<MagnifierInfo> magnifierInfo;

  @override
  State<IosTextMagnifier> createState() => _IosTextMagnifierState();
}

class _IosTextMagnifierState extends State<IosTextMagnifier> {
  static const _channel = MethodChannel('app.cogwheel.conduit/text_magnifier');
  static int _nextSession = 0;

  final int _session = _nextSession++;
  bool _started = false;
  bool _nativeReady = false;
  bool _fallback = false;

  @override
  void initState() {
    super.initState();
    widget.magnifierInfo.addListener(_move);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_begin());
    } else {
      _move();
    }
  }

  @override
  void didUpdateWidget(IosTextMagnifier oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.magnifierInfo != widget.magnifierInfo) {
      oldWidget.magnifierInfo.removeListener(_move);
      widget.magnifierInfo.addListener(_move);
      _move();
    }
  }

  Map<String, Object> get _geometry {
    final view = View.of(context);
    final viewSize = view.physicalSize / view.devicePixelRatio;
    final info = widget.magnifierInfo.value;
    final caret = info.caretRect;
    return {
      'session': _session,
      'viewWidth': viewSize.width,
      'viewHeight': viewSize.height,
      'x': info.globalGesturePosition.dx,
      'y': info.globalGesturePosition.dy,
      'caretX': caret.left,
      'caretY': caret.top,
      'caretWidth': caret.width,
      'caretHeight': caret.height,
    };
  }

  Future<bool> _invoke(String method, Map<String, Object> arguments) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _begin() async {
    final shown = await _invoke('begin', _geometry);
    if (!mounted) return;
    _nativeReady = shown;
    if (shown) {
      // The finger can move while the platform reply is in flight.
      _move();
    } else {
      setState(() => _fallback = true);
    }
  }

  void _move() {
    if (!_nativeReady) return;
    unawaited(_moveNative());
  }

  Future<void> _moveNative() async {
    final moved = await _invoke('move', _geometry);
    if (!moved && mounted && !_fallback) {
      _nativeReady = false;
      unawaited(_invoke('end', {'session': _session}));
      setState(() => _fallback = true);
    }
  }

  @override
  void dispose() {
    widget.magnifierInfo.removeListener(_move);
    // Session ownership prevents a departing overlay from hiding a newer one.
    unawaited(_invoke('end', {'session': _session}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _fallback
      ? CupertinoTextMagnifier(
          controller: widget.controller,
          magnifierInfo: widget.magnifierInfo,
        )
      : const SizedBox.shrink();
}
