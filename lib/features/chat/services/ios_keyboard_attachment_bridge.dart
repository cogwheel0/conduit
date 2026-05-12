import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

const _iosKeyboardAttachmentChannel = MethodChannel(
  'conduit/keyboard_attachment',
);

class IosKeyboardAttachmentBridge {
  IosKeyboardAttachmentBridge._() {
    _iosKeyboardAttachmentChannel.setMethodCallHandler(_handleMethodCall);
  }

  static final IosKeyboardAttachmentBridge instance =
      IosKeyboardAttachmentBridge._();

  final StreamController<IosKeyboardAttachmentEvent> _events =
      StreamController<IosKeyboardAttachmentEvent>.broadcast();

  Stream<IosKeyboardAttachmentEvent> get events => _events.stream;

  Future<void> configure({
    required List<IosKeyboardAttachmentActionConfig> actions,
  }) {
    if (!Platform.isIOS || actions.isEmpty) {
      return Future<void>.value();
    }
    return _invokeVoid('configure', actions: actions);
  }

  Future<bool> toggle({
    required List<IosKeyboardAttachmentActionConfig> actions,
  }) async {
    if (!Platform.isIOS || actions.isEmpty) {
      return false;
    }

    return _invokeBool('toggle', actions: actions);
  }

  Future<void> hide() {
    if (!Platform.isIOS) {
      return Future<void>.value();
    }
    return _invokeVoid('hide');
  }

  Future<void> _invokeVoid(
    String method, {
    List<IosKeyboardAttachmentActionConfig> actions = const [],
  }) async {
    final payload = actions.isEmpty
        ? null
        : {'actions': actions.map((action) => action.toMap()).toList()};

    try {
      await _iosKeyboardAttachmentChannel.invokeMethod<void>(method, payload);
    } catch (_) {}
  }

  Future<bool> _invokeBool(
    String method, {
    List<IosKeyboardAttachmentActionConfig> actions = const [],
  }) async {
    final payload = actions.isEmpty
        ? null
        : {'actions': actions.map((action) => action.toMap()).toList()};

    try {
      return await _iosKeyboardAttachmentChannel.invokeMethod<bool>(
            method,
            payload,
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) {
      return;
    }

    switch (call.method) {
      case 'onAction':
        final id = arguments['id'] as String?;
        if (id == null || id.isEmpty) return;
        _events.add(IosKeyboardAttachmentAction(id));
      case 'onVisibilityChanged':
        _events.add(
          IosKeyboardAttachmentVisibilityChanged(
            visible: arguments['visible'] == true,
          ),
        );
    }
  }
}

class IosKeyboardAttachmentActionConfig {
  const IosKeyboardAttachmentActionConfig({
    required this.id,
    required this.label,
    required this.sfSymbol,
    required this.section,
    this.subtitle,
    this.enabled = true,
    this.selected = false,
    this.dismissesKeyboard = true,
  });

  final String id;
  final String label;
  final String? subtitle;
  final String sfSymbol;
  final String section;
  final bool enabled;
  final bool selected;
  final bool dismissesKeyboard;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'label': label,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      'section': section,
      'enabled': enabled,
      'selected': selected,
      'dismissesKeyboard': dismissesKeyboard,
    };
  }
}

sealed class IosKeyboardAttachmentEvent {
  const IosKeyboardAttachmentEvent();
}

final class IosKeyboardAttachmentAction extends IosKeyboardAttachmentEvent {
  const IosKeyboardAttachmentAction(this.id);

  final String id;
}

final class IosKeyboardAttachmentVisibilityChanged
    extends IosKeyboardAttachmentEvent {
  const IosKeyboardAttachmentVisibilityChanged({required this.visible});

  final bool visible;
}
