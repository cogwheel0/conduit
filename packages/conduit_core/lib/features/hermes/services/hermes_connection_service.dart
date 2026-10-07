import 'package:collection/collection.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';

final hermesConnectionGatewayProvider = Provider<HermesConnectionGateway>(
  _RiverpodHermesConnectionGateway.new,
);

final class _RiverpodHermesConnectionGateway
    implements HermesConnectionGateway {
  const _RiverpodHermesConnectionGateway(this._ref);

  final Ref _ref;

  /// The live service when [draft] is exactly the active Desktop connection.
  HermesDesktopApiService? _liveDesktopServiceFor(HermesConfig draft) {
    final current = _ref.read(hermesConfigProvider);
    final live = _ref.read(hermesApiServiceProvider);
    return draft.connectionId == current.connectionId &&
            hermesDesktopConnectionMatches(current, draft) &&
            live is HermesDesktopApiService
        ? live
        : null;
  }

  /// A throwaway Desktop client for a draft that has no live service, as
  /// during onboarding, before Hermes is enabled, or for an inactive
  /// connection.
  HermesDesktopApiService _temporaryDesktopService(HermesConfig draft) {
    final current = _ref.read(hermesConfigProvider);
    final notifier = _ref.read(hermesConfigProvider.notifier);
    final targetsActive = draft.connectionId == current.connectionId;
    // Persist a refresh-token rotation only for a saved connection the draft
    // still matches: testing a different draft can never overwrite or clear
    // the saved credentials (issue #683). Each writer replaces only the
    // tokens its client holds, so a client built from tokens another one has
    // since rotated (a probe, then a name lookup) cannot clear them. An
    // inactive connection's writer re-checks the stored connection at write
    // time.
    final HermesDesktopCredentialsWriter? writeCredentials;
    if (draft.connectionId == null ||
        draft.desktopCredentials?.nativeTokens == null) {
      writeCredentials = null;
    } else if (targetsActive) {
      writeCredentials = hermesDesktopConnectionMatches(current, draft)
          ? notifier.credentialsWriterFor(draft)
          : null;
    } else {
      writeCredentials = notifier.credentialsWriterFor(draft);
    }
    return HermesDesktopApiService(
      config: draft.copyWith(enabled: true),
      // Dashboard-cookie gateways answer only through the host's WebView
      // bridge; it opens with the draft's own root and access headers.
      dashboardBridgeFactory: _ref.read(
        hostHermesDashboardBridgeFactoryProvider,
      ),
      onCredentialsChanged: writeCredentials,
    );
  }

  @override
  Future<bool> probe(HermesConfig draft) async {
    if (draft.mode != HermesBackendMode.desktopGateway) {
      return testHermesDraftConnection(draft);
    }
    final live = _liveDesktopServiceFor(draft);
    if (live != null) return live.health();
    final service = _temporaryDesktopService(draft);
    try {
      return await service.health();
    } finally {
      service.close();
    }
  }

  /// Names Hermes reports when nothing was configured: the API server's
  /// default model id and the Desktop default profile. They say nothing about
  /// the connection, so they never replace a name.
  static const Set<String> _placeholderNames = {'hermes-agent', 'default'};

  @override
  Future<String?> suggestDisplayName(HermesConfig draft) async {
    try {
      final suggestion = await _suggestDisplayName(
        draft,
      ).timeout(const Duration(seconds: 15));
      return suggestion == null ||
              _placeholderNames.contains(suggestion.toLowerCase())
          ? null
          : suggestion;
    } catch (error) {
      // A name is a convenience; the probe already reported reachability.
      DebugLogger.warning(
        'name-suggestion-failed',
        scope: 'hermes/connections',
        data: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<String?> _suggestDisplayName(HermesConfig draft) async {
    if (draft.mode == HermesBackendMode.desktopGateway) {
      final live = _liveDesktopServiceFor(draft);
      if (live != null) {
        return HermesConnectionProfile.sanitizeName(
          await live.suggestedDisplayName(),
        );
      }
      final service = _temporaryDesktopService(draft);
      try {
        return HermesConnectionProfile.sanitizeName(
          await service.suggestedDisplayName(),
        );
      } finally {
        service.close();
      }
    }
    final service = HermesApiService(config: draft.copyWith(enabled: true));
    try {
      return HermesConnectionProfile.sanitizeName(
        await service.suggestedDisplayName(),
      );
    } finally {
      service.close();
    }
  }

  @override
  Future<String?> persist(HermesConnectionDraft draft) async {
    final notifier = _ref.read(hermesConfigProvider.notifier);
    final config = draft.config;
    final targetId = config.connectionId;
    if (targetId == null &&
        _ref.read(hermesConfigProvider).connectionId != null) {
      // A new connection beside the active one is saved without switching.
      return notifier.createConnection(
        baseUrl: config.baseUrl,
        name: config.name,
        nameSource: draft.nameSource,
        mode: config.mode,
        desktopAuthKind: config.desktopAuthKind,
        desktopProfile: config.desktopProfile,
        allowSelfSignedCertificates: config.allowSelfSignedCertificates,
        apiKey: config.apiKey,
        sessionKey: config.sessionKey,
        desktopCredentials: config.desktopCredentials,
      );
    }
    await notifier.saveConnection(
      connectionId: targetId,
      baseUrl: config.baseUrl,
      name: config.name,
      nameSource: draft.nameSource,
      mode: config.mode,
      desktopAuthKind: config.desktopAuthKind,
      desktopProfile: config.desktopProfile,
      allowSelfSignedCertificates: config.allowSelfSignedCertificates,
      apiKeyChanged: draft.apiKeyChanged,
      apiKey: config.apiKey,
      sessionKeyChanged: draft.sessionKeyChanged,
      sessionKey: config.sessionKey,
      desktopCredentialsChanged: draft.desktopCredentialsChanged,
      desktopCredentials: config.desktopCredentials,
    );
    return targetId ?? _ref.read(hermesConfigProvider).connectionId;
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
    final previousActiveId = previousConfig.connectionId;
    final previousProfile = notifier.connections.firstWhereOrNull(
      (profile) => profile.id == previousActiveId,
    );
    final previousBackend = _ref.read(preferredBackendProvider);
    final preferredBackend = _ref.read(preferredBackendProvider.notifier);

    Future<void> restoreConnection() async {
      if (previousActiveId == null) {
        // Onboarding created the first connection; remove it again.
        final created = _ref.read(hermesConfigProvider).connectionId;
        if (created != null) await notifier.deleteConnection(created);
        return;
      }
      await notifier.saveConnection(
        connectionId: previousActiveId,
        baseUrl: previousConfig.baseUrl,
        name: previousProfile?.name,
        nameSource: previousProfile?.nameSource,
        mode: previousConfig.mode,
        desktopAuthKind: previousConfig.desktopAuthKind,
        desktopProfile: previousConfig.desktopProfile,
        allowSelfSignedCertificates: previousConfig.allowSelfSignedCertificates,
        apiKeyChanged: true,
        apiKey: previousConfig.apiKey,
        sessionKeyChanged: true,
        sessionKey: previousConfig.sessionKey,
        desktopCredentialsChanged: true,
        desktopCredentials: previousConfig.desktopCredentials,
      );
    }

    // Onboarding sets up the active connection (or the first one), never a
    // second connection beside it.
    final target = HermesConnectionDraft(
      config: draft.config.copyWith(
        connectionId: draft.config.connectionId ?? previousActiveId,
      ),
      apiKeyChanged: draft.apiKeyChanged,
      sessionKeyChanged: draft.sessionKeyChanged,
      desktopCredentialsChanged: draft.desktopCredentialsChanged,
      nameSource: draft.nameSource,
    );

    await runHermesOnboardingCommit(
      isCurrent: isCurrent,
      persist: () => persist(target),
      enable: () => notifier.setEnabled(true),
      ensureSessionKey: target.config.mode == HermesBackendMode.responsesApi
          ? notifier.ensureSessionKey
          : () async => '',
      selectBackend: () => preferredBackend.set(PreferredBackend.hermes),
      rollback: () => runHermesOnboardingRollback(
        previousEnabled: previousConfig.enabled,
        setEnabled: notifier.setEnabled,
        restoreConnection: restoreConnection,
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
