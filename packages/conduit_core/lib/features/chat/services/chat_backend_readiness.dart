/// Whether a chat's backend can take a turn now, asked before a send,
/// regenerate or edit writes anything.
library;

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// Why a chat's backend cannot take a turn now.
enum ChatBackendNotReady {
  /// No Open WebUI server, or one that is signed out.
  openWebUiSignedOut,

  /// No LibreChat account signed in.
  libreChatSignedOut,

  /// Hermes is not set up.
  hermesNotConfigured,

  /// Hermes is turned off, with a connection saved.
  hermesTurnedOff,

  /// A Hermes gateway that signs in natively and has not signed in yet.
  hermesAwaitsSignIn,

  /// A Direct or Apple model whose connection was removed, turned off or is
  /// no longer offered: the core would refuse it only after an edit has cut
  /// the transcript.
  modelUnavailable,
}

/// A turn refused by [requireChatBackendReady] before anything was written.
final class ChatBackendNotReadyException implements Exception {
  const ChatBackendNotReadyException(this.reason);

  final ChatBackendNotReady reason;

  @override
  String toString() => 'ChatBackendNotReadyException: ${reason.name}';
}

/// Why [model]'s backend cannot take a turn now, or null when it can.
///
/// The open [conversation] also names the backend: a Hermes or LibreChat
/// chat answers through its own backend whichever model is selected.
///
/// Offline is not "not ready": a signed-in Open WebUI account stays
/// signed in without a connection, and its sends queue.
ChatBackendNotReady? chatBackendNotReady(
  dynamic ref,
  Model model, {
  Conversation? conversation,
}) {
  if (isHermesModel(model) || isNativeHermesConversation(conversation)) {
    final config = ref.read(hermesConfigProvider) as HermesConfig;
    if (ref.read(hermesApiServiceProvider) == null) {
      return !config.enabled &&
              HermesConfig.connectionOrigin(config.baseUrl) != null
          ? ChatBackendNotReady.hermesTurnedOff
          : ChatBackendNotReady.hermesNotConfigured;
    }
    if (config.awaitsSignIn) {
      return ChatBackendNotReady.hermesAwaitsSignIn;
    }
    return null;
  }
  if (isLibreChatModel(model) || isLibreChatConversation(conversation)) {
    return ref.read(libreChatSessionHandleProvider) == null
        ? ChatBackendNotReady.libreChatSignedOut
        : null;
  }
  final binding = (ref.read(directModelRegistryProvider) as DirectModelRegistry)
      .resolve(model);
  if (binding?.source == DirectModelSource.device) return null;
  // Minted for a connection this device holds, but no longer bound to one:
  // not an Open WebUI model, and nothing can answer it.
  if (binding == null && hasReservedDirectIdentity(model)) {
    return ChatBackendNotReady.modelUnavailable;
  }
  if (ref.read(reviewerModeProvider) == true) return null;
  return openWebUiSignedIn(ref) ? null : ChatBackendNotReady.openWebUiSignedOut;
}

/// Whether an Open WebUI account is signed in, with its client built.
///
/// Both: a configured server whose session ended still has a client, and a
/// signed-in account has none while its server list is read again (an
/// account added, switched to, or its servers saved).
bool openWebUiSignedIn(dynamic ref) =>
    ref.read(apiServiceProvider) != null &&
    ref.read(isAuthenticatedProvider2) == true;

/// Throws [ChatBackendNotReadyException] when [model]'s backend cannot take
/// a turn now ([chatBackendNotReady]). No model is left to the caller.
///
/// A Hermes turn first waits for the saved Hermes secrets: on a cold start
/// the config is built before they are read, and looks unconfigured until
/// then. Only then is a future returned; every other backend is answered
/// synchronously (the throw included), so a caller that awaits only a
/// non-null result writes its optimistic rows in the same turn of the loop.
Future<void>? requireChatBackendReady(
  dynamic ref,
  Model? model, {
  Conversation? conversation,
}) {
  if (model == null) return null;
  void check() {
    final reason = chatBackendNotReady(ref, model, conversation: conversation);
    if (reason != null) throw ChatBackendNotReadyException(reason);
  }

  if (isHermesModel(model) || isNativeHermesConversation(conversation)) {
    final config =
        ref.read(hermesConfigProvider.notifier) as HermesConfigController;
    return Future<void>.sync(() async {
      await config.waitForSecretsHydration();
      check();
    });
  }
  check();
  return null;
}
