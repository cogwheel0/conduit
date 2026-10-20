import 'dart:async';
import 'dart:io' show Platform;

import '../../../platform/conduit_platform_apis.g.dart';

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

/// Whether a native panel row turns an option on and off, or runs a command.
enum IosKeyboardAttachmentActionKind {
  /// Shows a checkmark while on, and reads its state label to VoiceOver.
  toggle,

  /// Attaches something or opens a sheet. A list row shows a chevron.
  command,
}

class IosKeyboardAttachmentActionConfig {
  const IosKeyboardAttachmentActionConfig({
    required this.id,
    required this.label,
    required this.sfSymbol,
    required this.section,
    this.sectionTitle,
    this.kind = IosKeyboardAttachmentActionKind.command,
    this.stateLabel,
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

  /// The localized heading of [section], or null when the section shows none.
  final String? sectionTitle;
  final IosKeyboardAttachmentActionKind kind;

  /// The localized on or off state of a toggle, for VoiceOver.
  final String? stateLabel;
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
      'sectionTitle': sectionTitle,
      'kind': kind.name,
      'stateLabel': stateLabel,
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
      sectionTitle: sectionTitle,
      kind: switch (kind) {
        IosKeyboardAttachmentActionKind.toggle =>
          PlatformKeyboardAttachmentActionKind.toggle,
        IosKeyboardAttachmentActionKind.command =>
          PlatformKeyboardAttachmentActionKind.command,
      },
      stateLabel: stateLabel,
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
