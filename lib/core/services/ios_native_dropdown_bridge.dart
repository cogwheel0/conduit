import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../utils/debug_logger.dart';

const _iosNativeDropdownChannel = MethodChannel('conduit/native_dropdown');

void _logNativeDropdownBridgeError(
  String method,
  Object error,
  StackTrace stackTrace, {
  Map<String, Object?> data = const {},
}) {
  DebugLogger.error(
    'native-dropdown-bridge-call-failed',
    scope: 'native-dropdown',
    error: error,
    stackTrace: stackTrace,
    data: {'method': method, ...data},
  );
}

class IosNativeDropdownBridge {
  IosNativeDropdownBridge._();

  static final IosNativeDropdownBridge instance = IosNativeDropdownBridge._();

  Future<String?> show({
    required List<IosNativeDropdownOption> options,
    String? title,
    String? message,
    Rect? sourceRect,
    bool rethrowErrors = false,
  }) async {
    if (!Platform.isIOS || options.isEmpty) return null;
    try {
      return await _iosNativeDropdownChannel.invokeMethod<String>('show', {
        'title': title,
        'message': message,
        'options': options.map((option) => option.toMap()).toList(),
        if (sourceRect != null) 'sourceRect': _rectToMap(sourceRect),
      });
    } on PlatformException catch (error, stackTrace) {
      _logNativeDropdownBridgeError(
        'show',
        error,
        stackTrace,
        data: {'optionCount': options.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    } catch (error, stackTrace) {
      _logNativeDropdownBridgeError(
        'show',
        error,
        stackTrace,
        data: {'optionCount': options.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    }
  }

  Future<String?> showFromContext({
    required BuildContext context,
    required List<IosNativeDropdownOption> options,
    String? title,
    String? message,
    bool rethrowErrors = false,
  }) {
    return show(
      title: title,
      message: message,
      options: options,
      sourceRect: _globalRectForContext(context),
      rethrowErrors: rethrowErrors,
    );
  }

  Map<String, double> _rectToMap(Rect rect) {
    return {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    };
  }

  Rect? _globalRectForContext(BuildContext context) {
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.hasSize) {
      return null;
    }
    final topLeft = object.localToGlobal(Offset.zero);
    return topLeft & object.size;
  }
}

class IosNativeDropdownOption {
  const IosNativeDropdownOption({
    required this.id,
    required this.label,
    this.subtitle,
    this.sfSymbol,
    this.enabled = true,
    this.destructive = false,
  });

  final String id;
  final String label;
  final String? subtitle;
  final String? sfSymbol;
  final bool enabled;
  final bool destructive;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'label': label,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      'enabled': enabled,
      'destructive': destructive,
    };
  }
}
