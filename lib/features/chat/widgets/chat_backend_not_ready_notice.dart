import 'dart:async';

import 'package:conduit_core/features/chat/services/chat_backend_readiness.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

/// Why a turn was not sent, for [reason].
String chatBackendNotReadyMessage(
  AppLocalizations l10n,
  ChatBackendNotReady reason,
) => switch (reason) {
  ChatBackendNotReady.openWebUiSignedOut => l10n.chatBackendSignInRequired(
    'Open WebUI',
  ),
  ChatBackendNotReady.libreChatSignedOut => l10n.chatBackendSignInRequired(
    l10n.libreChatTitle,
  ),
  ChatBackendNotReady.hermesAwaitsSignIn => l10n.chatBackendSignInRequired(
    'Hermes',
  ),
  ChatBackendNotReady.hermesNotConfigured => l10n.chatBackendHermesNotSetUp,
  ChatBackendNotReady.hermesTurnedOff => l10n.chatBackendHermesTurnedOff,
  ChatBackendNotReady.modelUnavailable => l10n.chatBackendModelUnavailable,
};

/// Says why a send, regenerate or edit was refused before anything was
/// written. A Hermes gateway waiting for its sign-in is offered it here, as
/// the error card on a failed answer offered it; the draft is still there to
/// send once it is done.
void showChatBackendNotReady(BuildContext context, ChatBackendNotReady reason) {
  final l10n = AppLocalizations.of(context)!;
  final container = ProviderScope.containerOf(context, listen: false);
  final gateway = reason == ChatBackendNotReady.hermesAwaitsSignIn
      ? container.read(hermesApiServiceProvider)
      : null;
  final signIn = gateway is HermesDesktopApiService ? gateway : null;
  AdaptiveSnackBar.show(
    context,
    message: chatBackendNotReadyMessage(l10n, reason),
    type: AdaptiveSnackBarType.error,
    action: signIn == null ? null : l10n.signIn,
    onActionPressed: signIn == null
        ? null
        : () => unawaited(
            signIn.signInNative().then<void>(
              (_) {},
              onError: (Object error, StackTrace stackTrace) {
                DebugLogger.error(
                  'gateway-sign-in-failed',
                  scope: 'chat/backend-not-ready',
                  error: error,
                  stackTrace: stackTrace,
                );
                // As the error card's own Sign In Again says it.
                if (!context.mounted) return;
                AdaptiveSnackBar.show(
                  context,
                  message: l10n.hermesErrorActionFailed,
                  type: AdaptiveSnackBarType.error,
                );
              },
            ),
          ),
  );
}
