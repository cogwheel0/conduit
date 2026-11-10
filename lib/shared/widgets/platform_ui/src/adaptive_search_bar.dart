import 'dart:async';

import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNSearchBar, CNSearchBarController;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;

/// The iOS 26 system search bar, kept in step with a Flutter
/// [TextEditingController] and [FocusNode].
///
/// This is cupertino_native_better's [CNSearchBar]: a SwiftUI field on
/// Liquid Glass. What the person types reaches [controller] and
/// [onChanged]; text the app puts in [controller] (a saved query, or
/// clearing it) reaches the field.
///
/// [focusNode] stands for the field in Flutter's focus tree, which never
/// hears of the native field's focus by itself. Requesting the node brings
/// up the field's keyboard, and a tap on the field gives the node focus. The
/// field puts its keyboard away whenever the node loses focus: unfocusing it,
/// a list that hides the keyboard when it is dragged
/// (`ScrollViewKeyboardDismissBehavior.onDrag`), another route. Flutter alone
/// cannot hide a native field's keyboard, so this widget does it for them.
///
/// Build it only where `PlatformUiCapabilities.usesNativeIOS26` is true.
class AdaptiveNativeSearchBar extends StatefulWidget {
  const AdaptiveNativeSearchBar({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.onChanged,
    this.focusNode,
    this.height = 44,
  });

  final TextEditingController controller;

  /// Shown while the field is empty. The native field reads it as its
  /// VoiceOver label.
  final String placeholder;

  /// Called with the new text after each edit the person makes, once
  /// [controller] holds it, including the empty text when they clear the
  /// field, as `CupertinoSearchTextField` reports its clear button. Text the
  /// app sets is not reported.
  final ValueChanged<String> onChanged;

  /// The field's focus; this widget makes its own when null.
  final FocusNode? focusNode;

  final double height;

  @override
  State<AdaptiveNativeSearchBar> createState() =>
      _AdaptiveNativeSearchBarState();
}

class _AdaptiveNativeSearchBarState extends State<AdaptiveNativeSearchBar> {
  final _native = CNSearchBarController();

  FocusNode? _ownFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownFocusNode ??= FocusNode(debugLabel: 'AdaptiveNativeSearchBar'));

  /// The text the native field holds, as far as it has said. A new field
  /// starts empty.
  String _nativeText = '';

  /// Text the app set that the native field has not reported yet.
  String? _pendingText;

  /// Every text sent to the field that it has not reported back yet, oldest
  /// first. The field reports each one, in order, as it takes it; those
  /// reports are the app's own writes, not edits. Text the app replaced
  /// before it could be sent never reaches the field, so it is not here.
  final List<String> _sent = [];

  /// Whether the app asked for the keyboard and focus requests are still
  /// being sent.
  bool _pendingFocus = false;

  /// Sends what is pending again until the native field has it.
  Timer? _retry;

  /// Retries left before what is still pending is dropped.
  int _retriesLeft = 0;

  /// Focus requests sent again for the pending focus.
  int _focusSends = 0;

  static const _retryInterval = Duration(milliseconds: 100);
  static const _maxRetries = 30;

  /// How long to wait before each further focus request once the view
  /// exists. A request that arrives before the SwiftUI field is first drawn
  /// is dropped, the field says nothing either way, and on a busy device the
  /// first drawing can take a while.
  static const _focusResendDelays = [
    Duration(milliseconds: 100),
    Duration(milliseconds: 200),
    Duration(milliseconds: 400),
    Duration(milliseconds: 800),
  ];

  /// Bumped to replace the native field with a new one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    if (widget.controller.text.isNotEmpty) _setText(widget.controller.text);
  }

  @override
  void didUpdateWidget(covariant AdaptiveNativeSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _onControllerChanged();
    }
    // The placeholder is fixed when the native field is created: a new
    // field shows the new one, and is given the text and focus the old one
    // had.
    if (oldWidget.placeholder != widget.placeholder) {
      _generation++;
      _nativeText = '';
      final text = widget.controller.text;
      _pendingText = text.isEmpty ? null : text;
      _sent.clear();
      _pendingFocus = _focusNode.hasFocus;
      _focusSends = 0;
      _retriesLeft = _maxRetries;
      // Until the old field has gone, what is sent would reach it.
      _retry?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    _ownFocusNode?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final text = widget.controller.text;
    if (text != (_pendingText ?? _nativeText)) _setText(text);
  }

  void _setText(String text) {
    _pendingText = text;
    _retriesLeft = _maxRetries;
    _send();
  }

  void _requestNativeFocus() {
    _pendingFocus = true;
    _focusSends = 0;
    _retriesLeft = _maxRetries;
    _send();
  }

  /// Sends the pending text and focus once the native field's view exists,
  /// and again until the field has them or the retries run out.
  void _send() {
    _retry?.cancel();
    if (!mounted) return;
    // The field's controller drops what it is given until its view exists.
    // The view joins Flutter's focus tree, below the node, once it does.
    var delay = _retryInterval;
    if (_focusNode.descendants.isNotEmpty) {
      if (_pendingText case final text?) {
        if (_sent.isEmpty || _sent.last != text) _sent.add(text);
        unawaited(_native.setText(text).catchError((Object _) {}));
      }
      if (_pendingFocus) {
        unawaited(_native.focus().catchError((Object _) {}));
        if (_focusSends < _focusResendDelays.length) {
          if (_pendingText == null) delay = _focusResendDelays[_focusSends];
          _focusSends++;
        } else {
          _pendingFocus = false;
        }
      }
    }
    if (_pendingText == null && !_pendingFocus) return;
    if (_retriesLeft-- <= 0) {
      _pendingText = null;
      _pendingFocus = false;
      return;
    }
    _retry = Timer(delay, _send);
  }

  void _onNativeChanged(String text) {
    // A text sent again that the field and the app already had changes
    // nothing. A new field starts empty while the app may still hold text,
    // so an empty report can still be an edit.
    if (text == _nativeText && text == widget.controller.text) return;
    _nativeText = text;
    final echoed = _sent.indexOf(text);
    if (echoed >= 0 || text == _pendingText) {
      // The field took text the app set, and every write before it.
      if (echoed >= 0) _sent.removeRange(0, echoed + 1);
      if (text == _pendingText) _pendingText = null;
      return;
    }
    // The person edited the field: that wins over anything still on its way.
    _sent.clear();
    _pendingText = null;
    if (widget.controller.text != text) {
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    widget.onChanged(text);
  }

  void _onFocusChange(bool focused) {
    final tapped = _focusedByTap;
    _focusedByTap = false;
    if (!focused) {
      _pendingFocus = false;
      unawaited(_native.unfocus().catchError((Object _) {}));
    } else if (!tapped) {
      _requestNativeFocus();
    }
  }

  /// Where a pointer went down on the field, until it lifts.
  Offset? _pointerDown;

  /// Whether the node is taking focus for a tap on the field, which the
  /// native field answers by itself.
  bool _focusedByTap = false;

  /// A tap on the field focuses it natively, which Flutter never hears of:
  /// the node takes focus too, so that whatever takes focus away from it
  /// later reaches the field. A drag that starts on the field is not a tap.
  void _onPointerUp(PointerUpEvent event) {
    final down = _pointerDown;
    _pointerDown = null;
    if (down == null ||
        (event.position - down).distance > kTouchSlop ||
        _focusNode.hasFocus) {
      return;
    }
    _focusedByTap = true;
    _focusNode.requestFocus();
    // Flutter applies the focus change in a microtask queued before this one.
    scheduleMicrotask(() => _focusedByTap = false);
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    return Focus(
      focusNode: _focusNode,
      onFocusChange: _onFocusChange,
      child: Listener(
        onPointerDown: (event) => _pointerDown = event.position,
        onPointerUp: _onPointerUp,
        onPointerCancel: (_) => _pointerDown = null,
        child: SizedBox(
          height: widget.height,
          child: CNSearchBar(
            key: ValueKey<int>(_generation),
            controller: _native,
            placeholder: widget.placeholder,
            onChanged: (text) {
              // A field being replaced may still report.
              if (generation == _generation) _onNativeChanged(text);
            },
            expandable: false,
            expandedHeight: widget.height,
            // The package's Cancel button collapses a bar that cannot expand
            // again, and the Flutter field it replaces has none.
            showCancelButton: false,
            // The magnifying glass keeps this colour after a theme switch, so
            // it is the grey both appearances share.
            tint: CupertinoColors.systemGrey,
            // Hiding the field under a modal would recreate it afterwards
            // with the text it had, and text the app set meanwhile, which
            // waits only so long for the field, would not reach it.
            autoHideOnModal: false,
          ),
        ),
      ),
    );
  }
}
