import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_todo_providers.dart'
    show hermesOpenChatSessionProvider;
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider;

/// The working directory the open Hermes chat runs its tools in, live: only
/// a Desktop Gateway reports one. Null while it is unknown.
final hermesActiveWorkingDirectoryProvider =
    StreamProvider.autoDispose<String?>((ref) {
      final service = ref.watch(hermesApiServiceProvider);
      final storedId = ref.watch(hermesOpenChatSessionProvider);
      if (service is! HermesDesktopApiService || storedId == null) {
        return Stream.value(null);
      }
      return service.workingDirectoriesFor(storedId);
    });

/// The working directory for the diff cards of a reply that ran in Hermes
/// session [replySession] (its `hermesSessionId`): the open chat's, when the
/// reply ran there. A native Hermes chat runs every reply in its one
/// session. In an OpenWebUI chat, Hermes turns can run in different
/// sessions, and a reply from another one keeps its full paths.
final hermesReplyWorkingDirectoryProvider = Provider.autoDispose
    .family<String?, String?>((ref, replySession) {
      final native = ref.watch(
        activeConversationProvider.select(isNativeHermesConversation),
      );
      if (!native &&
          (replySession == null ||
              replySession != ref.watch(hermesOpenChatSessionProvider))) {
        return null;
      }
      return ref.watch(hermesActiveWorkingDirectoryProvider).value;
    });
