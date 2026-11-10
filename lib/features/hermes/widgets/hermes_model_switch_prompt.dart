import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/ports/ui_request_port.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';

/// The app's [HermesModelSwitchPrompt]: asks, through the UI request port,
/// whether to switch the chat to [held]'s model and send the waiting
/// message, giving Hermes' own reason when it has one. Resolves false to
/// keep the current model, and null when there is no screen to ask on.
Future<bool?> confirmHermesModelSwitch(
  UiRequestPort requests,
  HermesHeldModelSwitch held,
) async {
  final context = NavigationService.context;
  final l10n = context == null ? null : AppLocalizations.of(context);
  if (l10n == null) return null;
  return requests.confirm(
    title: l10n.hermesModelSwitchConfirmTitle(held.model),
    message: held.reason ?? l10n.hermesModelSwitchConfirmMessage,
    confirmLabel: l10n.hermesModelSwitchConfirmAction,
    cancelLabel: l10n.hermesModelSwitchKeepCurrent,
  );
}
