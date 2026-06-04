import 'dart:async';
import 'dart:io' show Platform;

import '../../../core/platform/conduit_platform_apis.g.dart';

class IosKeyboardAttachmentBridge
    implements NativeKeyboardAttachmentFlutterApi {
  IosKeyboardAttachmentBridge._() {
    NativeKeyboardAttachmentFlutterApi.setUp(this);
  }

  static final IosKeyboardAttachmentBridge instance =
      IosKeyboardAttachmentBridge._();

  final NativeKeyboardAttachmentHostApi _api =
      NativeKeyboardAttachmentHostApi();
  final StreamController<IosKeyboardAttachmentEvent> _events =
      StreamController<IosKeyboardAttachmentEvent>.broadcast();

  Stream<IosKeyboardAttachmentEvent> get events => _events.stream;

  Future<void> configure({
    required List<IosKeyboardAttachmentActionConfig> actions,
  }) {
    if (!Platform.isIOS || actions.isEmpty) {
      return Future<void>.value();
    }
    return _invokeVoid(() => _api.configure(_platformConfig(actions)));
  }

  Future<bool> toggle({
    required List<IosKeyboardAttachmentActionConfig> actions,
  }) async {
    if (!Platform.isIOS || actions.isEmpty) {
      return false;
    }

    return _invokeBool(() => _api.toggle(_platformConfig(actions)));
  }

  Future<void> hide() {
    if (!Platform.isIOS) {
      return Future<void>.value();
    }
    return _invokeVoid(_api.hide);
  }

  Future<void> _invokeVoid(Future<void> Function() invoke) async {
    try {
      await invoke();
    } catch (_) {}
  }

  Future<bool> _invokeBool(Future<bool> Function() invoke) async {
    try {
      return await invoke();
    } catch (_) {
      return false;
    }
  }

  PlatformKeyboardAttachmentConfig _platformConfig(
    List<IosKeyboardAttachmentActionConfig> actions,
  ) {
    return PlatformKeyboardAttachmentConfig(
      actions: actions.map((action) => action.toPlatform()).toList(),
    );
  }

  @override
  void onAction(PlatformKeyboardAttachmentActionEvent event) {
    if (event.id.isEmpty) return;
    _events.add(IosKeyboardAttachmentAction(event.id));
  }

  @override
  void onVisibilityChanged(PlatformKeyboardAttachmentVisibilityEvent event) {
    _events.add(IosKeyboardAttachmentVisibilityChanged(visible: event.visible));
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

  PlatformKeyboardAttachmentActionConfig toPlatform() {
    return PlatformKeyboardAttachmentActionConfig(
      id: id,
      label: label,
      subtitle: subtitle,
      sfSymbol: sfSymbol,
      section: section,
      enabled: enabled,
      selected: selected,
      dismissesKeyboard: dismissesKeyboard,
    );
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
