import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/chat_comparison.dart';

import '../models/computer_models.dart';
import '../models/terminal_models.dart';
import '../services/computer_service.dart';
import 'terminal_providers.dart';

final computerServiceProvider = FutureProvider.autoDispose<ComputerService?>((
  ref,
) async {
  final terminal = ref.watch(terminalServiceProvider);
  final scope = ref.watch(terminalSessionScopeIdProvider);
  final server = await ref.watch(terminalSelectedServerProvider.future);
  // Browser tabs belong to a saved chat. Never attach a draft to the unscoped
  // terminal's last tab, which may belong to a different conversation.
  if (terminal == null ||
      server == null ||
      !isSavedTerminalChatScopeId(scope)) {
    return null;
  }
  return ComputerService(terminal, server, scope);
});

final computerCapabilitiesProvider =
    FutureProvider.autoDispose<ComputerCapabilities>((ref) async {
      final service = await ref.watch(computerServiceProvider.future);
      return service == null
          ? const ComputerCapabilities()
          : service.capabilities();
    });

/// Input is only enabled once the current response has stopped on the server.
/// A shared chat's other participant cannot be stopped by this account.
final computerTakeControlProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    final userId = ref.read(currentUserProvider2)?.id;
    if (ref
        .read(chatMessagesProvider)
        .any(
          (message) => message.isStreaming && !message.isWrittenBy(userId),
        )) {
      return false;
    }
    final accepted = await stopOpenWebUiMainResponse(ref);
    return accepted &&
        ref.mounted &&
        !ref.read(chatMessagesProvider).any((message) => message.isStreaming);
  };
});
