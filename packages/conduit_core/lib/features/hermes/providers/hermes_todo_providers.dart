import 'package:collection/collection.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider, hermesTrustedMixedSessionProvider;

import 'package:conduit_core/features/hermes/models/hermes_todo.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider;

/// The Hermes session the open chat continues, when it is a Hermes chat, or
/// the one a Hermes turn inside an OpenWebUI chat runs in. Its plan and its
/// background work follow it.
final hermesOpenChatSessionProvider = Provider.autoDispose<String?>((ref) {
  final id = ref.watch(
    activeConversationProvider.select(
      (conversation) => conversation?.metadata['hermesSessionId'],
    ),
  );
  if (id is String && id.isNotEmpty) return id;
  // A Hermes turn inside an OpenWebUI chat keeps its session on its reply,
  // and the chat itself names none. Only a session this app bound for the
  // chat's latest turn counts: a reply's metadata alone may come from the
  // server. Reopened, the chat has its stored binding instead.
  final bound = ref.watch(hermesActiveSessionProvider);
  final latest = ref.watch(
    chatMessagesProvider.select(
      (messages) => messages
          .lastWhereOrNull((message) => message.role == 'assistant')
          ?.metadata?['hermesSessionId'],
    ),
  );
  if (bound != null && latest == bound) return bound;
  return ref.watch(hermesTrustedMixedSessionProvider);
});

/// The agent's task list for the open chat, live: only a Desktop Gateway
/// reports one. Null when the chat has none.
final hermesActiveTodoProvider = StreamProvider.autoDispose<HermesTodoState?>(
  (ref) {
    final service = ref.watch(hermesApiServiceProvider);
    final storedId = ref.watch(hermesOpenChatSessionProvider);
    if (service is! HermesDesktopApiService || storedId == null) {
      return Stream.value(null);
    }
    return service.todoStatesFor(storedId);
  },
);
