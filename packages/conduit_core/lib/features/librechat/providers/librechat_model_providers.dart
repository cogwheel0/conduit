import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The models the signed-in LibreChat account offers, for the picker: its
/// model specs, agents and endpoint models, minted for this process (see
/// [libreChatCatalog]). Empty while no LibreChat account is signed in.
final libreChatModelCatalogProvider = FutureProvider<List<Model>>((ref) async {
  final api = ref.watch(libreChatApiServiceProvider);
  if (api == null) return const <Model>[];
  final results = await Future.wait<Object?>([
    api.startupConfig(),
    api.endpoints(),
    api.models(),
    api.agents().catchError(
      (Object error) {
        // A server without agents, or a role that may not list them, still
        // offers its endpoints. Any other failure fails the refresh, which
        // keeps the list last loaded and the agent chosen from it.
        DebugLogger.warning(
          'agents-unavailable',
          scope: 'librechat/models',
          data: {'status': (error as LibreChatApiException).statusCode},
        );
        return const <Map<String, dynamic>>[];
      },
      test: (error) =>
          error is LibreChatApiException &&
          const {401, 403, 404, 405}.contains(error.statusCode),
    ),
  ]);
  return List<Model>.unmodifiable(
    libreChatCatalog(
      startupConfig: results[0]! as Map<String, dynamic>,
      endpoints: results[1]! as Map<String, dynamic>,
      models: results[2]! as Map<String, List<String>>,
      agents: results[3]! as List<Map<String, dynamic>>,
    ),
  );
});
