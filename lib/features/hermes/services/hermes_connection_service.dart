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
  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  }) async {
    final notifier = _ref.read(hermesConfigProvider.notifier);
    final previousConfig = _ref.read(hermesConfigProvider);
    final previousBackend = _ref.read(preferredBackendProvider);
    final preferredBackend = _ref.read(preferredBackendProvider.notifier);

    await runHermesOnboardingCommit(
      isCurrent: isCurrent,
      persist: () => persist(draft),
      enable: () => notifier.setEnabled(true),
      ensureSessionKey: notifier.ensureSessionKey,
      selectBackend: () => preferredBackend.set(PreferredBackend.hermes),
      rollback: () async {
        await preferredBackend.set(previousBackend);
        await notifier.saveConnection(
          baseUrl: previousConfig.baseUrl,
          apiKeyChanged: true,
          apiKey: previousConfig.apiKey,
          sessionKeyChanged: true,
          sessionKey: previousConfig.sessionKey,
        );
        await notifier.setEnabled(previousConfig.enabled);
      },
    );
  }
}

/// Commits onboarding as one owned operation and compensates every durable
/// step if activation fails or the initiating UI abandons the workflow.
Future<void> runHermesOnboardingCommit({
  required bool Function() isCurrent,
  required Future<void> Function() persist,
  required Future<void> Function() enable,
  required Future<String> Function() ensureSessionKey,
  required Future<void> Function() selectBackend,
  required Future<void> Function() rollback,
}) async {
  if (!isCurrent()) throw const HermesConnectionCommitCancelled();

  try {
    await persist();
  } catch (error) {
    throw HermesConnectionCommitException(
      stage: HermesConnectionCommitStage.persistence,
      error: error,
    );
  }

  var stage = HermesConnectionCommitStage.activation;
  late final Object activationError;
  try {
    if (!isCurrent()) throw const HermesConnectionCommitCancelled();
    await enable();
    if (!isCurrent()) throw const HermesConnectionCommitCancelled();
    await ensureSessionKey();
    if (!isCurrent()) throw const HermesConnectionCommitCancelled();
    await selectBackend();
    if (!isCurrent()) throw const HermesConnectionCommitCancelled();
    return;
  } catch (error) {
    activationError = error;
  }

  try {
    await rollback();
  } catch (rollbackError) {
    stage = HermesConnectionCommitStage.rollback;
    throw HermesConnectionCommitException(
      stage: stage,
      error: activationError,
      rollbackError: rollbackError,
    );
  }

  final error = activationError;
  if (error is HermesConnectionCommitCancelled) throw error;
  throw HermesConnectionCommitException(stage: stage, error: error);
}
