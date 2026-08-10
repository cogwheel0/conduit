import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../controllers/hermes_connection_controller.dart';
import '../models/hermes_config.dart';
import '../providers/hermes_providers.dart';
import 'hermes_api_service.dart';

final hermesConnectionGatewayProvider = Provider<HermesConnectionGateway>(
  _RiverpodHermesConnectionGateway.new,
);

final class _RiverpodHermesConnectionGateway
    implements HermesConnectionGateway {
  const _RiverpodHermesConnectionGateway(this._ref);

  final Ref _ref;

  @override
  Future<bool> probe(HermesConfig draft) => testHermesDraftConnection(draft);

  @override
  Future<void> persist(HermesConnectionDraft draft) {
    return _ref
        .read(hermesConfigProvider.notifier)
        .saveConnection(
          baseUrl: draft.config.baseUrl,
          apiKeyChanged: draft.apiKeyChanged,
          apiKey: draft.config.apiKey,
          sessionKeyChanged: draft.sessionKeyChanged,
          sessionKey: draft.config.sessionKey,
        );
  }

  @override
  Future<void> activate() async {
    final notifier = _ref.read(hermesConfigProvider.notifier);
    await notifier.setEnabled(true);
    await notifier.ensureSessionKey();
    await _ref
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.hermes);
  }
}
