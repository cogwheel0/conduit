import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';

import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/prompt.dart';

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

import 'package:conduit_core/providers/app_providers.dart'
    show
        activeConversationProvider,
        activeServerProvider,
        incompleteLogoutFenceProvider,
        reviewerModeProvider,
        selectedModelProvider;

import 'package:conduit_core/providers/backend_mode_providers.dart';

import 'package:conduit_core/providers/storage_providers.dart';

import 'package:conduit_core/services/secure_credential_storage.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';

import 'package:conduit_core/providers/host_ports.dart';

import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';

final class _HermesCredentialRollbackFailure implements Exception {
  const _HermesCredentialRollbackFailure({
    required this.writeError,
    required this.writeStackTrace,
  });

  final Object writeError;
  final StackTrace writeStackTrace;
}

final class _HermesCredentialSnapshot {
  const _HermesCredentialSnapshot({this.apiKey, this.sessionKey, this.desktop});

  factory _HermesCredentialSnapshot.fromConfig(HermesConfig config) =>
      _HermesCredentialSnapshot(
        apiKey: config.apiKey,
        sessionKey: config.sessionKey,
        desktop: config.desktopCredentials,
      );

  final String? apiKey;
  final String? sessionKey;
  final HermesDesktopCredentials? desktop;
}

final class _HermesCredentialWrites {
  const _HermesCredentialWrites({
    required this.apiKey,
    required this.sessionKey,
    required this.desktop,
  });

  final bool apiKey;
  final bool sessionKey;
  final bool desktop;

  bool get any => apiKey || sessionKey || desktop;
}

/// Which saved connection a connection edit targets.
final class _HermesConnectionTarget {
  const _HermesConnectionTarget._({
    required this.id,
    required this.isNew,
    required this.runtime,
  });

  /// A connection that does not exist yet. [activate] makes it the active
  /// connection as part of the same commit.
  factory _HermesConnectionTarget.create({required bool activate}) =>
      _HermesConnectionTarget._(
        id: HermesConnectionProfile.newId(),
        isNew: true,
        runtime: activate,
      );

  factory _HermesConnectionTarget.existing(String id, {required bool active}) =>
      _HermesConnectionTarget._(id: id, isNew: false, runtime: active);

  final String id;
  final bool isNew;

  /// Whether the runtime (state, transport, runs) follows this connection.
  final bool runtime;
}

/// Owns the Hermes config: non-secret fields from shared preferences, secrets
/// from secure storage. Exposes setters that persist and update state.
///
/// Several named connections can be saved; the state always describes the
/// active one, so downstream providers keep reading a single [HermesConfig].
/// Inactive connections are created and edited through the same serialized
/// mutation lane without touching the runtime.
class HermesConfigController extends Notifier<HermesConfig> {
  String? _runtimeDocumentTrustPrincipalId;

  /// Saved connections. Mirrors the durable document, or the in-memory
  /// migration of the single-connection settings until that is written.
  List<HermesConnectionProfile> _profiles = const [];
  String? _legacySecretsOwner;
  HermesConnectionProfile? _pendingLegacyMigration;
  Future<void>? _legacySecretMigration;

  Future<void> _mutationQueue = Future<void>.value();
  Future<void>? _secretsHydration;
  _HermesSessionKeyRequest? _sessionKeyRequest;
  bool _runAdmissionBlocked = false;
  bool _appDataClearBlocked = false;
  bool _durableLogoutFenceBlocked = false;
  HermesConfig? _configBeforeAppDataClear;
  int _connectionMutationEpoch = 0;

  /// Counts the live Desktop clients built; the newest is the live one.
  int _liveClientGeneration = 0;
  int _secretLoadEpoch = 0;

  bool get _mutationsBlocked =>
      _appDataClearBlocked || _durableLogoutFenceBlocked;

  /// Saved connections, in the order they were added.
  List<HermesConnectionProfile> get connections => _profiles;

  HermesConnectionProfile? _profile(String? id) =>
      id == null ? null : _profiles.firstWhereOrNull((p) => p.id == id);

  HermesConnectionProfile? get _activeProfile => _profile(state.connectionId);

  @override
  HermesConfig build() {
    final epoch = ++_secretLoadEpoch;
    _durableLogoutFenceBlocked = ref.watch(incompleteLogoutFenceProvider);
    if (_durableLogoutFenceBlocked) {
      _runAdmissionBlocked = true;
      _profiles = const [];
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
    final active = _restoreProfiles();
    // Secrets load asynchronously and patch the state in once available.
    final hydration = _loadSecrets(epoch, active?.id);
    _secretsHydration = hydration;
    unawaited(hydration);
    return active == null
        ? HermesConfig(enabled: enabled)
        : _configForProfile(active, enabled: enabled);
  }

  /// Loads the saved connections and returns the active one.
  ///
  /// When only the single-connection settings of an older install exist, they
  /// become the first saved connection in memory. [_loadSecrets] makes that
  /// durable before reading or copying any secret.
  HermesConnectionProfile? _restoreProfiles() {
    final document = HermesConnectionStore.readDocument();
    if (document != null) {
      _pendingLegacyMigration = null;
      _profiles = document.connections;
      _legacySecretsOwner = document.legacySecretsOwner;
      return _profile(HermesConnectionStore.readActiveId());
    }
    if (!HermesConnectionStore.hasLegacyConfiguration()) {
      _pendingLegacyMigration = null;
      _legacySecretsOwner = null;
      _profiles = const [];
      return null;
    }
    // Reuse one in-memory profile across rebuilds so a retried write cannot
    // mint a second id for the same connection.
    final migrated = _pendingLegacyMigration ??=
        HermesConnectionStore.legacyProfile(now: DateTime.now().toUtc());
    _profiles = List.unmodifiable([migrated]);
    _legacySecretsOwner = migrated.id;
    return migrated;
  }

  HermesConfig _configForProfile(
    HermesConnectionProfile profile, {
    required bool enabled,
    _HermesCredentialSnapshot secrets = const _HermesCredentialSnapshot(),
  }) => HermesConfig(
    enabled: enabled,
    connectionId: profile.id,
    name: profile.name,
    baseUrl: profile.baseUrl,
    mode: profile.mode,
    desktopAuthKind: profile.desktopAuthKind,
    desktopProfile: profile.desktopProfile,
    allowSelfSignedCertificates: profile.allowSelfSignedCertificates,
    apiKey: secrets.apiKey,
    sessionKey: secrets.sessionKey,
    desktopCredentials: secrets.desktop,
  );

  SecureCredentialStorage get _secure =>
      SecureCredentialStorage(instance: ref.read(secureStorageProvider));

  Future<void> _loadSecrets(int epoch, String? connectionId) async {
    try {
      await _persistLegacyMigration();
      await _migrateLegacySecrets();
      final secrets = connectionId == null
          ? const _HermesCredentialSnapshot()
          : await _readSecrets(connectionId);
      if (epoch != _secretLoadEpoch ||
          _mutationsBlocked ||
          !ref.mounted ||
          state.connectionId != connectionId) {
        return;
      }
      ref.read(hermesSecretsErrorProvider.notifier).clear();
      final desktopCredentials = secrets.desktop;
      final previousNative = state.desktopCredentials?.nativeTokens;
      final nextNative = desktopCredentials?.nativeTokens;
      final transportCredentialsChanged =
          state.apiKey != secrets.apiKey ||
          state.sessionKey != secrets.sessionKey ||
          state.desktopCredentials?.legacyToken !=
              desktopCredentials?.legacyToken ||
          previousNative?.accessToken != nextNative?.accessToken ||
          previousNative?.refreshToken != nextNative?.refreshToken ||
          previousNative?.expiresAt != nextNative?.expiresAt ||
          !const MapEquality<Object?, Object?>().equals(
            state.accessHeaders,
            desktopCredentials?.accessHeaders,
          );
      state = state.copyWith(
        apiKey: secrets.apiKey,
        sessionKey: secrets.sessionKey,
        desktopCredentials: desktopCredentials,
      );
      if (transportCredentialsChanged) {
        ref.read(hermesConnectionGenerationProvider.notifier).bump();
      }
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

  Future<_HermesCredentialSnapshot> _readSecrets(String connectionId) async {
    final apiKey = await _secure.getHermesApiKey(connectionId);
    final sessionKey = await _secure.getHermesSessionKey(connectionId);
    final desktopPayload = await _secure.getHermesDesktopCredentials(
      connectionId,
    );
    HermesDesktopCredentials? desktopCredentials;
    if (desktopPayload != null) {
      try {
        desktopCredentials = HermesDesktopCredentials.fromJson(
          jsonDecode(desktopPayload),
        );
      } on FormatException {
        DebugLogger.warning(
          'desktop-credentials-decode-failed',
          scope: 'hermes/config',
        );
      }
    }
    return _HermesCredentialSnapshot(
      apiKey: apiKey,
      sessionKey: sessionKey,
      desktop: desktopCredentials,
    );
  }

  /// Writes the in-memory migration of an older single-connection install.
  ///
  /// The active id lands first: if the process dies before the document is
  /// written, the next launch migrates again and overwrites it. The legacy
  /// preferences are removed only once the document is durable.
  Future<void> _persistLegacyMigration() async {
    final migrated = _pendingLegacyMigration;
    if (migrated == null) {
      if (HermesConnectionStore.hasLegacyKeys() &&
          HermesConnectionStore.readDocument() != null) {
        _throwIfMigrationBlocked();
        await _deleteLegacyPreferences();
      }
      return;
    }
    _throwIfMigrationBlocked();
    await HermesConnectionStore.writeActiveId(migrated.id);
    _throwIfMigrationBlocked();
    await HermesConnectionStore.writeDocument(
      HermesConnectionsDocument(
        connections: [migrated],
        legacySecretsOwner: migrated.id,
      ),
    );
    if (identical(_pendingLegacyMigration, migrated)) {
      _pendingLegacyMigration = null;
    }
    DebugLogger.log('legacy-connection-migrated', scope: 'hermes/connections');
    _throwIfMigrationBlocked();
    await _deleteLegacyPreferences();
  }

  /// The legacy migration writes outside the mutation queue, so an app-data
  /// wipe cannot drain it; it stops at its next write instead, leaving the
  /// legacy values for the wipe or a later retry.
  void _throwIfMigrationBlocked() {
    if (_mutationsBlocked) {
      throw StateError('Hermes changes are unavailable while signing out.');
    }
  }

  Future<void> _deleteLegacyPreferences() async {
    try {
      await HermesConnectionStore.deleteLegacyKeys();
    } catch (error) {
      // The saved-connection document is authoritative once it exists; the
      // next load retries this cleanup.
      DebugLogger.warning(
        'legacy-preference-cleanup-failed',
        scope: 'hermes/connections',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _migrateLegacySecrets() {
    final owner = _legacySecretsOwner;
    if (owner == null) return Future<void>.value();
    final pending = _legacySecretMigration;
    if (pending != null) return pending;
    late final Future<void> migration;
    migration = _runLegacySecretMigration(owner).whenComplete(() {
      if (identical(_legacySecretMigration, migration)) {
        _legacySecretMigration = null;
      }
    });
    _legacySecretMigration = migration;
    return migration;
  }

  /// Moves the unscoped secrets of an older install to [owner]'s keys.
  ///
  /// Each secret is written, read back, and only then deleted from its legacy
  /// key. Any failure throws with the legacy key intact, so the next load
  /// retries; the secrets error keeps every mutation blocked meanwhile, which
  /// is what makes repeating the copy safe.
  Future<void> _runLegacySecretMigration(String owner) async {
    final ownerExists = _profile(owner) != null;
    for (final kind in HermesSecretKind.values) {
      final legacy = await _secure.readLegacyHermesSecret(kind);
      if (legacy == null) continue;
      if (ownerExists) {
        _throwIfMigrationBlocked();
        await _secure.writeHermesSecret(kind, owner, legacy);
        final copied = await _secure.readHermesSecret(kind, owner);
        if (copied != legacy) {
          throw StateError('Hermes credentials could not be migrated.');
        }
      }
      _throwIfMigrationBlocked();
      await _secure.deleteLegacyHermesSecret(kind);
    }
    if (_legacySecretsOwner != owner) return;
    _throwIfMigrationBlocked();
    _legacySecretsOwner = null;
    try {
      await _writeProfiles(_profiles);
      DebugLogger.log('legacy-secrets-migrated', scope: 'hermes/connections');
    } catch (error) {
      // Harmless to keep: the next load finds no legacy secret and retries.
      _legacySecretsOwner = owner;
      DebugLogger.warning(
        'legacy-secret-marker-clear-failed',
        scope: 'hermes/connections',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<void> retrySecrets() {
    final epoch = ++_secretLoadEpoch;
    ref.read(hermesSecretsErrorProvider.notifier).clear();
    ref.read(hermesSecretsLoadingProvider.notifier).set(true);
    final hydration = _loadSecrets(epoch, state.connectionId);
    _secretsHydration = hydration;
    return hydration;
  }

  /// Waits until the current secure-storage read has settled and surfaces any
  /// hydration failure before callers snapshot credential-bearing state.
  Future<void> waitForSecretsHydration() async {
    await _secretsHydration;
    _throwIfSecretsUnavailable();
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

  /// Binds native credential writes to the current connection lifetime. Capture
  /// before sign-in or refresh starts; later connection edits or sign-out revoke
  /// the writer, while token rotations leave it valid.
  HermesDesktopCredentialsWriter nativeCredentialsWriter() {
    final epoch = _connectionMutationEpoch;
    final connection = state;
    return (credentials) =>
        _setDesktopNativeTokens(credentials.nativeTokens, epoch, connection);
  }

  Future<void> _setDesktopNativeTokens(
    HermesDesktopTokenSet? tokens,
    int epoch,
    HermesConfig connection,
  ) {
    return _serializeMutation(() async {
      await _secretsHydration;
      _throwIfSecretsUnavailable();
      final connectionId = state.connectionId;
      if (epoch != _connectionMutationEpoch ||
          connectionId == null ||
          connectionId != connection.connectionId ||
          !hermesDesktopConnectionMatches(state, connection) ||
          state.mode != connection.mode ||
          state.allowSelfSignedCertificates !=
              connection.allowSelfSignedCertificates) {
        throw StateError('Hermes connection changed before sign-in completed.');
      }
      final previous = state.desktopCredentials;
      final next = HermesDesktopCredentials(
        legacyToken: previous?.legacyToken,
        nativeTokens: tokens,
        accessHeaders: previous?.accessHeaders ?? const {},
      );
      await _persistDesktopCredentials(connectionId, next);
      state = _withState(desktopCredentials: next);
    });
  }

  /// Persists token rotations of a temporary client built from [connection]
  /// whichever saved connection is active. Probing or listing profiles of a
  /// Desktop connection can refresh its tokens; dropping the rotation would
  /// strand the stored refresh token. Whether the connection is active is
  /// judged when a rotation lands, not when the client was built, so a switch
  /// or turning Hermes off while a refresh is in flight keeps the tokens the
  /// server already issued. The write is rejected once [connection]'s
  /// endpoint, auth, or credentials change.
  ///
  /// [live] marks the writer of a live client being built. Any other writer
  /// that replaces the active connection's tokens, including that of a live
  /// client since replaced, rebuilds the live client, which would otherwise
  /// go on with the replaced ones, once no reply is streaming through it.
  HermesDesktopCredentialsWriter credentialsWriterFor(
    HermesConfig connection, {
    bool live = false,
  }) {
    final generation = live ? ++_liveClientGeneration : null;
    final connectionId = connection.connectionId;
    // The refresh token this writer's client holds. Two clients built from
    // the same stored tokens can race: once one rotates them, the other's
    // stale refresh (or its sign-out after a 401) must not overwrite them.
    var expectedRefreshToken =
        connection.desktopCredentials?.nativeTokens?.refreshToken;
    return (credentials) => _serializeMutation(() async {
      await _secretsHydration;
      _throwIfSecretsUnavailable();
      final profile = _profile(connectionId);
      if (connectionId == null || profile == null) {
        throw StateError('Hermes connection changed before sign-in completed.');
      }
      final active = connectionId == state.connectionId;
      final stored = active
          ? state
          : _configForProfile(
              profile,
              enabled: true,
              secrets: await _readSecrets(connectionId),
            );
      if (!hermesDesktopConnectionMatches(stored, connection) ||
          stored.mode != connection.mode ||
          stored.allowSelfSignedCertificates !=
              connection.allowSelfSignedCertificates ||
          stored.desktopCredentials?.nativeTokens?.refreshToken !=
              expectedRefreshToken) {
        throw StateError('Hermes connection changed before sign-in completed.');
      }
      final previous = stored.desktopCredentials;
      final next = HermesDesktopCredentials(
        legacyToken: previous?.legacyToken,
        nativeTokens: credentials.nativeTokens,
        accessHeaders: previous?.accessHeaders ?? const {},
      );
      await _persistDesktopCredentials(connectionId, next);
      if (active) {
        state = _withState(desktopCredentials: next);
        if (generation != _liveClientGeneration) _rebuildLiveClientWhenIdle();
      }
      expectedRefreshToken = credentials.nativeTokens?.refreshToken;
    });
  }

  /// Rebuilds the live client so it takes the stored tokens, but only once
  /// no reply is streaming: closing it mid-reply would freeze that reply.
  void _rebuildLiveClientWhenIdle() {
    final generation = _liveClientGeneration;
    ref.read(hermesRunRegistryProvider).whenIdle(() {
      // Outside the caller's frame, and skipped when a client built since
      // already took the stored tokens. Through the container: the live
      // client watches this notifier.
      scheduleMicrotask(() {
        if (!ref.mounted || generation != _liveClientGeneration) return;
        ref.container.invalidate(hermesApiServiceProvider);
      });
    });
  }

  Future<void> signOutDesktop() => _serializeMutation(() async {
    await _secretsHydration;
    _throwIfSecretsUnavailable();
    final connectionId = state.connectionId;
    if (connectionId == null) return;
    await _withRunAdmissionBlocked(() async {
      await _cancelActiveRuns();
      // An explicit sign-out clears the origin's dashboard cookies even when
      // another saved connection shares the origin: the WebView cookie store
      // is process-global, so that connection was using the same session.
      final cleared = await ref
          .read(cookieJarProvider)
          .clearForOrigin(state.baseUrl);
      if (!cleared) {
        throw StateError('Hermes dashboard cookies could not be cleared.');
      }
      await _persistDesktopCredentials(connectionId, null);
      state = _withState(desktopCredentials: null);
      _releaseRuntimeSession();
      ref.read(hermesConnectionGenerationProvider.notifier).bump();
    });
  });

  /// Atomically commits connection edits. Secrets are retained only when the
  /// normalized origin (scheme + host + port) is unchanged.
  ///
  /// [connectionId] defaults to the connection active when this is called.
  /// Without one the edits create a saved connection, activated unless
  /// another became active first. Editing an inactive connection never
  /// touches the runtime. Returns the id of the saved connection.
  ///
  /// A null [name] keeps the saved name; an empty one derives it from the URL.
  Future<String> saveConnection({
    String? connectionId,
    required String baseUrl,
    String? name,
    HermesConnectionNameSource? nameSource,
    HermesBackendMode? mode,
    HermesDesktopAuthKind? desktopAuthKind,
    String? desktopProfile,
    bool? allowSelfSignedCertificates,
    bool apiKeyChanged = false,
    String? apiKey,
    bool sessionKeyChanged = false,
    String? sessionKey,
    bool desktopCredentialsChanged = false,
    HermesDesktopCredentials? desktopCredentials,
  }) {
    final trimmedUrl = baseUrl.trim();
    final nextOrigin = connectionOrigin(trimmedUrl);
    if ((trimmedUrl.isNotEmpty && nextOrigin == null) ||
        trimmedUrl.length > kMaxHermesBaseUrlCharacters) {
      return Future<String>.error(
        ArgumentError.value(baseUrl, 'baseUrl', 'Use a valid http(s) URL'),
      );
    }
    // Chosen now, not when the queue reaches this save: a connection that an
    // earlier queued save creates and activates meanwhile must not turn this
    // new connection into an edit of that one.
    final targetId = connectionId ?? state.connectionId;
    String? saved;
    return _serializeMutation(() async {
      // Resolve the one cold-start read before applying edits. This prevents a
      // same-origin save from accidentally replacing not-yet-hydrated secrets
      // with null, while the serialized queue prevents write reordering.
      await _secretsHydration;
      _throwIfSecretsUnavailable();
      if (targetId != null && _profile(targetId) == null) {
        throw StateError('This Hermes connection no longer exists.');
      }
      if (targetId == null && _profiles.length >= kMaxHermesConnections) {
        throw StateError('Too many saved Hermes connections.');
      }
      saved = await _commitConnection(
        targetId == null
            ? _HermesConnectionTarget.create(
                activate: state.connectionId == null,
              )
            : _HermesConnectionTarget.existing(
                targetId,
                active: targetId == state.connectionId,
              ),
        trimmedUrl: trimmedUrl,
        nextOrigin: nextOrigin,
        name: name,
        nameSource: nameSource,
        mode: mode,
        desktopAuthKind: desktopAuthKind,
        desktopProfile: desktopProfile,
        allowSelfSignedCertificates: allowSelfSignedCertificates,
        apiKeyChanged: apiKeyChanged,
        apiKey: apiKey,
        sessionKeyChanged: sessionKeyChanged,
        sessionKey: sessionKey,
        desktopCredentialsChanged: desktopCredentialsChanged,
        desktopCredentials: desktopCredentials,
      );
    }).then((_) => saved!);
  }

  /// Saves a new connection without activating it, and returns its id. Use
  /// [saveConnection] to create the first connection, which it activates.
  Future<String> createConnection({
    required String baseUrl,
    String? name,
    HermesConnectionNameSource? nameSource,
    HermesBackendMode? mode,
    HermesDesktopAuthKind? desktopAuthKind,
    String? desktopProfile,
    bool? allowSelfSignedCertificates,
    String? apiKey,
    String? sessionKey,
    HermesDesktopCredentials? desktopCredentials,
  }) async {
    final trimmedUrl = baseUrl.trim();
    final nextOrigin = connectionOrigin(trimmedUrl);
    if (nextOrigin == null || trimmedUrl.length > kMaxHermesBaseUrlCharacters) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Use a valid http(s) URL');
    }
    String? created;
    await _serializeMutation(() async {
      await _secretsHydration;
      _throwIfSecretsUnavailable();
      if (_profiles.length >= kMaxHermesConnections) {
        throw StateError('Too many saved Hermes connections.');
      }
      created = await _commitConnection(
        _HermesConnectionTarget.create(activate: false),
        trimmedUrl: trimmedUrl,
        nextOrigin: nextOrigin,
        name: name ?? '',
        nameSource: nameSource,
        mode: mode,
        desktopAuthKind: desktopAuthKind,
        desktopProfile: desktopProfile,
        allowSelfSignedCertificates: allowSelfSignedCertificates,
        apiKeyChanged: true,
        apiKey: apiKey,
        sessionKeyChanged: true,
        sessionKey: sessionKey,
        desktopCredentialsChanged: true,
        desktopCredentials: desktopCredentials,
      );
    });
    return created!;
  }

  Future<String> _commitConnection(
    _HermesConnectionTarget target, {
    required String trimmedUrl,
    required String? nextOrigin,
    required String? name,
    required HermesConnectionNameSource? nameSource,
    required HermesBackendMode? mode,
    required HermesDesktopAuthKind? desktopAuthKind,
    required String? desktopProfile,
    required bool? allowSelfSignedCertificates,
    required bool apiKeyChanged,
    required String? apiKey,
    required bool sessionKeyChanged,
    required String? sessionKey,
    required bool desktopCredentialsChanged,
    required HermesDesktopCredentials? desktopCredentials,
  }) async {
    final connectionId = target.id;
    final previousProfile = target.isNew ? null : _profile(connectionId);
    // The baseline the edits apply to: the live state for the active
    // connection, the stored profile and secrets for an inactive one, and an
    // empty connection for a new one.
    final HermesConfig previous;
    if (previousProfile == null) {
      previous = HermesConfig(enabled: state.enabled);
    } else if (target.runtime) {
      previous = state;
    } else {
      previous = _configForProfile(
        previousProfile,
        enabled: state.enabled,
        secrets: await _readSecrets(connectionId),
      );
    }
    final nextDesktopCredentials = desktopCredentialsChanged
        ? desktopCredentials
        : previous.desktopCredentials;
    final headerError = HermesConfig.validateAccessHeaders(
      nextDesktopCredentials?.accessHeaders ?? const {},
    );
    if (headerError != null) throw ArgumentError(headerError);
    final previousBaseUrl = previous.baseUrl;
    final originChanged = connectionOrigin(previousBaseUrl) != nextOrigin;
    final endpointChanged =
        connectionEndpoint(previousBaseUrl) != connectionEndpoint(trimmedUrl);
    final nextMode = mode ?? previous.mode;
    final nextDesktopAuthKind = desktopAuthKind ?? previous.desktopAuthKind;
    final nextDesktopProfile = desktopProfile?.trim().isNotEmpty == true
        ? desktopProfile!.trim()
        : previous.desktopProfile;
    if (!HermesConfig.isValidDesktopProfile(nextDesktopProfile)) {
      throw ArgumentError.value(
        desktopProfile,
        'desktopProfile',
        'Use a valid Hermes profile ID',
      );
    }
    final nextAllowSelfSigned =
        allowSelfSignedCertificates ?? previous.allowSelfSignedCertificates;
    final modeChanged = nextMode != previous.mode;
    final authKindChanged = nextDesktopAuthKind != previous.desktopAuthKind;
    final profileChanged = nextDesktopProfile != previous.desktopProfile;
    final identityChanged =
        apiKeyChanged ||
        sessionKeyChanged ||
        desktopCredentialsChanged ||
        modeChanged ||
        authKindChanged ||
        profileChanged;
    // A trust change rebuilds the transport without touching credentials, so
    // it is not an identity change, but active runs still hold the old
    // client and must be cancelled before the service rotates.
    final trustChanged =
        nextAllowSelfSigned != previous.allowSelfSignedCertificates;
    final serviceWillRotate =
        target.runtime &&
        (previous.baseUrl != trimmedUrl || identityChanged || trustChanged);
    final previousCredentials = _HermesCredentialSnapshot.fromConfig(previous);
    var nextApiKey = previousCredentials.apiKey;
    var nextSessionKey = previousCredentials.sessionKey;
    var committedDesktopCredentials = nextDesktopCredentials;

    if (originChanged) {
      nextApiKey = null;
      nextSessionKey = null;
      if (!desktopCredentialsChanged) committedDesktopCredentials = null;
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
    final writeDesktopCredentials = originChanged || desktopCredentialsChanged;
    final credentialWrites = _HermesCredentialWrites(
      apiKey: writeApiKey,
      sessionKey: writeSessionKey,
      desktop: writeDesktopCredentials,
    );
    final nextCredentials = _HermesCredentialSnapshot(
      apiKey: nextApiKey,
      sessionKey: nextSessionKey,
      desktop: committedDesktopCredentials,
    );

    // Endpoint and identity changes rotate this connection's trust principal
    // so earlier session bindings and document trust stop matching.
    final nextPrincipal =
        previousProfile == null || endpointChanged || identityChanged
        ? const Uuid().v4()
        : previousProfile.documentTrustPrincipalId;
    final chosenName = HermesConnectionProfile.sanitizeName(name);
    final String nextName;
    final HermesConnectionNameSource nextNameSource;
    if (chosenName != null) {
      nextName = chosenName;
      nextNameSource = nameSource ?? HermesConnectionNameSource.user;
    } else if (name == null && previousProfile != null) {
      nextName = previousProfile.name;
      nextNameSource = previousProfile.nameSource;
    } else {
      nextName = HermesConnectionProfile.deriveName(trimmedUrl);
      nextNameSource = HermesConnectionNameSource.derived;
    }
    final nextProfile = HermesConnectionProfile(
      id: connectionId,
      name: nextName,
      nameSource: nextNameSource,
      baseUrl: trimmedUrl,
      mode: nextMode,
      desktopAuthKind: nextDesktopAuthKind,
      desktopProfile: nextDesktopProfile,
      allowSelfSignedCertificates: nextAllowSelfSigned,
      documentTrustPrincipalId: nextPrincipal,
      lastUsedAt: target.runtime
          ? DateTime.now().toUtc()
          : previousProfile?.lastUsedAt,
    );

    Future<void> restorePreviousProfile() async {
      if (previousProfile != null) {
        await _writeProfiles(_replacing(previousProfile));
      } else {
        await _writeProfiles([
          for (final profile in _profiles)
            if (profile.id != connectionId) profile,
        ]);
        if (target.runtime) await HermesConnectionStore.writeActiveId(null);
      }
    }

    Future<void> quarantine() => _quarantineUncertainCredentialMutation(
      connectionId: connectionId,
      clearApiKey: writeApiKey,
      clearSessionKey: writeSessionKey,
      clearDesktopCredentials: writeDesktopCredentials,
    );

    Future<void> commitConnectionMutation() async {
      // Secure storage and SharedPreferences cannot participate in one
      // transaction. Remove the endpoint before changing credential identity
      // so a process kill between secret writes can restart only into a
      // disabled connection, never a live endpoint with mixed credentials.
      final endpointPreQuarantined =
          previousProfile != null && (originChanged || identityChanged);
      if (endpointPreQuarantined) {
        await _writeProfiles(_replacing(previousProfile.copyWith(baseUrl: '')));
      }

      try {
        await _persistSecretsAtomically(
          connectionId: connectionId,
          previous: previousCredentials,
          next: nextCredentials,
          writes: credentialWrites,
        );
      } on _HermesCredentialRollbackFailure catch (failure) {
        // A partially committed secret mutation with a failed rollback must
        // never remain paired with the previous durable endpoint. Quarantine
        // the endpoint (or, if preferences are unavailable, every touched
        // secret) and revoke the in-memory service before surfacing the
        // original secure-storage error.
        await quarantine();
        Error.throwWithStackTrace(failure.writeError, failure.writeStackTrace);
      } catch (error, stackTrace) {
        // Ordinary write failures reached here only after exact credential
        // rollback. Restore the endpoint removed for the crash-safe window;
        // if that durable recovery is uncertain, quarantine the connection.
        if (endpointPreQuarantined) {
          try {
            await _writeProfiles(_replacing(previousProfile));
          } catch (recoveryError) {
            DebugLogger.error(
              'endpoint-recovery-after-credential-write-failed',
              scope: 'hermes/config',
              data: {'errorType': recoveryError.runtimeType.toString()},
            );
            await quarantine();
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }

      try {
        // A new active connection is pointed at before its profile exists:
        // the active id alone selects nothing, so a failure between the two
        // writes still restarts without a connection.
        if (target.isNew && target.runtime) {
          await HermesConnectionStore.writeActiveId(connectionId);
        }
        await _writeProfiles(_replacing(nextProfile));
      } catch (error, stackTrace) {
        // The profile document and its secure credentials live in separate
        // stores. If the profile cannot be made durable, restore the old keys
        // before restoring the old profile so a restart cannot send
        // replacement-origin credentials to the previous server.
        var previousCredentialsRestored = false;
        try {
          await _persistSecretsAtomically(
            connectionId: connectionId,
            previous: nextCredentials,
            next: previousCredentials,
            writes: credentialWrites,
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
            if (writeApiKey) await _persistApiKey(connectionId, null);
            if (writeSessionKey) await _persistSessionKey(connectionId, null);
            if (writeDesktopCredentials) {
              await _persistDesktopCredentials(connectionId, null);
            }
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
            await restorePreviousProfile();
          } catch (rollbackError) {
            DebugLogger.error(
              'endpoint-recovery-write-failed',
              scope: 'hermes/config',
              data: {'errorType': rollbackError.runtimeType.toString()},
            );
            await quarantine();
          }
        } else {
          await quarantine();
        }
        Error.throwWithStackTrace(error, stackTrace);
      }

      if (originChanged &&
          previousBaseUrl.trim().isNotEmpty &&
          !_originSharedByAnotherConnection(previousBaseUrl, connectionId)) {
        final cleared = await ref
            .read(cookieJarProvider)
            .clearForOrigin(previousBaseUrl);
        if (!cleared) {
          try {
            // As on the way in, the endpoint goes before the credentials
            // change, so neither a restart nor a concurrent read pairs the
            // replacement server with the restored credentials.
            await _writeProfiles(
              _replacing(nextProfile.copyWith(baseUrl: '')),
            );
            await _persistSecretsAtomically(
              connectionId: connectionId,
              previous: nextCredentials,
              next: previousCredentials,
              writes: credentialWrites,
            );
            await restorePreviousProfile();
          } catch (rollbackError) {
            DebugLogger.error(
              'cookie-cleanup-rollback-failed',
              scope: 'hermes/config',
              data: {'errorType': rollbackError.runtimeType.toString()},
            );
            await quarantine();
          }
          throw StateError('Hermes dashboard cookies could not be cleared.');
        }
      }

      if (target.runtime) {
        if (endpointChanged || identityChanged) {
          // Endpoint and secret changes can switch servers, accounts, or
          // memory principals. Never carry the old server-side session across
          // them.
          _releaseRuntimeSession();
        }
        state = _configForProfile(
          nextProfile,
          enabled: state.enabled,
          secrets: nextCredentials,
        );
        if (identityChanged) {
          ref.read(hermesConnectionGenerationProvider.notifier).bump();
        }
      }
      if ((endpointChanged || identityChanged) &&
          previousBaseUrl.trim().isNotEmpty) {
        final previousOrigin = connectionOrigin(previousBaseUrl);
        if (previousOrigin != null) {
          try {
            // Records from before saved connections match by origin alone,
            // so a connection still on the old origin keeps answering them.
            await HermesPendingDecisionStore.clearConnection(
              connectionId: connectionId,
              origin:
                  _originSharedByAnotherConnection(
                    previousBaseUrl,
                    connectionId,
                  )
                  ? null
                  : previousOrigin,
            );
          } catch (error) {
            DebugLogger.error(
              'pending-decision-cleanup-failed',
              scope: 'hermes/config',
              data: {'errorType': error.runtimeType.toString()},
            );
          }
        }
      }
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
    return connectionId;
  }

  /// Makes [connectionId] the active connection.
  ///
  /// Its secrets are read before anything changes, so a keychain failure
  /// leaves the current connection intact. Live runs of the previous
  /// connection are cancelled and its session is released.
  Future<void> setActiveConnection(String connectionId) =>
      _serializeMutation(() async {
        await _secretsHydration;
        _throwIfSecretsUnavailable();
        final target = _profile(connectionId);
        if (target == null) {
          throw StateError('This Hermes connection no longer exists.');
        }
        if (state.connectionId == connectionId) return;
        final secrets = await _readSecrets(connectionId);
        await _withRunAdmissionBlocked(() async {
          await _cancelActiveRuns();
          await HermesConnectionStore.writeActiveId(connectionId);
          final used = target.copyWith(lastUsedAt: DateTime.now().toUtc());
          try {
            await _writeProfiles(_replacing(used));
          } catch (error) {
            // Recency only orders the fallback after a delete; the switch
            // itself is already durable.
            DebugLogger.warning(
              'last-used-write-failed',
              scope: 'hermes/connections',
              data: {'errorType': error.runtimeType.toString()},
            );
          }
          _activateRuntime(_profile(connectionId) ?? used, secrets);
          DebugLogger.log('connection-switched', scope: 'hermes/connections');
        });
      });

  /// Deletes a saved connection with its secrets and local trust records.
  ///
  /// Deleting the active connection activates the most recently used
  /// remaining one, or leaves Hermes without a connection.
  Future<void> deleteConnection(String connectionId) =>
      _serializeMutation(() async {
        await _secretsHydration;
        _throwIfSecretsUnavailable();
        final target = _profile(connectionId);
        if (target == null) return;
        final remaining = [
          for (final profile in _profiles)
            if (profile.id != connectionId) profile,
        ];
        final wasActive = state.connectionId == connectionId;

        Future<void> commit() async {
          // Reads that can fail come first, so such a failure changes
          // nothing.
          HermesConnectionProfile? replacement;
          var replacementSecrets = const _HermesCredentialSnapshot();
          if (wasActive) {
            replacement = _mostRecentlyUsed(remaining);
            if (replacement != null) {
              replacementSecrets = await _readSecrets(replacement.id);
            }
          }
          final kept = _profiles;
          // The connection survives, so keep it the active one as well.
          Future<void> keepActive() async {
            if (!wasActive) return;
            try {
              await HermesConnectionStore.writeActiveId(connectionId);
            } catch (error) {
              DebugLogger.warning(
                'active-connection-restore-failed',
                scope: 'hermes/connections',
                data: {'errorType': error.runtimeType.toString()},
              );
            }
          }

          if (wasActive) {
            // Repoint the runtime first: an active id must never name a
            // profile that is gone, and if the document write below fails the
            // deleted connection is simply no longer active.
            await HermesConnectionStore.writeActiveId(replacement?.id);
          }
          try {
            await _writeProfiles(remaining);
          } catch (_) {
            await keepActive();
            rethrow;
          }
          // Cleared once the connection is gone from the list, so a write that
          // fails above leaves it signed in to its dashboard. A clear that
          // fails puts the connection back, still signed in, rather than
          // report a deletion that left its dashboard session behind. A
          // connection sharing the origin still uses that session.
          if (connectionOrigin(target.baseUrl) != null &&
              !_originSharedByAnotherConnection(target.baseUrl, connectionId)) {
            Object? clearError;
            StackTrace? clearStackTrace;
            var cleared = false;
            try {
              cleared = await ref
                  .read(cookieJarProvider)
                  .clearForOrigin(target.baseUrl);
            } catch (error, stackTrace) {
              clearError = error;
              clearStackTrace = stackTrace;
            }
            if (!cleared) {
              try {
                await _writeProfiles(kept);
              } catch (error) {
                DebugLogger.warning(
                  'deleted-connection-restore-failed',
                  scope: 'hermes/connections',
                  data: {'errorType': error.runtimeType.toString()},
                );
              }
              await keepActive();
              if (clearError != null) {
                Error.throwWithStackTrace(clearError, clearStackTrace!);
              }
              throw StateError('Hermes dashboard cookies could not be cleared.');
            }
          }
          if (wasActive) {
            if (replacement == null) {
              state = HermesConfig(enabled: state.enabled);
              _releaseRuntimeSession();
              ref.read(hermesConnectionGenerationProvider.notifier).bump();
            } else {
              _activateRuntime(replacement, replacementSecrets);
            }
          }
          DebugLogger.log('connection-deleted', scope: 'hermes/connections');
          await _discardConnectionData(target);
        }

        if (wasActive) {
          await _withRunAdmissionBlocked(() async {
            await _cancelActiveRuns();
            await commit();
          });
        } else {
          await commit();
        }
      });

  /// Best-effort cleanup once a deleted profile is gone from the document.
  /// Leftovers are unreachable: ids are never reused and a full sign-out wipes
  /// all secure storage and preferences.
  Future<void> _discardConnectionData(HermesConnectionProfile profile) async {
    Future<void> attempt(String message, Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        DebugLogger.warning(
          message,
          scope: 'hermes/connections',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }

    await attempt(
      'deleted-connection-secrets-cleanup-failed',
      () => _secure.deleteHermesConnectionSecrets(profile.id),
    );
    final identity = connectionIdentityFor(profile);
    if (identity != null) {
      await attempt(
        'deleted-connection-document-trust-cleanup-failed',
        () => HermesLocalDocumentTrustStore.forgetConnectionIdentity(identity),
      );
      await attempt(
        'deleted-connection-session-binding-cleanup-failed',
        () =>
            HermesMixedSessionBindingTrustStore.forgetConnectionIdentity(
              identity,
            ),
      );
    }
    // Records from before saved connections carry no id and match by origin
    // alone, so a connection still on that origin keeps answering them.
    await attempt(
      'deleted-connection-decision-cleanup-failed',
      () => HermesPendingDecisionStore.clearConnection(
        connectionId: profile.id,
        origin: _originSharedByAnotherConnection(profile.baseUrl, profile.id)
            ? null
            : connectionOrigin(profile.baseUrl),
      ),
    );
  }

  /// Points the runtime at [profile]: replaces the state, releases the
  /// previous connection's session, and rebuilds the transport.
  void _activateRuntime(
    HermesConnectionProfile profile,
    _HermesCredentialSnapshot secrets,
  ) {
    _releaseRuntimeSession();
    // The selected model follows through its own listener on the active
    // connection (see SelectedModel.build); reading it here would be circular.
    state = _configForProfile(profile, enabled: state.enabled, secrets: secrets);
    ref.read(hermesConnectionGenerationProvider.notifier).bump();
  }

  void _releaseRuntimeSession() {
    ref.read(hermesActiveSessionProvider.notifier).set(null);
    final activeConversation = ref.read(activeConversationProvider);
    if (isNativeHermesConversation(activeConversation)) {
      ref.read(activeConversationProvider.notifier).clear();
    }
  }

  static HermesConnectionProfile? _mostRecentlyUsed(
    Iterable<HermesConnectionProfile> profiles,
  ) {
    HermesConnectionProfile? best;
    for (final profile in profiles) {
      final used = profile.lastUsedAt;
      final bestUsed = best?.lastUsedAt;
      if (best == null || (used != null && (bestUsed == null || used.isAfter(bestUsed)))) {
        best = profile;
      }
    }
    return best;
  }

  bool _originSharedByAnotherConnection(String baseUrl, String connectionId) {
    final origin = connectionOrigin(baseUrl);
    if (origin == null) return false;
    return _profiles.any(
      (profile) =>
          profile.id != connectionId &&
          connectionOrigin(profile.baseUrl) == origin,
    );
  }

  List<HermesConnectionProfile> _replacing(HermesConnectionProfile profile) {
    final index = _profiles.indexWhere((existing) => existing.id == profile.id);
    if (index < 0) return [..._profiles, profile];
    return [..._profiles]..[index] = profile;
  }

  Future<void> _writeProfiles(List<HermesConnectionProfile> profiles) async {
    final document = HermesConnectionsDocument(
      connections: profiles,
      legacySecretsOwner: _legacySecretsOwner,
    );
    await HermesConnectionStore.writeDocument(document);
    _profiles = document.connections;
  }

  /// The saved connection whose sessions are bound to [connectionIdentity]
  /// (see [connectionIdentityFor]), if it still exists.
  HermesConnectionProfile? connectionForIdentity(String connectionIdentity) {
    for (final profile in _profiles) {
      if (connectionIdentityFor(profile) == connectionIdentity) return profile;
    }
    return null;
  }

  /// The identity stamped into mixed-chat metadata and document trust for a
  /// saved connection, or null without a usable endpoint.
  static String? connectionIdentityFor(HermesConnectionProfile profile) {
    final endpoint = connectionEndpoint(profile.baseUrl);
    if (endpoint == null) return null;
    return HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: endpoint,
      principalId: profile.documentTrustPrincipalId,
    );
  }

  /// A saved connection with its secrets, for editing it. The active one is
  /// the live state.
  Future<HermesConfig> savedConnectionConfig(String connectionId) async {
    await _secretsHydration;
    _throwIfSecretsUnavailable();
    while (true) {
      if (connectionId == state.connectionId) return state;
      final profile = _profile(connectionId);
      if (profile == null) {
        throw StateError('This Hermes connection no longer exists.');
      }
      final secrets = await _readSecrets(connectionId);
      // A save can re-address the connection while its secrets are read. It
      // replaces the profile before writing any secret, so an unchanged
      // profile means these secrets belong to its address; otherwise read
      // both again rather than pair the old address with new secrets.
      if (identical(_profile(connectionId), profile)) {
        return _configForProfile(
          profile,
          enabled: state.enabled,
          secrets: secrets,
        );
      }
    }
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
    final result = _mutationQueue
        .then<void>(
          (_) => operation(),
          // Defensive recovery if an older implementation or unexpected callback
          // ever left the internal tail in an error state.
          onError: (Object _, StackTrace _) => operation(),
        )
        // Publish the saved-connection list once per mutation, after commit
        // or rollback, rather than at each intermediate document write.
        .whenComplete(_publishConnections);
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _publishConnections() {
    if (ref.mounted) ref.read(hermesConnectionsRevisionProvider.notifier).bump();
  }

  /// Rejects new config writes, drains already-queued writes, and revokes
  /// runtime work before a full app-data wipe.
  Future<void> blockMutationsForAppDataClear() async {
    _configBeforeAppDataClear ??= state;
    _appDataClearBlocked = true;
    _runAdmissionBlocked = true;
    _secretLoadEpoch++;
    // A load in flight may be migrating legacy secrets outside the mutation
    // queue. It stops at its next write; wait for that so nothing it writes
    // lands after the wipe. Loads report their own errors.
    final hydration = _secretsHydration;
    _secretsHydration = Future<void>.value();
    _connectionMutationEpoch++;
    await hydration;
    await _legacySecretMigration?.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
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
    // The wipe never ran, so the durable list is intact; a rebuild under the
    // logout fence may have dropped the in-memory copy meanwhile.
    _restoreProfiles();
    final epoch = ++_secretLoadEpoch;
    final hydration = _loadSecrets(epoch, state.connectionId);
    _secretsHydration = hydration;
    unawaited(hydration);
    _runAdmissionBlocked = false;
  }

  /// Lifts the barrier once the wipe has committed. Riverpod keeps this
  /// notifier across `invalidate`, so without this the rebuild would keep
  /// serving the config captured before the wipe.
  void finishAppDataClear() {
    _appDataClearBlocked = false;
    _configBeforeAppDataClear = null;
  }

  /// Removes live connection authority after a partial wipe while the durable
  /// incomplete-logout fence keeps config and run admission blocked.
  void revokeRuntimeAfterIncompleteAppDataClear() {
    if (!ref.mounted) return;
    // The durable fence owns the persistent block after an incomplete wipe.
    _appDataClearBlocked = false;
    _configBeforeAppDataClear = null;
    _profiles = const [];
    state = const HermesConfig();
    _releaseRuntimeSession();
  }

  Future<void> _persistSecretsAtomically({
    required String connectionId,
    required _HermesCredentialSnapshot previous,
    required _HermesCredentialSnapshot next,
    required _HermesCredentialWrites writes,
  }) async {
    if (!writes.any) return;
    try {
      if (writes.apiKey) await _persistApiKey(connectionId, next.apiKey);
      if (writes.sessionKey) {
        await _persistSessionKey(connectionId, next.sessionKey);
      }
      if (writes.desktop) {
        await _persistDesktopCredentials(connectionId, next.desktop);
      }
    } catch (error, stackTrace) {
      // Secure storage has no multi-key transaction. Restore every key touched
      // by this mutation before surfacing the original failure so the old
      // server remains usable when a replacement write only partially lands.
      var rollbackSucceeded = true;
      Object? rollbackError;
      if (writes.apiKey) {
        try {
          await _persistApiKey(connectionId, previous.apiKey);
        } catch (error) {
          rollbackSucceeded = false;
          rollbackError ??= error;
        }
      }
      if (writes.sessionKey) {
        try {
          await _persistSessionKey(connectionId, previous.sessionKey);
        } catch (error) {
          rollbackSucceeded = false;
          rollbackError ??= error;
        }
      }
      if (writes.desktop) {
        try {
          await _persistDesktopCredentials(connectionId, previous.desktop);
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

  /// Fails a connection closed after a credential mutation of uncertain
  /// outcome: blanks its saved endpoint, or when preferences are unavailable,
  /// removes every touched secret. A connection whose profile was never
  /// written has no endpoint to pair with, so it is already quarantined.
  Future<void> _quarantineUncertainCredentialMutation({
    required String connectionId,
    required bool clearApiKey,
    required bool clearSessionKey,
    required bool clearDesktopCredentials,
  }) async {
    Future<bool> quarantineEndpoint() async {
      final profile = _profile(connectionId);
      if (profile == null) return true;
      await _writeProfiles(_replacing(profile.copyWith(baseUrl: '')));
      return true;
    }

    var endpointQuarantined = false;
    try {
      endpointQuarantined = await quarantineEndpoint();
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
        await _persistApiKey(connectionId, null);
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
        await _persistSessionKey(connectionId, null);
      } catch (error) {
        secretsCleared = false;
        DebugLogger.error(
          'session-key-quarantine-failed',
          scope: 'hermes/config',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }
    if (!endpointQuarantined && clearDesktopCredentials) {
      try {
        await _persistDesktopCredentials(connectionId, null);
      } catch (error) {
        secretsCleared = false;
        DebugLogger.error(
          'desktop-credential-quarantine-failed',
          scope: 'hermes/config',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }

    if (connectionId == state.connectionId) _clearRuntimeConnection();
    if (!endpointQuarantined && !secretsCleared) {
      // One last checked endpoint write handles transient preference failures
      // after best-effort secret clearing. If both stores remain unavailable,
      // keep the runtime disabled and surface the quarantine failure.
      try {
        await quarantineEndpoint();
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
    state = HermesConfig(
      enabled: state.enabled,
      connectionId: state.connectionId,
      name: state.name,
      mode: state.mode,
      desktopAuthKind: state.desktopAuthKind,
      desktopProfile: state.desktopProfile,
      allowSelfSignedCertificates: state.allowSelfSignedCertificates,
    );
    _releaseRuntimeSession();
  }

  Future<void> _persistApiKey(String connectionId, String? value) =>
      value == null
      ? _secure.deleteHermesApiKey(connectionId)
      : _secure.saveHermesApiKey(connectionId, value);

  Future<void> _persistSessionKey(String connectionId, String? value) =>
      value == null
      ? _secure.deleteHermesSessionKey(connectionId)
      : _secure.saveHermesSessionKey(connectionId, value);

  Future<void> _persistDesktopCredentials(
    String connectionId,
    HermesDesktopCredentials? value,
  ) => value == null || value.isEmpty
      ? _secure.deleteHermesDesktopCredentials(connectionId)
      : _secure.saveHermesDesktopCredentials(
          connectionId,
          jsonEncode(value.toJson()),
        );

  Future<T> _withRunAdmissionBlocked<T>(Future<T> Function() operation) async {
    _runAdmissionBlocked = true;
    _connectionMutationEpoch++;
    try {
      return await operation();
    } catch (_) {
      // Even a rolled-back edit revoked the live client's credential writer.
      // Rebuild it for the retained connection without reviving old callbacks.
      if (ref.mounted && !_mutationsBlocked) {
        ref.read(hermesConnectionGenerationProvider.notifier).bump();
      }
      rethrow;
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
  static String? connectionOrigin(String value) =>
      HermesConfig.connectionOrigin(value);

  /// Canonical request root used to detect when the currently configured
  /// Hermes endpoint changes. `/v1` and a trailing slash are equivalent because
  /// [HermesApiService] strips them before composing request paths.
  static String? connectionEndpoint(String value) =>
      HermesConfig.connectionEndpoint(value);

  /// The active connection's trust principal (see
  /// [HermesConnectionProfile.documentTrustPrincipalId]).
  String documentTrustPrincipalId() {
    final active = _activeProfile;
    if (active != null) return active.documentTrustPrincipalId;
    // Without an active saved connection nothing can bind to a principal
    // durably. Honour a legacy principal that has not been migrated yet,
    // otherwise keep one for the life of this controller.
    final legacy = PreferencesStore.getString(
      PreferenceKeys.hermesLocalDocumentTrustPrincipal,
    )?.trim();
    if (legacy != null && HermesConnectionProfile.isValidPrincipalId(legacy)) {
      return _runtimeDocumentTrustPrincipalId = legacy;
    }
    return _runtimeDocumentTrustPrincipalId ??= const Uuid().v4();
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

        final connectionId = state.connectionId;
        if (connectionId == null) {
          throw StateError('Hermes has no saved connection.');
        }
        final generated = const Uuid().v4();
        await _secure.saveHermesSessionKey(connectionId, generated);
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
    HermesBackendMode? mode,
    HermesDesktopAuthKind? desktopAuthKind,
    String? desktopProfile,
    String? apiKey = _keep,
    String? sessionKey = _keep,
    Object? desktopCredentials = _keepObject,
  }) {
    return HermesConfig(
      enabled: enabled ?? state.enabled,
      connectionId: state.connectionId,
      name: state.name,
      baseUrl: baseUrl ?? state.baseUrl,
      mode: mode ?? state.mode,
      desktopAuthKind: desktopAuthKind ?? state.desktopAuthKind,
      desktopProfile: desktopProfile ?? state.desktopProfile,
      allowSelfSignedCertificates: state.allowSelfSignedCertificates,
      apiKey: identical(apiKey, _keep) ? state.apiKey : apiKey,
      sessionKey: identical(sessionKey, _keep) ? state.sessionKey : sessionKey,
      desktopCredentials: identical(desktopCredentials, _keepObject)
          ? state.desktopCredentials
          : desktopCredentials as HermesDesktopCredentials?,
    );
  }

  // Sentinel so setters can distinguish "leave unchanged" from "clear to null".
  static const String _keep = '__hermes_keep__';
  static const Object _keepObject = Object();
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

/// The host's WebView-backed dashboard bridge, if it has one.
///
/// Hermes' dashboard authenticates with cookies a WebView holds, so the
/// implementation drives `flutter_inappwebview` and cannot live beside this
/// file. A host that registers nothing simply cannot reach the dashboard,
/// which the auth path reports rather than failing opaquely.
final hostHermesDashboardBridgeFactoryProvider =
    Provider<HermesDashboardBridgeFactory?>((ref) => null);

/// Asks the user whether to switch to the saved Hermes connection named
/// [connectionName]. Resolves false when declined or when nobody can be asked.
typedef HermesConnectionSwitchPrompt =
    Future<bool> Function(String connectionName);

/// Offered before continuing a mixed chat whose Hermes session belongs to an
/// inactive saved connection. The core cannot localize the question, so the
/// host binds it (through its UI request port); the default declines, which
/// keeps starting a new session on the active connection.
final hermesConnectionSwitchPromptProvider =
    Provider<HermesConnectionSwitchPrompt>((ref) => (_) async => false);

final hermesConfigProvider =
    NotifierProvider<HermesConfigController, HermesConfig>(
      HermesConfigController.new,
    );

class HermesConnectionsRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Bumped after every saved-connection mutation, including edits of inactive
/// connections that leave [hermesConfigProvider] unchanged.
final hermesConnectionsRevisionProvider =
    NotifierProvider<HermesConnectionsRevision, int>(
      HermesConnectionsRevision.new,
    );

/// Saved Hermes connections, in the order they were added.
final hermesConnectionsProvider = Provider<List<HermesConnectionProfile>>((
  ref,
) {
  ref.watch(hermesConnectionsRevisionProvider);
  // Building the config controller restores (or migrates) the saved list.
  ref.watch(hermesConfigProvider);
  return ref.read(hermesConfigProvider.notifier).connections;
});

/// Id of the active saved connection, or null when none is saved.
final hermesActiveConnectionIdProvider = Provider<String?>(
  (ref) => ref.watch(hermesConfigProvider.select((config) => config.connectionId)),
);

/// Display name of the active saved connection, or null when none is saved.
final hermesActiveConnectionNameProvider = Provider<String?>(
  (ref) => ref.watch(hermesConfigProvider.select((config) => config.name)),
);

class HermesConnectionGeneration extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Non-secret epoch used to replace a transport after an identity mutation.
final hermesConnectionGenerationProvider =
    NotifierProvider<HermesConnectionGeneration, int>(
      HermesConnectionGeneration.new,
    );

/// Whether the Hermes agent is toggled on (regardless of whether it is fully
/// configured). Used to decide whether to surface the synthetic model.
final hermesEnabledProvider = Provider<bool>(
  (ref) => ref.watch(hermesConfigProvider).enabled,
);

class HermesFastTierSelection extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(selectedModelProvider.select((model) => model?.id));
    return false;
  }

  void set(bool value) => state = value;
}

final hermesFastTierSelectionProvider =
    NotifierProvider<HermesFastTierSelection, bool>(
      HermesFastTierSelection.new,
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
final hermesApiServiceProvider = Provider<HermesBackendService?>((ref) {
  ref.watch(hermesConnectionGenerationProvider);
  ref.watch(
    hermesConfigProvider.select(
      (config) => (
        config.enabled,
        config.connectionId,
        config.baseUrl,
        config.mode,
        config.desktopAuthKind,
        config.desktopProfile,
        config.allowSelfSignedCertificates,
        config.isUsable,
      ),
    ),
  );
  final config = ref.read(hermesConfigProvider);
  if (!config.isUsable) return null;
  final HermesBackendService service;
  if (config.mode == HermesBackendMode.desktopGateway) {
    // Rotations land even after this client is replaced, as by a switch
    // away: the server has already spent the refresh token they replace.
    // They never overwrite tokens this client did not hold.
    final writeCredentials = ref
        .read(hermesConfigProvider.notifier)
        .credentialsWriterFor(config, live: true);
    final desktopService = HermesDesktopApiService(
      config: config,
      openExternalUrl: ref.read(openExternalUrlProvider),
      dashboardBridgeFactory: ref.read(
        hostHermesDashboardBridgeFactoryProvider,
      ),
      onCredentialsChanged: (credentials) async {
        try {
          await writeCredentials(credentials);
        } catch (error) {
          DebugLogger.error(
            'desktop-token-rotation-persist-failed',
            scope: 'hermes/config',
            data: {'errorType': error.runtimeType.toString()},
          );
        }
      },
    );
    desktopService.startLifecycleObservation(ref.read(appLifecycleProvider));
    service = desktopService;
  } else {
    service = HermesApiService(config: config);
  }
  ref.onDispose(service.close);
  return service;
});

/// Authoritative Desktop turn state. Responses mode remains on its existing
/// dispatcher and therefore always exposes the neutral idle state here.
final hermesDesktopTurnStateProvider =
    StreamProvider.autoDispose<HermesDesktopTurnState>((ref) async* {
      final service = ref.watch(hermesApiServiceProvider);
      if (service is! HermesDesktopApiService) {
        yield HermesDesktopTurnState.idle;
        return;
      }
      final conversation = ref.watch(activeConversationProvider);
      if (!isNativeHermesConversation(conversation)) {
        yield HermesDesktopTurnState.idle;
        return;
      }
      final storedId = conversation?.metadata['hermesSessionId']?.toString();
      if (storedId == null || storedId.isEmpty) {
        yield HermesDesktopTurnState.idle;
        return;
      }
      yield* service.turnStatesFor(storedId);
    });

final hermesDesktopTranscriptChangesProvider = StreamProvider<String>((ref) {
  final service = ref.watch(hermesApiServiceProvider);
  return service is HermesDesktopApiService
      ? service.transcriptChanges
      : const Stream<String>.empty();
});

final hermesDesktopModelsProvider = FutureProvider<List<Model>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service is! HermesDesktopApiService) return const [];
  final rows = await service.configuredModels();
  final models = <Model>[];
  for (final row in rows.take(1000)) {
    final id = validateHermesBoundedString(row.id, maxCharacters: 512);
    if (id == null) continue;
    final provider =
        validateHermesBoundedString(
          row.provider,
          maxCharacters: 128,
          allowEmpty: true,
        ) ??
        '';
    models.add(
      hermesDesktopModel(
        modelId: id,
        name: validateHermesBoundedString(row.name, maxCharacters: 512) ?? id,
        provider: provider,
        supportsFast: row.supportsFast,
        supportsReasoning: row.supportsReasoning,
      ),
    );
  }
  return models;
});

/// The Hermes agent's skills mapped to [Prompt]s so they can drive the existing
/// `/` slash-command overlay. Selecting one inserts `/skill-name ` into the
/// composer, which the agent interprets natively. Empty when Hermes is off.
final hermesSkillPromptsProvider = FutureProvider<List<Prompt>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const [];
  final skills = service is HermesDesktopApiService
      ? await service.listCommands()
      : await service.listSkills();
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

final hermesInstalledSkillsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
      final service = ref.watch(hermesApiServiceProvider);
      return service is HermesDesktopApiService
          ? service.listSkills()
          : const [];
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

  HermesBackendService? get _service => ref.read(hermesApiServiceProvider);

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

/// Bot Mode roster, newest activity first. Empty on gateways without Bot Mode
/// and on the Responses backend, which hides the sidebar section entirely.
final hermesBotsProvider = FutureProvider<List<HermesBot>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service is! HermesDesktopApiService) return const [];
  ref.watch(hermesDesktopContractProvider);
  try {
    return sortHermesBotsByRecency(await service.listBots());
  } catch (_) {
    // An older gateway rejects profiles.list outright; the roster is optional.
    return const [];
  }
});

/// Roster order: most recently active first.
///
/// Copies before sorting — the Bot-Mode-off path yields an unmodifiable const
/// list, which would sort in place with an `UnsupportedError`.
@visibleForTesting
List<HermesBot> sortHermesBotsByRecency(List<HermesBot> bots) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  return [...bots]
    ..sort((a, b) => (b.lastActive ?? epoch).compareTo(a.lastActive ?? epoch));
}

/// A bot's avatar data URL, or null when it has none.
final hermesBotAvatarProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, profile) async {
      final service = ref.watch(hermesApiServiceProvider);
      if (service is! HermesDesktopApiService) return null;
      try {
        return await service.botAvatar(profile);
      } catch (_) {
        return null;
      }
    });

/// Server-advertised capabilities (`/v1/capabilities`). Falls back to the
/// optimistic all-enabled default when discovery fails, so features are only
/// hidden when the server explicitly says they're unsupported.
final hermesCapabilitiesProvider = FutureProvider<HermesCapabilities>((
  ref,
) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return HermesCapabilities.enabledByDefault;
  if (service is HermesDesktopApiService) {
    ref.watch(hermesDesktopContractProvider);
  }
  try {
    return HermesCapabilities.fromJson(await service.getCapabilities());
  } catch (_) {
    return service is HermesDesktopApiService
        ? HermesCapabilities.desktopCoreOnly
        : HermesCapabilities.enabledByDefault;
  }
});

final hermesDesktopContractProvider = StreamProvider<int>((ref) {
  final service = ref.watch(hermesApiServiceProvider);
  return service is HermesDesktopApiService
      ? service.desktopContracts()
      : const Stream<int>.empty();
});

/// Synchronous best-effort view of capabilities for gating UI (optimistic
/// default while loading / on error).
HermesCapabilities hermesCapabilitiesNow(Ref ref) =>
    ref.read(hermesCapabilitiesProvider).asData?.value ??
    (ref.read(hermesConfigProvider).mode == HermesBackendMode.desktopGateway
        ? HermesCapabilities.desktopCoreOnly
        : HermesCapabilities.enabledByDefault);

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

  HermesBackendService get _service =>
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
    ref.invalidate(hermesJobRunsProvider(id));
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

/// Desktop cron runs are ordinary Hermes sessions, newest first.
final hermesJobRunsProvider = FutureProvider.autoDispose
    .family<List<HermesSessionSummary>, String>((ref, jobId) async {
      final service = ref.watch(hermesApiServiceProvider);
      if (service is! HermesDesktopApiService) return const [];
      final rows = await service.listJobRuns(jobId);
      return rows
          .map(HermesSessionSummary.fromJson)
          .whereType<HermesSessionSummary>()
          .take(20)
          .toList(growable: false);
    });

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
  final List<void Function()> _whenIdle = [];

  /// Calls [callback] once no run is active: now, or when the last one ends.
  void whenIdle(void Function() callback) {
    if (_runs.isEmpty) {
      callback();
    } else {
      _whenIdle.add(callback);
    }
  }

  void _notifyIfIdle() {
    if (_runs.isNotEmpty || _whenIdle.isEmpty) return;
    final callbacks = List.of(_whenIdle);
    _whenIdle.clear();
    for (final callback in callbacks) {
      _observeHermesRegistryCleanup(
        () async => callback(),
        message: 'idle-callback-failed',
      );
    }
  }

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

  /// Associates an inline stream with a run announced by one of its events.
  bool bindRunId(
    HermesRunKey key, {
    required CancelToken cancelToken,
    required String runId,
  }) {
    final run = _runs[key];
    if (run == null ||
        run.cancelled ||
        !identical(run.cancelToken, cancelToken) ||
        (run.runId != null && run.runId != runId)) {
      return false;
    }
    run.runId = runId;
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
    final stopped = _cancelDetached(run);
    _notifyIfIdle();
    return stopped;
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
    final stopped = _cancelDetached(run);
    _notifyIfIdle();
    return stopped;
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
    _notifyIfIdle();
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
