import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../models/hermes_connection_contract.dart';
import '../models/hermes_config.dart';
import '../providers/hermes_providers.dart';
import 'hermes_api_service.dart';
import 'hermes_desktop_api_service.dart';
import 'hermes_desktop_connection_coordinator.dart';

final hermesConnectionGatewayProvider = Provider<HermesConnectionGateway>(
  _RiverpodHermesConnectionGateway.new,
);

final class _RiverpodHermesConnectionGateway
    implements HermesConnectionGateway {
  const _RiverpodHermesConnectionGateway(this._ref);

  final Ref _ref;

  @override
  Future<bool> probe(HermesConfig draft) async {
    if (draft.mode != HermesBackendMode.desktopGateway) {
      return testHermesDraftConnection(draft);
    }
    final current = _ref.read(hermesConfigProvider);
    final live = _ref.read(hermesApiServiceProvider);
    final sameConnection = hermesDesktopConnectionMatches(current, draft);
    if (sameConnection && live is HermesDesktopApiService) {
      return live.health();
    }
    if (draft.desktopCredentials?.nativeTokens != null) {
      throw StateError('Save the Hermes server before testing its sign-in.');
    }
    final service = HermesDesktopApiService(
      config: draft.copyWith(enabled: true),
    );
    try {
      return await service.health();
    } finally {
      service.close();
    }
  }

  @override
  Future<void> persist(HermesConnectionDraft draft) {
    return _ref
        .read(hermesConfigProvider.notifier)
        .saveConnection(
          baseUrl: draft.config.baseUrl,
          mode: draft.config.mode,
          desktopAuthKind: draft.config.desktopAuthKind,
          desktopProfile: draft.config.desktopProfile,
          allowSelfSignedCertificates:
              draft.config.allowSelfSignedCertificates,
          apiKeyChanged: draft.apiKeyChanged,
          apiKey: draft.config.apiKey,
          sessionKeyChanged: draft.sessionKeyChanged,
          sessionKey: draft.config.sessionKey,
          desktopCredentialsChanged: draft.desktopCredentialsChanged,
          desktopCredentials: draft.config.desktopCredentials,
        );
  }

  @override
  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  }) async {
    final notifier = _ref.read(hermesConfigProvider.notifier);
    try {
      await notifier.waitForSecretsHydration();
    } catch (error) {
      throw HermesConnectionCommitException(
        stage: HermesConnectionCommitStage.persistence,
        error: error,
      );
    }
    if (!isCurrent()) throw const HermesConnectionCommitCancelled();
    final previousConfig = _ref.read(hermesConfigProvider);
    final previousBackend = _ref.read(preferredBackendProvider);
    final preferredBackend = _ref.read(preferredBackendProvider.notifier);

    await runHermesOnboardingCommit(
      isCurrent: isCurrent,
      persist: () => persist(draft),
      enable: () => notifier.setEnabled(true),
      ensureSessionKey: draft.config.mode == HermesBackendMode.responsesApi
          ? notifier.ensureSessionKey
          : () async => '',
      selectBackend: () => preferredBackend.set(PreferredBackend.hermes),
      rollback: () => runHermesOnboardingRollback(
        previousEnabled: previousConfig.enabled,
        setEnabled: notifier.setEnabled,
        restoreConnection: () => notifier.saveConnection(
          baseUrl: previousConfig.baseUrl,
          mode: previousConfig.mode,
          desktopAuthKind: previousConfig.desktopAuthKind,
          desktopProfile: previousConfig.desktopProfile,
          allowSelfSignedCertificates:
              previousConfig.allowSelfSignedCertificates,
          apiKeyChanged: true,
          apiKey: previousConfig.apiKey,
          sessionKeyChanged: true,
          sessionKey: previousConfig.sessionKey,
          desktopCredentialsChanged: true,
          desktopCredentials: previousConfig.desktopCredentials,
        ),
        restoreBackend: () => preferredBackend.set(previousBackend),
      ),
    );
  }
}

enum HermesConnectionRollbackStep {
  deactivate,
  restoreConnection,
  restoreEnabled,
  restoreBackend,
  retryDeactivation,
}

final class HermesConnectionRollbackFailure {
  const HermesConnectionRollbackFailure({
    required this.step,
    required this.errorType,
  });

  final HermesConnectionRollbackStep step;
  final String errorType;
}

/// Aggregates sanitized rollback failure descriptors without retaining raw
/// error objects that could carry credential-bearing messages.
final class HermesConnectionRollbackException implements Exception {
  HermesConnectionRollbackException(
    Iterable<HermesConnectionRollbackFailure> failures,
  ) : failures = List<HermesConnectionRollbackFailure>.unmodifiable(failures);

  final List<HermesConnectionRollbackFailure> failures;

  @override
  String toString() =>
      'HermesConnectionRollbackException('
      '${failures.map((failure) => '${failure.step.name}:${failure.errorType}').join(', ')})';
}

/// Restores a failed onboarding transaction without allowing one failed
/// compensation to suppress the remaining independent cleanup steps.
Future<void> runHermesOnboardingRollback({
  required bool previousEnabled,
  required Future<void> Function(bool enabled) setEnabled,
  required Future<void> Function() restoreConnection,
  required Future<void> Function() restoreBackend,
}) async {
  final failures = <HermesConnectionRollbackFailure>[];

  Future<bool> attempt(
    HermesConnectionRollbackStep step,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      return true;
    } catch (error) {
      failures.add(
        HermesConnectionRollbackFailure(
          step: step,
          errorType: error.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  final deactivated = await attempt(
    HermesConnectionRollbackStep.deactivate,
    () => setEnabled(false),
  );
  final connectionRestored = await attempt(
    HermesConnectionRollbackStep.restoreConnection,
    restoreConnection,
  );
  if (connectionRestored) {
    await attempt(
      HermesConnectionRollbackStep.restoreEnabled,
      () => setEnabled(previousEnabled),
    );
  } else if (!deactivated) {
    // The previous connection could not be restored, so retry the fail-closed
    // state instead of risking re-enabling the replacement configuration.
    await attempt(
      HermesConnectionRollbackStep.retryDeactivation,
      () => setEnabled(false),
    );
  }
  await attempt(HermesConnectionRollbackStep.restoreBackend, restoreBackend);

  if (failures.isNotEmpty) {
    throw HermesConnectionRollbackException(failures);
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
