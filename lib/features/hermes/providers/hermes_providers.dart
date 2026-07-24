import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/models/prompt.dart';
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart'
    show
        activeConversationProvider,
        activeServerProvider,
        incompleteLogoutFenceProvider,
        reviewerModeProvider;
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/providers/storage_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/hermes_capabilities.dart';
import '../models/hermes_config.dart';
import '../models/hermes_job.dart';
import '../models/hermes_session.dart';
import '../models/hermes_toolset.dart';
import '../services/hermes_api_service.dart';
import '../services/hermes_identifier.dart';
import '../services/hermes_local_document_trust_store.dart';
import '../services/hermes_message_mapper.dart';
import '../services/hermes_session_provenance.dart';

final class _HermesCredentialRollbackFailure implements Exception {
  const _HermesCredentialRollbackFailure({
    required this.writeError,
    required this.writeStackTrace,
  });

  final Object writeError;
  final StackTrace writeStackTrace;
}

/// Owns the Hermes config: non-secret fields from shared preferences, secrets
/// from secure storage. Exposes setters that persist and update state.
class HermesConfigController extends Notifier<HermesConfig> {
  String? _runtimeDocumentTrustPrincipalId;
  Future<void>? _pendingDocumentTrustPrincipalWrite;

  Future<void> _mutationQueue = Future<void>.value();
  Future<void>? _secretsHydration;
  _HermesSessionKeyRequest? _sessionKeyRequest;
  bool _runAdmissionBlocked = false;
  bool _appDataClearBlocked = false;
  bool _durableLogoutFenceBlocked = false;
  HermesConfig? _configBeforeAppDataClear;
  int _connectionMutationEpoch = 0;
  int _secretLoadEpoch = 0;

  bool get _mutationsBlocked =>
      _appDataClearBlocked || _durableLogoutFenceBlocked;

  @override
  HermesConfig build() {
    final epoch = ++_secretLoadEpoch;
    _durableLogoutFenceBlocked = ref.watch(incompleteLogoutFenceProvider);
    if (_durableLogoutFenceBlocked) {
      _runAdmissionBlocked = true;
      _secretsHydration = Future<void>.value();
      return const HermesConfig();
    }
    if (_appDataClearBlocked) {
      _runAdmissionBlocked = true;
      _secretsHydration = Future<void>.value();
      return _configBeforeAppDataClear ?? const HermesConfig();
    }
    _runAdmissionBlocked = false;
    final enabled =
        PreferencesStore.getBool(PreferenceKeys.hermesEnabled) ?? false;
    final baseUrl =
        PreferencesStore.getString(PreferenceKeys.hermesBaseUrl) ?? '';
    // Secrets load asynchronously and patch the state in once available.
    final hydration = _loadSecrets(epoch);
    _secretsHydration = hydration;
    unawaited(hydration);
    return HermesConfig(enabled: enabled, baseUrl: baseUrl);
  }

  SecureCredentialStorage get _secure =>
      SecureCredentialStorage(instance: ref.read(secureStorageProvider));

  Future<void> _loadSecrets(int epoch) async {
    try {
      final apiKey = await _secure.getHermesApiKey();
      final sessionKey = await _secure.getHermesSessionKey();
      if (epoch != _secretLoadEpoch || _mutationsBlocked || !ref.mounted) {
        return;
      }
      ref.read(hermesSecretsErrorProvider.notifier).clear();
      state = HermesConfig(
        enabled: state.enabled,
        baseUrl: state.baseUrl,
        apiKey: apiKey,
        sessionKey: sessionKey,
      );
    } catch (error) {
      if (epoch != _secretLoadEpoch || _mutationsBlocked || !ref.mounted) {
        return;
      }
      // Missing secrets are represented by successful null reads. A thrown
      // keychain/keystore failure is materially different: preserve it so the
      // UI can explain the outage and offer a retry instead of pretending the
      // user never configured Hermes.
      ref.read(hermesSecretsErrorProvider.notifier).set(error);
    } finally {
      if (epoch == _secretLoadEpoch && ref.mounted) {
        ref.read(hermesSecretsLoadingProvider.notifier).set(false);
      }
    }
  }

  Future<void> retrySecrets() {
    final epoch = ++_secretLoadEpoch;
    ref.read(hermesSecretsErrorProvider.notifier).clear();
    ref.read(hermesSecretsLoadingProvider.notifier).set(true);
    final hydration = _loadSecrets(epoch);
    _secretsHydration = hydration;
    return hydration;
  }

  Future<void> setEnabled(bool value) async {
    await _serializeMutation(() async {
      if (state.enabled && !value) {
        await _withRunAdmissionBlocked(() async {
          await _cancelActiveRuns();
          await PreferencesStore.putChecked(
            PreferenceKeys.hermesEnabled,
            value,
          );
          state = _withState(enabled: value);
        });
        return;
      }
      await PreferencesStore.putChecked(PreferenceKeys.hermesEnabled, value);
      state = _withState(enabled: value);
    });
  }

  Future<void> setBaseUrl(String value) async {
    await saveConnection(baseUrl: value);
  }

  Future<void> setApiKey(String value) async {
    await saveConnection(
      baseUrl: state.baseUrl,
      apiKeyChanged: true,
      apiKey: value,
    );
  }

  Future<void> setSessionKey(String value) async {
    await saveConnection(
      baseUrl: state.baseUrl,
      sessionKeyChanged: true,
      sessionKey: value,
    );
  }

  /// Atomically commits connection edits. Secrets are retained only when the
  /// normalized origin (scheme + host + port) is unchanged.
  Future<void> saveConnection({
    required String baseUrl,
    bool apiKeyChanged = false,
    String? apiKey,
    bool sessionKeyChanged = false,
    String? sessionKey,
  }) {
    final trimmedUrl = baseUrl.trim();
    final nextOrigin = connectionOrigin(trimmedUrl);
    if (trimmedUrl.isNotEmpty && nextOrigin == null) {
      return Future<void>.error(
        ArgumentError.value(baseUrl, 'baseUrl', 'Use a valid http(s) URL'),
      );
    }

    return _serializeMutation(() async {
      // Resolve the one cold-start read before applying edits. This prevents a
      // same-origin save from accidentally replacing not-yet-hydrated secrets
      // with null, while the serialized queue prevents write reordering.
      await _secretsHydration;
      _throwIfSecretsUnavailable();
      final previousBaseUrl = state.baseUrl;
      final originChanged = connectionOrigin(previousBaseUrl) != nextOrigin;
      final endpointChanged =
          connectionEndpoint(previousBaseUrl) != connectionEndpoint(trimmedUrl);
      final identityChanged = apiKeyChanged || sessionKeyChanged;
      final serviceWillRotate = state.baseUrl != trimmedUrl || identityChanged;
      final previousApiKey = state.apiKey;
      final previousSessionKey = state.sessionKey;
      var nextApiKey = previousApiKey;
      var nextSessionKey = previousSessionKey;

      if (originChanged) {
        nextApiKey = null;
        nextSessionKey = null;
      }

      if (apiKeyChanged) {
        final value = apiKey?.trim() ?? '';
        nextApiKey = value.isEmpty ? null : value;
      }

      if (sessionKeyChanged) {
        final value = sessionKey?.trim() ?? '';
        nextSessionKey = value.isEmpty ? null : value;
      }
      final writeApiKey = originChanged || apiKeyChanged;
      final writeSessionKey = originChanged || sessionKeyChanged;

      Future<void> commitConnectionMutation() async {
        if (endpointChanged || identityChanged) {
          // This random, non-secret epoch scopes local document provenance to
          // one configured principal without persisting a credential verifier.
          // Rotate before credential mutation so any later failure is
          // fail-closed. Run admission is already blocked at this point.
          try {
            await _pendingDocumentTrustPrincipalWrite;
          } catch (_) {
            // A fresh rotation below replaces a failed lazy initialization.
          }
          final nextPrincipalId = const Uuid().v4();
          await PreferencesStore.putChecked(
            PreferenceKeys.hermesLocalDocumentTrustPrincipal,
            nextPrincipalId,
          );
          _runtimeDocumentTrustPrincipalId = nextPrincipalId;
          _pendingDocumentTrustPrincipalWrite = null;
        }

        // Secure storage and SharedPreferences cannot participate in one
        // transaction. Remove the endpoint before changing credential identity
        // so a process kill between secret writes can restart only into a
        // disabled service, never a live endpoint with mixed credentials.
        final endpointPreQuarantined = originChanged || identityChanged;
        if (endpointPreQuarantined) {
          await PreferencesStore.putChecked(PreferenceKeys.hermesBaseUrl, null);
        }

        try {
          await _persistSecretsAtomically(
            previousApiKey: previousApiKey,
            previousSessionKey: previousSessionKey,
            nextApiKey: nextApiKey,
            nextSessionKey: nextSessionKey,
            writeApiKey: writeApiKey,
            writeSessionKey: writeSessionKey,
          );
        } on _HermesCredentialRollbackFailure catch (failure) {
          // A partially committed secret mutation with a failed rollback must
          // never remain paired with the previous durable endpoint. Quarantine
          // the endpoint (or, if preferences are unavailable, every touched
          // secret) and revoke the in-memory service before surfacing the
          // original secure-storage error.
          await _quarantineUncertainCredentialMutation(
            clearApiKey: writeApiKey,
            clearSessionKey: writeSessionKey,
          );
          Error.throwWithStackTrace(
            failure.writeError,
            failure.writeStackTrace,
          );
        } catch (error, stackTrace) {
          // Ordinary write failures reached here only after exact credential
          // rollback. Restore the endpoint removed for the crash-safe window;
          // if that durable recovery is uncertain, quarantine the connection.
          if (endpointPreQuarantined) {
            try {
              await PreferencesStore.putChecked(
                PreferenceKeys.hermesBaseUrl,
                previousBaseUrl,
              );
            } catch (recoveryError) {
              DebugLogger.error(
                'endpoint-recovery-after-credential-write-failed',
                scope: 'hermes/config',
                data: {'errorType': recoveryError.runtimeType.toString()},
              );
              await _quarantineUncertainCredentialMutation(
                clearApiKey: writeApiKey,
                clearSessionKey: writeSessionKey,
              );
            }
          }
          Error.throwWithStackTrace(error, stackTrace);
        }

        try {
          await PreferencesStore.putChecked(
            PreferenceKeys.hermesBaseUrl,
            trimmedUrl,
          );
        } catch (error, stackTrace) {
          // The endpoint preference and its secure credentials live in separate
          // stores. If the endpoint cannot be made durable, restore the old keys
          // before restoring the old cached/durable URL so a restart cannot send
          // replacement-origin credentials to the previous server.
          var previousCredentialsRestored = false;
          try {
            await _persistSecretsAtomically(
              previousApiKey: nextApiKey,
              previousSessionKey: nextSessionKey,
              nextApiKey: previousApiKey,
              nextSessionKey: previousSessionKey,
              writeApiKey: writeApiKey,
              writeSessionKey: writeSessionKey,
            );
            previousCredentialsRestored = true;
          } catch (rollbackError) {
            DebugLogger.error(
              'credential-rollback-after-endpoint-failure-failed',
              scope: 'hermes/config',
              data: {'errorType': rollbackError.runtimeType.toString()},
            );
            // If exact restoration is unavailable, removing the affected keys
            // is safer than pairing credentials of uncertain origin with the
            // previous endpoint after restart.
            try {
              if (writeApiKey) await _persistApiKey(null);
              if (writeSessionKey) await _persistSessionKey(null);
              previousCredentialsRestored = true;
            } catch (clearError) {
              DebugLogger.error(
                'credential-clear-after-endpoint-failure-failed',
                scope: 'hermes/config',
                data: {'errorType': clearError.runtimeType.toString()},
              );
            }
          }
          if (previousCredentialsRestored) {
            try {
              await PreferencesStore.putChecked(
                PreferenceKeys.hermesBaseUrl,
                previousBaseUrl,
              );
            } catch (rollbackError) {
              DebugLogger.error(
                'endpoint-recovery-write-failed',
                scope: 'hermes/config',
                data: {'errorType': rollbackError.runtimeType.toString()},
              );
              await _quarantineUncertainCredentialMutation(
                clearApiKey: writeApiKey,
                clearSessionKey: writeSessionKey,
              );
            }
          } else {
            await _quarantineUncertainCredentialMutation(
              clearApiKey: writeApiKey,
              clearSessionKey: writeSessionKey,
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }

        if (endpointChanged || identityChanged) {
          // Endpoint and secret changes can switch servers, accounts, or memory
          // principals. Never carry the old server-side session across them.
          ref.read(hermesActiveSessionProvider.notifier).set(null);
          final activeConversation = ref.read(activeConversationProvider);
          if (isNativeHermesConversation(activeConversation)) {
            ref.read(activeConversationProvider.notifier).clear();
          }
        }

        state = HermesConfig(
          enabled: state.enabled,
          baseUrl: trimmedUrl,
          apiKey: nextApiKey,
          sessionKey: nextSessionKey,
        );
      }

      if (serviceWillRotate) {
        await _withRunAdmissionBlocked(() async {
          // Revoke every old generation before rotating provenance or
          // credentials. The admission guard remains raised while owner-bound
          // cleanup settles and throughout commit or rollback.
          await _cancelActiveRuns();
          await commitConnectionMutation();
        });
      } else {
        await commitConnectionMutation();
      }
    });
  }

  Future<void> _serializeMutation(Future<void> Function() operation) {
    if (_mutationsBlocked) {
      return Future<void>.error(
        StateError('Hermes changes are unavailable while signing out.'),
      );
    }
    // Keep the caller-visible result separate from the internal queue tail. The
    // result must preserve this operation's error, while the tail must always
    // settle successfully so one failed secure-storage/preferences write cannot
    // prevent every later mutation from running.
    final result = _mutationQueue.then<void>(
      (_) => operation(),
      // Defensive recovery if an older implementation or unexpected callback
      // ever left the internal tail in an error state.
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Rejects new config writes, drains already-queued writes, and revokes
  /// runtime work before a full app-data wipe.
  Future<void> blockMutationsForAppDataClear() async {
    _configBeforeAppDataClear ??= state;
    _appDataClearBlocked = true;
    _runAdmissionBlocked = true;
    _secretLoadEpoch++;
    _secretsHydration = Future<void>.value();
    _connectionMutationEpoch++;
    await _mutationQueue;
    _runAdmissionBlocked = true;
    await _cancelActiveRuns();
  }

  /// Restores mutation and run admission if the app-data wipe loses ownership
  /// to a newer authenticated session.
  void resumeMutationsAfterAppDataClearAbort() {
    if (!ref.mounted) return;
    _appDataClearBlocked = false;
    if (_durableLogoutFenceBlocked) {
      _runAdmissionBlocked = true;
      return;
    }
    final previous = _configBeforeAppDataClear;
    if (previous != null) {
      state = previous;
      _configBeforeAppDataClear = null;
    }
    final epoch = ++_secretLoadEpoch;
    final hydration = _loadSecrets(epoch);
    _secretsHydration = hydration;
    unawaited(hydration);
    _runAdmissionBlocked = false;
  }

  /// Removes live connection authority after a partial wipe while the durable
  /// incomplete-logout fence keeps config and run admission blocked.
  void revokeRuntimeAfterIncompleteAppDataClear() {
    if (!ref.mounted) return;
    // The durable fence owns the persistent block after an incomplete wipe.
    _appDataClearBlocked = false;
    _configBeforeAppDataClear = null;
    state = const HermesConfig();
    ref.read(hermesActiveSessionProvider.notifier).set(null);
    final activeConversation = ref.read(activeConversationProvider);
    if (isNativeHermesConversation(activeConversation)) {
      ref.read(activeConversationProvider.notifier).clear();
    }
  }

  Future<void> _persistSecretsAtomically({
    required String? previousApiKey,
    required String? previousSessionKey,
    required String? nextApiKey,
    required String? nextSessionKey,
    required bool writeApiKey,
    required bool writeSessionKey,
  }) async {
    if (!writeApiKey && !writeSessionKey) return;
    try {
      if (writeApiKey) await _persistApiKey(nextApiKey);
      if (writeSessionKey) await _persistSessionKey(nextSessionKey);
    } catch (error, stackTrace) {
      // Secure storage has no multi-key transaction. Restore every key touched
      // by this mutation before surfacing the original failure so the old
      // server remains usable when a replacement write only partially lands.
      var rollbackSucceeded = true;
      Object? rollbackError;
      if (writeApiKey) {
        try {
          await _persistApiKey(previousApiKey);
        } catch (error) {
          rollbackSucceeded = false;
          rollbackError ??= error;
        }
      }
      if (writeSessionKey) {
        try {
          await _persistSessionKey(previousSessionKey);
        } catch (error) {
          rollbackSucceeded = false;
          rollbackError ??= error;
        }
      }
      if (!rollbackSucceeded) {
        DebugLogger.error(
          'credential-rollback-failed',
          scope: 'hermes/config',
          data: {'errorType': rollbackError.runtimeType.toString()},
        );
        throw _HermesCredentialRollbackFailure(
          writeError: error,
          writeStackTrace: stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _quarantineUncertainCredentialMutation({
    required bool clearApiKey,
    required bool clearSessionKey,
  }) async {
    var endpointQuarantined = false;
    try {
      await PreferencesStore.putChecked(PreferenceKeys.hermesBaseUrl, null);
      endpointQuarantined = true;
    } catch (error) {
      DebugLogger.error(
        'endpoint-quarantine-after-credential-rollback-failed',
        scope: 'hermes/config',
        data: {'errorType': error.runtimeType.toString()},
      );
    }

    var secretsCleared = true;
    if (!endpointQuarantined && clearApiKey) {
      try {
        await _persistApiKey(null);
      } catch (error) {
        secretsCleared = false;
        DebugLogger.error(
          'api-key-quarantine-failed',
          scope: 'hermes/config',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }
    if (!endpointQuarantined && clearSessionKey) {
      try {
        await _persistSessionKey(null);
      } catch (error) {
        secretsCleared = false;
        DebugLogger.error(
          'session-key-quarantine-failed',
          scope: 'hermes/config',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }

    _clearRuntimeConnection();
    if (!endpointQuarantined && !secretsCleared) {
      // One last checked endpoint write handles transient preference failures
      // after best-effort secret clearing. If both stores remain unavailable,
      // keep the runtime disabled and surface the quarantine failure.
      try {
        await PreferencesStore.putChecked(PreferenceKeys.hermesBaseUrl, null);
        return;
      } catch (_, stackTrace) {
        Error.throwWithStackTrace(
          StateError('Hermes credentials could not be safely quarantined.'),
          stackTrace,
        );
      }
    }
  }

  void _clearRuntimeConnection() {
    state = HermesConfig(enabled: state.enabled);
    ref.read(hermesActiveSessionProvider.notifier).set(null);
    final activeConversation = ref.read(activeConversationProvider);
    if (isNativeHermesConversation(activeConversation)) {
      ref.read(activeConversationProvider.notifier).clear();
    }
  }

  Future<void> _persistApiKey(String? value) => value == null
      ? _secure.deleteHermesApiKey()
      : _secure.saveHermesApiKey(value);

  Future<void> _persistSessionKey(String? value) => value == null
      ? _secure.deleteHermesSessionKey()
      : _secure.saveHermesSessionKey(value);

  Future<T> _withRunAdmissionBlocked<T>(Future<T> Function() operation) async {
    _runAdmissionBlocked = true;
    _connectionMutationEpoch++;
    try {
      return await operation();
    } finally {
      if (!_mutationsBlocked) {
        _runAdmissionBlocked = false;
      }
    }
  }

  /// Captures permission for a non-run session action (open/fork/delete).
  /// A null result means a connection mutation is already in progress.
  int? captureSessionActionAdmission() =>
      _runAdmissionBlocked || _mutationsBlocked
      ? null
      : _connectionMutationEpoch;

  /// Revalidates an action after an await so an endpoint/principal mutation
  /// cannot apply stale results to the replacement account.
  bool sessionActionAdmissionIsCurrent(int admission) =>
      !_runAdmissionBlocked &&
      !_mutationsBlocked &&
      admission == _connectionMutationEpoch;

  Future<void> _cancelActiveRuns() async {
    final stopFutures = ref.read(hermesRunRegistryProvider).cancelAll();

    // cancelAll() revokes every run token synchronously. Interrupt session-key
    // preparation only after that ownership boundary has moved so chat
    // preflight observes cancellation instead of surfacing a configuration
    // error. The admission guard is established first so a synchronous
    // cancellation callback cannot start a replacement request.
    //
    // A request can also come from setup or settings without a registry entry,
    // so it must be interrupted even when cancelAll() returns no futures.
    // Letting either kind continue can create a cycle:
    //
    // config mutation -> cancellationSettled -> ensureSessionKey mutation
    //        ^                                      |
    //        +--------------------------------------+
    final sessionKeyRequest = _sessionKeyRequest;
    if (sessionKeyRequest != null) {
      _sessionKeyRequest = null;
      sessionKeyRequest.interrupt();
    }

    await Future.wait<void>([
      for (final stop in stopFutures) stop.catchError((_) {}),
    ]);
  }

  /// Canonical origin used to bind secrets to their intended server.
  static String? connectionOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
  }

  /// Canonical request root used to detect when the currently configured
  /// Hermes endpoint changes. `/v1` and a trailing slash are equivalent because
  /// [HermesApiService] strips them before composing request paths.
  static String? connectionEndpoint(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('/v1')) {
      normalized = normalized.substring(0, normalized.length - '/v1'.length);
    }

    final uri = Uri.tryParse(normalized);
    final origin = connectionOrigin(normalized);
    if (uri == null || origin == null) return null;
    return '$origin${uri.path}'
        '${uri.hasQuery ? '?${uri.query}' : ''}'
        '${uri.hasFragment ? '#${uri.fragment}' : ''}';
  }

  String documentTrustPrincipalId() {
    final existing = PreferencesStore.getString(
      PreferenceKeys.hermesLocalDocumentTrustPrincipal,
    )?.trim();
    if (existing != null &&
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(existing)) {
      _runtimeDocumentTrustPrincipalId = existing;
      return existing;
    }
    final principalId = _runtimeDocumentTrustPrincipalId ??= const Uuid().v4();
    if (!PreferencesStore.isReady ||
        _pendingDocumentTrustPrincipalWrite != null) {
      return principalId;
    }
    final write = PreferencesStore.putChecked(
      PreferenceKeys.hermesLocalDocumentTrustPrincipal,
      principalId,
    );
    _pendingDocumentTrustPrincipalWrite = write;
    unawaited(
      write.then<void>(
        (_) {
          if (_runtimeDocumentTrustPrincipalId == principalId) {
            _pendingDocumentTrustPrincipalWrite = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (_runtimeDocumentTrustPrincipalId == principalId) {
            _pendingDocumentTrustPrincipalWrite = null;
          }
        },
      ),
    );
    return principalId;
  }

  /// Returns the long-term memory session key, generating and persisting a
  /// stable one when the user has not set their own. Keeps Hermes memory
  /// associated with this install across restarts.
  Future<String> ensureSessionKey() {
    if (_runAdmissionBlocked) {
      return Future<String>.error(
        StateError('Hermes configuration is changing. Try again.'),
        StackTrace.current,
      );
    }

    final pending = _sessionKeyRequest;
    if (pending != null) return pending.future;

    final request = _HermesSessionKeyRequest();
    _sessionKeyRequest = request;
    // Fulfilment owns every error and reports it through request.future. This
    // detached task must therefore never produce an unobserved async failure.
    unawaited(_fulfillSessionKeyRequest(request));
    return request.future;
  }

  void _throwIfSecretsUnavailable() {
    if (ref.read(hermesSecretsErrorProvider) != null) {
      throw StateError(
        'Hermes secure storage is unavailable. Retry credential loading first.',
      );
    }
  }

  Future<void> _fulfillSessionKeyRequest(
    _HermesSessionKeyRequest request,
  ) async {
    try {
      await _secretsHydration;
      if (request.interrupted) return;
      _throwIfSecretsUnavailable();

      final hydrated = state.sessionKey;
      if (hydrated != null && hydrated.isNotEmpty) {
        request.complete(hydrated);
        return;
      }

      String? resolved;
      await _serializeMutation(() async {
        if (request.interrupted) return;

        // An explicit connection edit may have supplied a key while this
        // request waited for the serialized mutation lane. It is authoritative
        // and must never be overwritten by an earlier automatic generation.
        final existing = state.sessionKey;
        if (existing != null && existing.isNotEmpty) {
          resolved = existing;
          return;
        }

        final generated = const Uuid().v4();
        await _secure.saveHermesSessionKey(generated);
        state = _withState(sessionKey: generated);
        resolved = generated;
      });

      if (request.interrupted) return;
      final value = resolved;
      if (value == null) {
        throw StateError('Hermes session-key preparation did not complete.');
      }
      request.complete(value);
    } catch (error, stackTrace) {
      request.completeError(error, stackTrace);
    } finally {
      if (identical(_sessionKeyRequest, request)) {
        _sessionKeyRequest = null;
      }
    }
  }

  HermesConfig _withState({
    bool? enabled,
    String? baseUrl,
    String? apiKey = _keep,
    String? sessionKey = _keep,
  }) {
    return HermesConfig(
      enabled: enabled ?? state.enabled,
      baseUrl: baseUrl ?? state.baseUrl,
      apiKey: identical(apiKey, _keep) ? state.apiKey : apiKey,
      sessionKey: identical(sessionKey, _keep) ? state.sessionKey : sessionKey,
    );
  }

  // Sentinel so setters can distinguish "leave unchanged" from "clear to null".
  static const String _keep = '__hermes_keep__';
}

final class _HermesSessionKeyRequest {
  final Completer<String> _result = Completer<String>();
  bool _interrupted = false;

  Future<String> get future => _result.future;
  bool get interrupted => _interrupted;

  void complete(String value) {
    if (!_result.isCompleted) _result.complete(value);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_result.isCompleted) _result.completeError(error, stackTrace);
  }

  void interrupt() {
    if (_result.isCompleted) return;
    _interrupted = true;
    _result.completeError(
      StateError('Hermes configuration changed during session preparation.'),
      StackTrace.current,
    );
  }
}

class HermesSecretsLoading extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

/// True until the initial secure-storage hydration settles (success or error).
final hermesSecretsLoadingProvider =
    NotifierProvider<HermesSecretsLoading, bool>(HermesSecretsLoading.new);

class HermesSecretsError extends Notifier<Object?> {
  @override
  Object? build() => null;

  void set(Object error) => state = error;

  void clear() => state = null;
}

/// A secure-storage access failure, distinct from successfully reading no key.
final hermesSecretsErrorProvider =
    NotifierProvider<HermesSecretsError, Object?>(HermesSecretsError.new);

final hermesConfigProvider =
    NotifierProvider<HermesConfigController, HermesConfig>(
      HermesConfigController.new,
    );

/// Whether the Hermes agent is toggled on (regardless of whether it is fully
/// configured). Used to decide whether to surface the synthetic model.
final hermesEnabledProvider = Provider<bool>(
  (ref) => ref.watch(hermesConfigProvider).enabled,
);

/// True when Hermes is the only currently usable primary backend. A retained
/// OpenWebUI server does not make the session mixed-mode after its user signs
/// out; it becomes optional again until re-authenticated. Reviewer mode takes
/// precedence.
final hermesOnlyModeProvider = Provider<bool>((ref) {
  if (ref.watch(reviewerModeProvider)) return false;
  if (!ref.watch(hermesConfigProvider).isUsable) return false;
  final preferredBackend = ref.watch(preferredBackendProvider);
  // With no OpenWebUI server, legacy Hermes-only installs may still have an
  // unset preference. A deliberate Direct primary must never inherit Hermes'
  // sidebar/profile presentation merely because Hermes is also configured.
  if (preferredBackend == PreferredBackend.direct) return false;
  final activeServer = ref.watch(activeServerProvider);
  if (activeServer.hasValue && activeServer.requireValue == null) return true;
  if (preferredBackend != PreferredBackend.hermes) {
    return false;
  }
  // Loading/error states may retain a previous server value during refresh.
  // Until a server resolves successfully, there is no usable OpenWebUI surface
  // to expose even if an old auth token is still cached.
  if (activeServer.isLoading || activeServer.hasError) return true;
  if (!activeServer.hasValue) return true;
  final openWebUiAuthenticated = ref
      .watch(authStateManagerProvider)
      .maybeWhen(data: (state) => state.isAuthenticated, orElse: () => false);
  return !openWebUiAuthenticated;
});

/// The Hermes client, or null when Hermes is disabled / not fully configured.
final hermesApiServiceProvider = Provider<HermesApiService?>((ref) {
  final config = ref.watch(hermesConfigProvider);
  if (!config.isUsable) return null;
  final service = HermesApiService(config: config);
  ref.onDispose(service.close);
  return service;
});

/// The Hermes agent's skills mapped to [Prompt]s so they can drive the existing
/// `/` slash-command overlay. Selecting one inserts `/skill-name ` into the
/// composer, which the agent interprets natively. Empty when Hermes is off.
final hermesSkillPromptsProvider = FutureProvider<List<Prompt>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const [];
  final skills = await service.listSkills();
  final prompts = <Prompt>[];
  for (final skill in skills) {
    if (prompts.length >= 256) break;
    final name = validateHermesOpaqueIdentifier(skill['name']);
    if (name == null) continue;
    final description = validateHermesBoundedString(
      skill['description'],
      maxCharacters: 4096,
      allowEmpty: true,
    );
    prompts.add(
      Prompt(command: '/$name', title: description ?? '', content: '/$name '),
    );
  }
  return prompts;
});

/// The Hermes server-side session bound to the current chat, or null for a
/// fresh chat with no session yet. Created lazily on the first Hermes turn and
/// reused for follow-ups; cleared on "new chat"; set when opening a session
/// from the sessions browser.
class HermesActiveSession extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? sessionId) => state = sessionId;
}

final hermesActiveSessionProvider =
    NotifierProvider<HermesActiveSession, String?>(HermesActiveSession.new);

/// Invalidates asynchronous Hermes-session opens whenever navigation changes.
class HermesSessionNavigationEpoch extends Notifier<int> {
  @override
  int build() => 0;

  int bump() {
    state++;
    return state;
  }
}

final hermesSessionNavigationEpochProvider =
    NotifierProvider<HermesSessionNavigationEpoch, int>(
      HermesSessionNavigationEpoch.new,
    );

/// Aligns a fork's freshly inserted rows with its source history. Any shape,
/// order, role, content, or identity mismatch rejects the entire mapping so
/// provenance can never slide onto a merely similar prompt.
Map<String, String>? alignHermesForkedMessageIds(
  List<Map<String, dynamic>> source,
  List<Map<String, dynamic>> target,
) {
  if (source.length != target.length) return null;
  final sourceIds = <String>{};
  final targetIds = <String>{};
  final mapping = <String, String>{};
  for (var index = 0; index < source.length; index++) {
    final sourceRow = source[index];
    final targetRow = target[index];
    final sourceRoleValue = sourceRow['role'] ?? sourceRow['author'];
    final targetRoleValue = targetRow['role'] ?? targetRow['author'];
    final sourceRole = sourceRoleValue is String && sourceRoleValue.length <= 32
        ? sourceRoleValue.toLowerCase()
        : null;
    final targetRole = targetRoleValue is String && targetRoleValue.length <= 32
        ? targetRoleValue.toLowerCase()
        : null;
    final sourceId = validateHermesOpaqueIdentifier(sourceRow['id']);
    final targetId = validateHermesOpaqueIdentifier(targetRow['id']);
    final sourceContent = hermesMessageTextContent(
      sourceRow['content'] ?? sourceRow['text'],
    );
    final targetContent = hermesMessageTextContent(
      targetRow['content'] ?? targetRow['text'],
    );
    if (sourceRole == null ||
        sourceRole != targetRole ||
        sourceId == null ||
        sourceId.isEmpty ||
        targetId == null ||
        targetId.isEmpty ||
        !sourceIds.add(sourceId) ||
        !targetIds.add(targetId) ||
        sourceContent == null ||
        targetContent == null ||
        sourceContent != targetContent) {
      return null;
    }
    mapping[sourceId] = targetId;
  }
  return mapping;
}

/// The user's Hermes sessions (server-side transcripts), newest first.
class HermesSessionsController
    extends AsyncNotifier<List<HermesSessionSummary>> {
  @override
  Future<List<HermesSessionSummary>> build() async {
    final service = ref.watch(hermesApiServiceProvider);
    if (service == null) return const [];
    final raw = await service.listSessions();
    final sessions = <HermesSessionSummary>[];
    for (final item in raw) {
      final summary = HermesSessionSummary.fromJson(item);
      if (summary != null) sessions.add(summary);
    }
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    sessions.sort(
      (a, b) => (b.updatedAt ?? epoch).compareTo(a.updatedAt ?? epoch),
    );
    return sessions;
  }

  HermesApiService? get _service => ref.read(hermesApiServiceProvider);

  /// Forks a session and returns the new session id (null if Hermes is off).
  Future<String?> fork(String id) async {
    final sourceSessionId = validateHermesOpaqueIdentifier(id);
    if (sourceSessionId == null) return null;
    final configController = ref.read(hermesConfigProvider.notifier);
    final admission = configController.captureSessionActionAdmission();
    if (admission == null) return null;
    final service = _service;
    if (service == null) return null;
    final endpointIdentity = HermesConfigController.connectionEndpoint(
      service.config.baseUrl,
    );
    final principalId = configController.documentTrustPrincipalId();
    final connectionIdentity = endpointIdentity == null
        ? null
        : HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpointIdentity,
            principalId: principalId,
          );
    List<Map<String, dynamic>>? sourceHistory;
    if (connectionIdentity != null &&
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: connectionIdentity,
          sessionId: sourceSessionId,
        ).isNotEmpty) {
      try {
        sourceHistory = await service.getSessionMessages(sourceSessionId);
      } catch (_) {
        DebugLogger.warning(
          'local-document-trust-fork-source-failed',
          scope: 'hermes/sessions',
        );
      }
    }
    if (!configController.sessionActionAdmissionIsCurrent(admission) ||
        !identical(ref.read(hermesApiServiceProvider), service) ||
        configController.documentTrustPrincipalId() != principalId) {
      return null;
    }
    final newId = await service.forkSession(sourceSessionId);

    bool forkContextIsCurrent() =>
        configController.sessionActionAdmissionIsCurrent(admission) &&
        identical(ref.read(hermesApiServiceProvider), service) &&
        configController.documentTrustPrincipalId() == principalId;

    Future<void> discardStaleFork() async {
      if (connectionIdentity != null) {
        try {
          await HermesLocalDocumentTrustStore.forgetSession(
            connectionIdentity: connectionIdentity,
            sessionId: newId,
          );
        } catch (_) {
          DebugLogger.warning(
            'local-document-trust-stale-fork-purge-failed',
            scope: 'hermes/sessions',
          );
        }
      }
      try {
        await service.deleteSession(newId);
      } catch (_) {
        DebugLogger.warning(
          'stale-fork-delete-failed',
          scope: 'hermes/sessions',
        );
      }
    }

    if (!forkContextIsCurrent()) {
      await discardStaleFork();
      return null;
    }
    if (connectionIdentity != null) {
      var trustRebound = false;
      try {
        final identityStillCurrent = forkContextIsCurrent();
        if (identityStillCurrent && sourceHistory != null) {
          final targetHistory = await service.getSessionMessages(newId);
          final stillCurrentAfterTarget = forkContextIsCurrent();
          final messageIdMap = stillCurrentAfterTarget
              ? alignHermesForkedMessageIds(sourceHistory, targetHistory)
              : null;
          if (messageIdMap != null) {
            await HermesLocalDocumentTrustStore.rebindForkedSession(
              connectionIdentity: connectionIdentity,
              sourceSessionId: sourceSessionId,
              targetSessionId: newId,
              messageIdMap: messageIdMap,
            );
            trustRebound = true;
          }
        }
      } catch (_) {
        DebugLogger.warning(
          'local-document-trust-fork-rebind-failed',
          scope: 'hermes/sessions',
        );
      }
      if (!trustRebound) {
        try {
          await HermesLocalDocumentTrustStore.prepareNewSession(
            connectionIdentity: connectionIdentity,
            sessionId: newId,
          );
        } catch (_) {
          DebugLogger.warning(
            'local-document-trust-fork-purge-failed',
            scope: 'hermes/sessions',
          );
          await discardStaleFork();
          return null;
        }
      }
    }
    if (!forkContextIsCurrent()) {
      await discardStaleFork();
      return null;
    }
    ref.invalidateSelf();
    return newId;
  }

  Future<void> rename(String id, String title) async {
    final configController = ref.read(hermesConfigProvider.notifier);
    final admission = configController.captureSessionActionAdmission();
    if (admission == null) {
      throw StateError('Hermes connection is changing. Try again.');
    }
    final service = _service;
    if (service == null) return;
    await service.renameSession(id, title);
    if (configController.sessionActionAdmissionIsCurrent(admission) &&
        identical(ref.read(hermesApiServiceProvider), service)) {
      ref.invalidateSelf();
    }
  }

  /// Returns whether the remote DELETE completed.
  ///
  /// A connection rotation can supersede this action after durable trust is
  /// purged but before any request is sent. Callers must not tear down local
  /// session state when that happens.
  Future<bool> delete(String id) async {
    final configController = ref.read(hermesConfigProvider.notifier);
    final admission = configController.captureSessionActionAdmission();
    if (admission == null) {
      throw StateError('Hermes connection is changing. Try again.');
    }
    final service = _service;
    if (service == null) return false;
    final endpointIdentity = HermesConfigController.connectionEndpoint(
      service.config.baseUrl,
    );
    final principalId = configController.documentTrustPrincipalId();
    final connectionIdentity = endpointIdentity == null
        ? null
        : HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpointIdentity,
            principalId: principalId,
          );
    if (connectionIdentity != null) {
      // Revoke durable provenance before the destructive request. A process
      // kill or lost response after the server commits deletion must not let a
      // reused session id regain trust after restart. If this checked purge
      // fails, do not issue the remote delete.
      await HermesLocalDocumentTrustStore.forgetSession(
        connectionIdentity: connectionIdentity,
        sessionId: id,
      );
    }
    if (!configController.sessionActionAdmissionIsCurrent(admission) ||
        !identical(ref.read(hermesApiServiceProvider), service) ||
        configController.documentTrustPrincipalId() != principalId) {
      return false;
    }
    await service.deleteSession(id);
    if (configController.sessionActionAdmissionIsCurrent(admission) &&
        identical(ref.read(hermesApiServiceProvider), service)) {
      ref.invalidateSelf();
    }
    return true;
  }
}

final hermesSessionsProvider =
    AsyncNotifierProvider<HermesSessionsController, List<HermesSessionSummary>>(
      HermesSessionsController.new,
    );

/// Server-advertised capabilities (`/v1/capabilities`). Falls back to the
/// optimistic all-enabled default when discovery fails, so features are only
/// hidden when the server explicitly says they're unsupported.
final hermesCapabilitiesProvider = FutureProvider<HermesCapabilities>((
  ref,
) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return HermesCapabilities.enabledByDefault;
  try {
    return HermesCapabilities.fromJson(await service.getCapabilities());
  } catch (_) {
    return HermesCapabilities.enabledByDefault;
  }
});

/// Synchronous best-effort view of capabilities for gating UI (optimistic
/// default while loading / on error).
HermesCapabilities hermesCapabilitiesNow(Ref ref) {
  return ref.read(hermesCapabilitiesProvider).asData?.value ??
      HermesCapabilities.enabledByDefault;
}

/// Resolved toolsets for the api_server platform (`/v1/toolsets`).
final hermesToolsetsProvider = FutureProvider<List<HermesToolset>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const [];
  final raw = await service.listToolsets();
  final toolsets = <HermesToolset>[];
  for (final item in raw) {
    final toolset = HermesToolset.fromJson(item);
    if (toolset != null) toolsets.add(toolset);
  }
  return toolsets;
});

/// Extended server status (`/health/detailed`): active sessions, running
/// agents, resource usage. Empty map when unavailable.
final hermesServerStatusProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const {};
  return service.healthDetailed();
});

/// The user's scheduled Hermes jobs (`/api/jobs`).
class HermesJobsController extends AsyncNotifier<List<HermesJob>> {
  @override
  Future<List<HermesJob>> build() async {
    final service = ref.watch(hermesApiServiceProvider);
    if (service == null) return const [];
    final raw = await service.listJobs();
    final jobs = <HermesJob>[];
    for (final item in raw) {
      final job = HermesJob.fromJson(item);
      if (job != null) jobs.add(job);
    }
    return jobs;
  }

  HermesApiService get _service =>
      ref.read(hermesApiServiceProvider) ??
      (throw StateError('Hermes is not configured'));

  Future<void> create({
    required String name,
    required String prompt,
    required String schedule,
  }) async {
    final service = _service;
    await service.createJob(name: name, prompt: prompt, schedule: schedule);
    ref.invalidateSelf();
  }

  Future<void> edit(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
  }) async {
    final service = _service;
    await service.updateJob(id, name: name, prompt: prompt, schedule: schedule);
    ref.invalidateSelf();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final service = _service;
    if (enabled) {
      await service.resumeJob(id);
    } else {
      await service.pauseJob(id);
    }
    ref.invalidateSelf();
  }

  Future<void> runNow(String id) async {
    await _service.runJob(id);
  }

  Future<void> delete(String id) async {
    final service = _service;
    await service.deleteJob(id);
    ref.invalidateSelf();
  }
}

final hermesJobsProvider =
    AsyncNotifierProvider<HermesJobsController, List<HermesJob>>(
      HermesJobsController.new,
    );

/// Collision-free address for a Hermes run inside a conversation.
///
/// Message ids are not globally unique: the same id may legitimately exist in
/// OpenWebUI and direct-local stores, or in two concurrently loaded chats. A
/// run therefore always owns the pair rather than the assistant id alone.
final class HermesRunBackendIdentity {
  const HermesRunBackendIdentity.openWebUi({
    required this.database,
    required this.api,
    required this.authSessionEpoch,
  });

  final Object? database;
  final Object? api;
  final Object? authSessionEpoch;

  @override
  bool operator ==(Object other) =>
      other is HermesRunBackendIdentity &&
      identical(other.database, database) &&
      identical(other.api, api) &&
      identical(other.authSessionEpoch, authSessionEpoch);

  @override
  int get hashCode => Object.hash(
    identityHashCode(database),
    identityHashCode(api),
    identityHashCode(authSessionEpoch),
  );
}

typedef HermesRunKey = ({
  String ownerConversationId,
  String assistantMessageId,
  HermesRunBackendIdentity? backendIdentity,
});

HermesRunKey hermesRunKey({
  required String ownerConversationId,
  required String assistantMessageId,
  HermesRunBackendIdentity? backendIdentity,
}) => (
  ownerConversationId: ownerConversationId,
  assistantMessageId: assistantMessageId,
  backendIdentity: backendIdentity,
);

const String _legacyHermesRunOwner = 'conduit-hermes-legacy://';

/// Compatibility address for transport-only callers without a conversation.
/// App chat flows must use [hermesRunKey] with their scoped owner instead.
HermesRunKey legacyHermesRunKey(String assistantMessageId) => (
  ownerConversationId: _legacyHermesRunOwner,
  assistantMessageId: assistantMessageId,
  backendIdentity: null,
);

/// Tracks the live event subscription + run id for each streaming Hermes
/// assistant message so a stop request can cancel the right run.
///
class HermesRunRegistry {
  final Map<HermesRunKey, _ActiveRun> _runs = {};

  CancelToken registerPending(
    HermesRunKey key, {
    CancelToken? cancelToken,
    Future<void>? cancellationSettled,
    void Function()? onCleanupSettled,
    required void Function() onCancelled,
  }) {
    final token = cancelToken ?? CancelToken();
    final existing = _runs[key];
    if (existing != null &&
        !existing.cancelled &&
        identical(existing.cancelToken, token)) {
      existing.onCancelled.add(onCancelled);
      existing.cancellationSettled ??= cancellationSettled;
      if (onCleanupSettled != null) {
        existing.onCleanupSettled.add(onCleanupSettled);
      }
      return token;
    }

    final replacement = _ActiveRun(
      cancelToken: token,
      onCancelled: [onCancelled],
      cancellationSettled: cancellationSettled,
      onCleanupSettled: [?onCleanupSettled],
    );
    // Publish the new generation before notifying the displaced one. This
    // lets owner callbacks distinguish supersession from an explicit stop and
    // prevents an old generation from completing a reused placeholder.
    _runs[key] = replacement;
    if (existing != null) {
      _observeHermesRegistryCleanup(
        () => _cancelDetached(existing),
        message: 'displaced-run-cleanup-failed',
      );
    }
    return token;
  }

  /// Attaches server state to a pending run. Returns false when the pending
  /// entry was already cancelled, in which case the subscription is cancelled.
  bool attachRun(
    HermesRunKey key, {
    required CancelToken cancelToken,
    required String runId,
    required StreamSubscription<void> subscription,
    required Future<void> Function(String runId) stopRemote,
  }) {
    final run = _runs[key];
    if (run == null ||
        run.cancelled ||
        !identical(run.cancelToken, cancelToken)) {
      _observeHermesRegistryCleanup(
        subscription.cancel,
        message: 'stale-run-subscription-cleanup-failed',
      );
      return false;
    }
    run.runId = runId;
    run.subscription = subscription;
    run.stopRemote = stopRemote;
    return true;
  }

  /// Attaches a cancellable stream that has no separate remote stop endpoint,
  /// such as Hermes Responses SSE. Cancelling the Dio token closes the stream;
  /// current Hermes servers interrupt the owning agent on disconnect.
  bool attachStream(
    HermesRunKey key, {
    required CancelToken cancelToken,
    required StreamSubscription<void> subscription,
  }) {
    final run = _runs[key];
    if (run == null ||
        run.cancelled ||
        !identical(run.cancelToken, cancelToken)) {
      _observeHermesRegistryCleanup(
        subscription.cancel,
        message: 'stale-stream-subscription-cleanup-failed',
      );
      return false;
    }
    run.subscription = subscription;
    return true;
  }

  /// Compatibility helper for callers that already have a live run.
  void register(
    HermesRunKey key, {
    required String runId,
    required CancelToken cancelToken,
    required StreamSubscription<void> subscription,
    required Future<void> Function(String runId) stopRemote,
  }) {
    registerPending(key, cancelToken: cancelToken, onCancelled: () {});
    attachRun(
      key,
      cancelToken: cancelToken,
      runId: runId,
      subscription: subscription,
      stopRemote: stopRemote,
    );
  }

  String? runIdFor(HermesRunKey key) => _runs[key]?.runId;

  /// Returns an opaque identity for the exact live run generation.
  ///
  /// Approval UI captures this before an asynchronous decision POST so a
  /// replacement that reuses the same message (or even server run id) cannot
  /// receive the old generation's result.
  Object? generationTokenFor(HermesRunKey key, {required String runId}) {
    final run = _runs[key];
    if (run == null || run.cancelled || run.runId != runId) return null;
    return run;
  }

  /// Exact transport token paired with [generationToken]. Approval callbacks
  /// retain it so owner projection state can settle after navigation or an
  /// in-place key remap without falling back to message/run ids.
  CancelToken? cancelTokenForGeneration(
    HermesRunKey key, {
    required Object generationToken,
    required String runId,
  }) {
    final run = _runs[key];
    if (run == null ||
        run.cancelled ||
        !identical(run, generationToken) ||
        run.runId != runId) {
      return null;
    }
    return run.cancelToken;
  }

  /// Whether [generationToken] still owns [key] and [runId]. The token may be
  /// checked against a newly computed key after an in-place chat-id remap.
  bool ownsGeneration(
    HermesRunKey key, {
    required Object generationToken,
    required String runId,
  }) {
    final run = _runs[key];
    return run != null &&
        !run.cancelled &&
        identical(run, generationToken) &&
        run.runId == runId;
  }

  bool owns(HermesRunKey key, {required CancelToken cancelToken}) {
    final run = _runs[key];
    return run != null &&
        !run.cancelled &&
        identical(run.cancelToken, cancelToken);
  }

  bool hasReplacement(HermesRunKey key, {required CancelToken cancelToken}) {
    final run = _runs[key];
    return run != null && !identical(run.cancelToken, cancelToken);
  }

  /// Atomically moves a live generation when a fresh Hermes shell receives
  /// its stable session-backed conversation id.
  bool rebind(
    HermesRunKey from,
    HermesRunKey to, {
    required CancelToken cancelToken,
  }) {
    final run = _runs[from];
    if (run == null ||
        run.cancelled ||
        !identical(run.cancelToken, cancelToken)) {
      return false;
    }
    if (from == to) return true;

    final displaced = _runs[to];
    _runs.remove(from);
    _runs[to] = run;
    if (displaced != null && !identical(displaced, run)) {
      _observeHermesRegistryCleanup(
        () => _cancelDetached(displaced),
        message: 'rebind-displaced-run-cleanup-failed',
      );
    }
    return true;
  }

  /// Moves exactly [cancelToken]'s generation without displacing an existing
  /// generation at [to]. A chat-id remap cannot establish which colliding run
  /// is newer, so callers must cancel the moving generation when this returns
  /// false instead of revoking the destination by key alone.
  bool rebindIfVacant(
    HermesRunKey from,
    HermesRunKey to, {
    required CancelToken cancelToken,
  }) {
    final run = _runs[from];
    if (run == null ||
        run.cancelled ||
        !identical(run.cancelToken, cancelToken)) {
      return false;
    }
    if (from == to) return true;

    final destination = _runs[to];
    if (destination != null && !identical(destination, run)) return false;
    if (!identical(_runs[from], run)) return false;
    _runs.remove(from);
    _runs[to] = run;
    return true;
  }

  /// Cancels and forgets the run for [assistantMessageId]. The returned future
  /// waits for both the owner-bound remote stop (when the run id is known) and
  /// pending transport settlement (when create/preflight is still in flight).
  Future<void>? cancel(HermesRunKey key) {
    final run = _runs.remove(key);
    if (run == null) return null;
    return _cancelDetached(run);
  }

  /// Cancels [key] only when it still belongs to [cancelToken]. This is the
  /// failure half of an exact rebind: a colliding/newer generation must never
  /// be cancelled merely because it now occupies one of the remap keys.
  Future<void>? cancelOwned(
    HermesRunKey key, {
    required CancelToken cancelToken,
  }) {
    final run = _runs[key];
    if (run == null || !identical(run.cancelToken, cancelToken)) return null;
    _runs.remove(key);
    return _cancelDetached(run);
  }

  /// Cancels the run for the visible conversation without falling back to an
  /// id-only match. With no conversation owner, cancellation is allowed only
  /// when exactly one pending/legacy run has that assistant id.
  Future<void>? cancelMessage(
    String assistantMessageId, {
    String? ownerConversationId,
    HermesRunBackendIdentity? backendIdentity,
  }) {
    if (ownerConversationId != null) {
      return cancel(
        hermesRunKey(
          ownerConversationId: ownerConversationId,
          assistantMessageId: assistantMessageId,
          backendIdentity: backendIdentity,
        ),
      );
    }
    final matches = _runs.keys
        .where((key) => key.assistantMessageId == assistantMessageId)
        .toList(growable: false);
    if (matches.length != 1) return null;
    return cancel(matches.single);
  }

  Future<void> _cancelDetached(_ActiveRun run) async {
    run.cancelled = true;
    run.cancelToken.cancel('stopped');
    for (final callback in run.onCancelled) {
      try {
        callback();
      } catch (_) {
        // One UI cleanup callback must not prevent subscription/remote cleanup.
      }
    }
    final subscription = run.subscription;
    if (subscription != null) {
      _observeHermesRegistryCleanup(
        subscription.cancel,
        message: 'run-subscription-cleanup-failed',
      );
    }
    final pending = <Future<void>>[];
    final cancellationSettled = run.cancellationSettled;
    if (cancellationSettled != null) pending.add(cancellationSettled);
    final runId = run.runId;
    final stopRemote = run.stopRemote;
    if (runId != null && stopRemote != null) {
      pending.add(Future<void>.sync(() => stopRemote(runId)));
    }
    try {
      await Future.wait<void>(pending);
    } finally {
      _reportCleanupSettled(run);
    }
  }

  List<Future<void>> cancelAll() {
    final stops = <Future<void>>[];
    for (final key in _runs.keys.toList(growable: false)) {
      final stop = cancel(key);
      if (stop != null) stops.add(stop);
    }
    return stops;
  }

  bool complete(HermesRunKey key, {required CancelToken cancelToken}) {
    final run = _runs[key];
    if (run == null || !identical(run.cancelToken, cancelToken)) return false;
    _runs.remove(key);
    _reportCleanupSettled(run);
    return true;
  }

  void _reportCleanupSettled(_ActiveRun run) {
    if (run.cleanupReported) return;
    run.cleanupReported = true;
    for (final callback in run.onCleanupSettled) {
      try {
        callback();
      } catch (_) {
        // Cleanup ownership is already settled. A bookkeeping callback must
        // not turn successful transport teardown into an uncaught failure.
      }
    }
  }
}

/// Observes provider-controlled teardown without letting it block registry
/// ownership changes or escape as an uncaught zone error.
///
/// A subscription/remote cleanup error and its stack can contain reflected
/// credentials, so diagnostics deliberately identify only the cleanup site.
void _observeHermesRegistryCleanup(
  Future<void> Function() cleanup, {
  required String message,
}) {
  void logFailure() {
    DebugLogger.error(message, scope: 'hermes/registry');
  }

  try {
    unawaited(
      cleanup().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) => logFailure(),
      ),
    );
  } catch (_) {
    logFailure();
  }
}

class _ActiveRun {
  _ActiveRun({
    required this.cancelToken,
    required this.onCancelled,
    required this.onCleanupSettled,
    this.cancellationSettled,
  });

  String? runId;
  final CancelToken cancelToken;
  final List<void Function()> onCancelled;
  final List<void Function()> onCleanupSettled;
  Future<void>? cancellationSettled;
  StreamSubscription<void>? subscription;
  Future<void> Function(String runId)? stopRemote;
  bool cancelled = false;
  bool cleanupReported = false;
}

final hermesRunRegistryProvider = Provider<HermesRunRegistry>(
  (ref) => HermesRunRegistry(),
);
