import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_handoff_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/media_upload_controller.dart';
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

/// The app's handoff opener. Attachments picked in the old composer don't
/// follow into the new chat, as with a folder's New Chat.
void openChatHandoffInApp(Ref ref, Model model, String prompt) {
  unawaited(
    ref.read(mediaUploadControllerProvider).clearAttachments().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      DebugLogger.error(
        'attachment-boundary-cleanup-failed',
        scope: 'chat/handoff',
        error: error,
        stackTrace: stackTrace,
      );
    }),
  );
  openChatHandoff(ref, model, prompt);
}
