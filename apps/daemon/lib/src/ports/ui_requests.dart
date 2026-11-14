import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart'
    show HermesHeldModelSwitch;
import 'package:conduit_core/ports/ui_request_port.dart';

import '../ui_requests_service.dart';

/// The core's [UiRequestPort], bound before there is anyone to ask.
///
/// The core container is made before the daemon server attaches its
/// `UiRequestsService`, and a container's overrides are fixed when it is
/// made. So the core gets this, which declines everything, as the port's
/// contract says to with no UI, until the server attaches the real broker.
/// Every Open WebUI prompt the streaming pipeline raises mid-turn -- a tool
/// asking for approval, a function asking a question -- then reaches the
/// windows as `ui.request`, whichever chat's scope raised it.
final class DaemonUiRequestPort implements UiRequestPort {
  UiRequestPort _target = const NullUiRequestPort();

  void attach(UiRequestPort target) => _target = target;

  void detach() => _target = const NullUiRequestPort();

  @override
  Future<bool> confirm({
    required String title,
    String message = '',
    String? confirmLabel,
    String? cancelLabel,
  }) => _target.confirm(
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
  );

  @override
  Future<String?> promptForText({
    required String title,
    String message = '',
    String? placeholder,
    String? initialValue,
    UiTextInputType inputType = UiTextInputType.text,
    List<UiSelectOption> options = const <UiSelectOption>[],
    String? confirmLabel,
    String? cancelLabel,
  }) => _target.promptForText(
    title: title,
    message: message,
    placeholder: placeholder,
    initialValue: initialValue,
    inputType: inputType,
    options: options,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
  );

  @override
  void notify(UiNoticeLevel level, String message) =>
      _target.notify(level, message);

  /// Core's Hermes model-switch prompt (`hermesModelSwitchPromptProvider`):
  /// asked of the windows once the broker is attached; null (the switch
  /// refused, as before) until then.
  Future<bool?> confirmHermesModelSwitch(HermesHeldModelSwitch held) {
    final target = _target;
    if (target is! UiRequestsService) return Future<bool?>.value();
    return target.askHermesModelSwitch(model: held.model, reason: held.reason);
  }
}
