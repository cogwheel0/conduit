import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/hermes/models/hermes_todo.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider;

/// The Hermes session the open chat continues, when it is a Hermes chat.
final _activeHermesSessionProvider = Provider.autoDispose<String?>((ref) {
  final id = ref.watch(
    activeConversationProvider.select(
      (conversation) => conversation?.metadata['hermesSessionId'],
    ),
  );
  return id is String && id.isNotEmpty ? id : null;
});

/// The agent's task list for the open chat, live: only a Desktop Gateway
/// reports one. Null when the chat has none.
final hermesActiveTodoProvider = StreamProvider.autoDispose<HermesTodoState?>(
  (ref) {
    final service = ref.watch(hermesApiServiceProvider);
    final storedId = ref.watch(_activeHermesSessionProvider);
    if (service is! HermesDesktopApiService || storedId == null) {
      return Stream.value(null);
    }
    return service.todoStatesFor(storedId);
  },
);
