import 'package:conduit_core/ports/ui_request_port.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';

/// The app's `ChatHandoffPrompt`: asks, through the UI request port, whether
/// to follow the server's suggestion and continue in a new chat with
/// [modelName].
Future<bool> confirmChatHandoff(
  UiRequestPort requests,
  String modelName,
) async {
  final context = NavigationService.context;
  final l10n = context == null ? null : AppLocalizations.of(context);
  if (l10n == null) return false;
  return requests.confirm(
    title: l10n.chatHandoffPromptTitle(modelName),
    message: l10n.chatHandoffPromptMessage(modelName),
    confirmLabel: l10n.chatHandoffStartNewChat,
    cancelLabel: l10n.chatHandoffStayHere,
  );
}
