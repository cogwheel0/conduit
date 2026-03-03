import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Controller for [NativeChatInput].
class NativeChatInputController {
  _NativeChatInputState? _state;

  void _attach(_NativeChatInputState state) {
    _state = state;
  }

  void _detach(_NativeChatInputState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  Future<void> focus() async {
    await _state?._invokeMethod('focus');
  }

  Future<void> unfocus() async {
    await _state?._invokeMethod('unfocus');
  }

  Future<void> setText(String text) async {
    await _state?._invokeMethod('setText', {'text': text});
  }

  Future<void> setSelection(TextSelection selection) async {
    await _state?._invokeMethod('setSelection', {
      'baseOffset': selection.baseOffset,
      'extentOffset': selection.extentOffset,
    });
  }

  Future<void> clear() async {
    await setText('');
  }
}

/// Native platform chat input using platform views on iOS and Android.
class NativeChatInput extends StatefulWidget {
  const NativeChatInput({
    super.key,
    required this.controller,
    required this.text,
    required this.selection,
    required this.placeholder,
    required this.enabled,
    required this.sendOnEnter,
    this.showInputAccessoryBar = false,
    this.accessoryCanSend = false,
    this.accessoryCanUseMic = false,
    this.accessoryIsRecording = false,
    required this.onChanged,
    required this.onSelectionChanged,
    required this.onFocusChanged,
    required this.onAccessoryAction,
    this.onHeightChanged,
    this.onSubmitted,
    this.minHeight = 44,
    this.maxHeight = 120,
    this.textColor,
    this.placeholderColor,
    this.fontSize = 17,
  });

  final NativeChatInputController controller;
  final String text;
  final TextSelection selection;
  final String placeholder;
  final bool enabled;
  final bool sendOnEnter;
  final bool showInputAccessoryBar;
  final bool accessoryCanSend;
  final bool accessoryCanUseMic;
  final bool accessoryIsRecording;
  final ValueChanged<String> onChanged;
  final ValueChanged<TextSelection> onSelectionChanged;
  final ValueChanged<bool> onFocusChanged;
  final ValueChanged<String> onAccessoryAction;
  final ValueChanged<double>? onHeightChanged;
  final ValueChanged<String>? onSubmitted;
  final double minHeight;
  final double maxHeight;
  final Color? textColor;
  final Color? placeholderColor;
  final double fontSize;

  @override
  State<NativeChatInput> createState() => _NativeChatInputState();
}

class _NativeChatInputState extends State<NativeChatInput> {
  static const String _viewType = 'conduit/native_chat_input';

  MethodChannel? _channel;
  String _nativeText = '';

  @override
  void initState() {
    super.initState();
    _nativeText = widget.text;
    widget.controller._attach(this);
  }

  @override
  void didUpdateWidget(covariant NativeChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }

    if (widget.text != oldWidget.text && widget.text != _nativeText) {
      _invokeMethod('setText', {'text': widget.text});
    }

    if (widget.selection != oldWidget.selection) {
      _invokeMethod('setSelection', {
        'baseOffset': widget.selection.baseOffset,
        'extentOffset': widget.selection.extentOffset,
      });
    }

    if (widget.enabled != oldWidget.enabled) {
      _invokeMethod('setEnabled', {'enabled': widget.enabled});
    }

    if (widget.placeholder != oldWidget.placeholder) {
      _invokeMethod('setPlaceholder', {'placeholder': widget.placeholder});
    }

    if (widget.sendOnEnter != oldWidget.sendOnEnter) {
      _invokeMethod('setSendOnEnter', {'sendOnEnter': widget.sendOnEnter});
    }

    if (widget.showInputAccessoryBar != oldWidget.showInputAccessoryBar ||
        widget.accessoryCanSend != oldWidget.accessoryCanSend ||
        widget.accessoryCanUseMic != oldWidget.accessoryCanUseMic ||
        widget.accessoryIsRecording != oldWidget.accessoryIsRecording) {
      _invokeMethod('setAccessoryConfig', {
        'showInputAccessoryBar': widget.showInputAccessoryBar,
        'accessoryCanSend': widget.accessoryCanSend,
        'accessoryCanUseMic': widget.accessoryCanUseMic,
        'accessoryIsRecording': widget.accessoryIsRecording,
      });
    }

    if (widget.textColor?.toARGB32() != oldWidget.textColor?.toARGB32()) {
      _invokeMethod('setTextColor', {'color': widget.textColor?.toARGB32()});
    }

    if (widget.placeholderColor?.toARGB32() !=
        oldWidget.placeholderColor?.toARGB32()) {
      _invokeMethod('setPlaceholderColor', {
        'color': widget.placeholderColor?.toARGB32(),
      });
    }

    if (widget.fontSize != oldWidget.fontSize) {
      _invokeMethod('setFontSize', {'fontSize': widget.fontSize});
    }
  }

  @override
  void dispose() {
    widget.controller._detach(this);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _invokeMethod(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      await _channel?.invokeMethod(method, arguments);
    } catch (_) {
      // Ignore channel errors during platform view lifecycle transitions.
    }
  }

  Future<void> _handlePlatformCall(MethodCall call) async {
    final args = call.arguments as Map<dynamic, dynamic>?;
    switch (call.method) {
      case 'onTextChanged':
        final text = (args?['text'] as String?) ?? '';
        _nativeText = text;
        widget.onChanged(text);
        return;
      case 'onFocusChanged':
        final hasFocus = (args?['hasFocus'] as bool?) ?? false;
        widget.onFocusChanged(hasFocus);
        return;
      case 'onSelectionChanged':
        final base = (args?['baseOffset'] as num?)?.toInt() ?? -1;
        final extent = (args?['extentOffset'] as num?)?.toInt() ?? -1;
        widget.onSelectionChanged(
          TextSelection(baseOffset: base, extentOffset: extent),
        );
        return;
      case 'onHeightChanged':
        final height = (args?['height'] as num?)?.toDouble();
        if (height != null) {
          widget.onHeightChanged?.call(height);
        }
        return;
      case 'onSubmitted':
        final text = (args?['text'] as String?) ?? '';
        widget.onSubmitted?.call(text);
        return;
      case 'onAccessoryAction':
        final action = (args?['action'] as String?) ?? '';
        if (action.isNotEmpty) {
          widget.onAccessoryAction(action);
        }
        return;
      default:
        return;
    }
  }

  Map<String, dynamic> _creationParams(BuildContext context) {
    final isDark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    return {
      'text': widget.text,
      'placeholder': widget.placeholder,
      'enabled': widget.enabled,
      'sendOnEnter': widget.sendOnEnter,
      'showInputAccessoryBar': widget.showInputAccessoryBar,
      'accessoryCanSend': widget.accessoryCanSend,
      'accessoryCanUseMic': widget.accessoryCanUseMic,
      'accessoryIsRecording': widget.accessoryIsRecording,
      'isDark': isDark,
      'minHeight': widget.minHeight,
      'maxHeight': widget.maxHeight,
      'fontSize': widget.fontSize,
      'textColor': widget.textColor?.toARGB32(),
      'placeholderColor': widget.placeholderColor?.toARGB32(),
      'selectionBaseOffset': widget.selection.baseOffset,
      'selectionExtentOffset': widget.selection.extentOffset,
    };
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('conduit/native_chat_input_$id');
    _channel = channel;
    channel.setMethodCallHandler(_handlePlatformCall);
    _invokeMethod('setText', {'text': widget.text});
    _invokeMethod('setSelection', {
      'baseOffset': widget.selection.baseOffset,
      'extentOffset': widget.selection.extentOffset,
    });
    _invokeMethod('setEnabled', {'enabled': widget.enabled});
    _invokeMethod('setPlaceholder', {'placeholder': widget.placeholder});
    _invokeMethod('setSendOnEnter', {'sendOnEnter': widget.sendOnEnter});
    _invokeMethod('setAccessoryConfig', {
      'showInputAccessoryBar': widget.showInputAccessoryBar,
      'accessoryCanSend': widget.accessoryCanSend,
      'accessoryCanUseMic': widget.accessoryCanUseMic,
      'accessoryIsRecording': widget.accessoryIsRecording,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: _viewType,
        creationParams: _creationParams(context),
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: _viewType,
        creationParams: _creationParams(context),
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }

    return const SizedBox.shrink();
  }
}
