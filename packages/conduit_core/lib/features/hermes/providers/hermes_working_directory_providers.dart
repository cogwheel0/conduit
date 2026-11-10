import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_todo_providers.dart'
    show hermesOpenChatSessionProvider;
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

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
