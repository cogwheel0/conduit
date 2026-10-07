import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show selectedModelProvider;
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _a = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _b = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _c = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _legacyPrincipal = '12345678-1234-4234-8234-123456789012';

void main() {
  setUp(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
  });
  tearDown(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  group('migration', () {
    void seedLegacyPreferences() {
      PreferencesStore.debugOverride(
        InMemoryKeyValueStore(<String, Object?>{
          PreferenceKeys.hermesEnabled: true,
          PreferenceKeys.hermesBaseUrl: 'https://legacy.example/v1',
          PreferenceKeys.hermesBackendMode:
              HermesBackendMode.desktopGateway.name,
          PreferenceKeys.hermesDesktopAuthKind:
              HermesDesktopAuthKind.nativePkce.name,
          PreferenceKeys.hermesDesktopProfile: 'work',
          PreferenceKeys.hermesAllowSelfSignedCertificates: true,
          PreferenceKeys.hermesLocalDocumentTrustPrincipal: _legacyPrincipal,
        }),
      );
    }

    Map<String, String> legacySecrets() => <String, String>{
      'hermes_api_key_v1': 'legacy-key',
      'hermes_session_key_v1': 'legacy-memory',
      'hermes_desktop_credentials_v1':
          '{"legacy_token":"legacy-token","access_headers":{}}',
    };

    test(
      'moves the single connection into the first saved connection',
      () async {
        seedLegacyPreferences();
        final secrets = _Secrets(legacySecrets());
        final container = await _ready(secrets);
        addTearDown(container.dispose);

        final config = container.read(hermesConfigProvider);
        final id = config.connectionId!;
        check(HermesConnectionProfile.isValidId(id)).isTrue();
        check(config.name).equals(kHermesDefaultConnectionName);
        check(config.baseUrl).equals('https://legacy.example/v1');
        check(config.mode).equals(HermesBackendMode.desktopGateway);
        check(config.desktopAuthKind).equals(HermesDesktopAuthKind.nativePkce);
        check(config.desktopProfile).equals('work');
        check(config.allowSelfSignedCertificates).isTrue();
        check(config.apiKey).equals('legacy-key');
        check(config.sessionKey).equals('legacy-memory');
        check(config.desktopCredentials?.legacyToken).equals('legacy-token');

        final document = HermesConnectionStore.readDocument()!;
        final profile = document.connections.single;
        check(profile.id).equals(id);
        check(profile.nameSource).equals(HermesConnectionNameSource.derived);
        // Existing mixed-chat bindings and document trust stay valid.
        check(profile.documentTrustPrincipalId).equals(_legacyPrincipal);
        check(
          container
              .read(hermesConfigProvider.notifier)
              .documentTrustPrincipalId(),
        ).equals(_legacyPrincipal);
        check(document.legacySecretsOwner).isNull();
        check(HermesConnectionStore.readActiveId()).equals(id);
        for (final key in HermesConnectionStore.legacyKeys) {
          check(PreferencesStore.containsKey(key)).isFalse();
        }
        check(PreferencesStore.getBool(PreferenceKeys.hermesEnabled))
            .equals(true);

        check(await secrets.read(key: 'hermes_api_key_v1:$id'))
            .equals('legacy-key');
        check(await secrets.read(key: 'hermes_session_key_v1:$id'))
            .equals('legacy-memory');
        check(await secrets.read(key: 'hermes_desktop_credentials_v1:$id'))
            .isNotNull();
        for (final key in legacySecrets().keys) {
          check(await secrets.read(key: key)).isNull();
        }

        // A restart reads the saved connection instead of migrating again.
        final restarted = await _ready(secrets);
        addTearDown(restarted.dispose);
        check(restarted.read(hermesConfigProvider).connectionId).equals(id);
        check(restarted.read(hermesConfigProvider).apiKey).equals('legacy-key');
        check(restarted.read(hermesConnectionsProvider)).length.equals(1);
      },
    );

    test(
      'a failed secret copy keeps the legacy key and retries on the next load',
      () async {
        seedLegacyPreferences();
        final secrets = _Secrets(legacySecrets())
          ..failWritePrefixes.add('hermes_session_key_v1:');
        final container = await _ready(secrets);
        addTearDown(container.dispose);
        final id = container.read(hermesConfigProvider).connectionId!;

        check(container.read(hermesSecretsErrorProvider)).isNotNull();
        // The API key moved before the failure; the session key did not.
        check(await secrets.read(key: 'hermes_api_key_v1:$id'))
            .equals('legacy-key');
        check(await secrets.read(key: 'hermes_api_key_v1')).isNull();
        check(await secrets.read(key: 'hermes_session_key_v1'))
            .equals('legacy-memory');
        check(await secrets.read(key: 'hermes_session_key_v1:$id')).isNull();
        check(HermesConnectionStore.readDocument()!.legacySecretsOwner)
            .equals(id);
        // Mutations stay blocked while legacy secrets are half-moved.
        await check(
          container
              .read(hermesConfigProvider.notifier)
              .saveConnection(baseUrl: 'https://legacy.example/v1'),
        ).throws<StateError>();

        await container.read(hermesConfigProvider.notifier).retrySecrets();

        check(container.read(hermesSecretsErrorProvider)).isNull();
        check(container.read(hermesConfigProvider).sessionKey)
            .equals('legacy-memory');
        check(await secrets.read(key: 'hermes_session_key_v1:$id'))
            .equals('legacy-memory');
        check(await secrets.read(key: 'hermes_session_key_v1')).isNull();
        check(HermesConnectionStore.readDocument()!.legacySecretsOwner)
            .isNull();
      },
    );

    test('an unverifiable copy never deletes the legacy secret', () async {
      seedLegacyPreferences();
      final secrets = _Secrets(legacySecrets())
        ..dropWritePrefixes.add('hermes_api_key_v1:');
      final container = await _ready(secrets);
      addTearDown(container.dispose);

      check(container.read(hermesSecretsErrorProvider)).isNotNull();
      check(await secrets.read(key: 'hermes_api_key_v1')).equals('legacy-key');

      // The next load, with storage behaving, finishes the move.
      secrets.dropWritePrefixes.clear();
      final restarted = await _ready(secrets);
      addTearDown(restarted.dispose);
      final id = restarted.read(hermesConfigProvider).connectionId!;
      check(restarted.read(hermesSecretsErrorProvider)).isNull();
      check(restarted.read(hermesConfigProvider).apiKey).equals('legacy-key');
      check(await secrets.read(key: 'hermes_api_key_v1:$id'))
          .equals('legacy-key');
      check(await secrets.read(key: 'hermes_api_key_v1')).isNull();
    });

    test('an app-data wipe waits for a secret copy in flight', () async {
      seedLegacyPreferences();
      final secrets = _Secrets(legacySecrets());
      final apiKeyRead = Completer<void>();
      secrets.heldReads['hermes_api_key_v1'] = apiKeyRead.future;
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(secrets)],
      );
      addTearDown(container.dispose);
      container.read(hermesConfigProvider);
      await pumpEventQueue();

      var blocked = false;
      final barrier = container
          .read(hermesConfigProvider.notifier)
          .blockMutationsForAppDataClear()
          .then((_) => blocked = true);
      await pumpEventQueue();
      check(blocked).isFalse();

      apiKeyRead.complete();
      await barrier;
      // The copy stopped at its next write rather than racing the wipe.
      check(
        (await secrets.readAll()).keys,
      ).not((it) => it.any((key) => key.startsWith('hermes_api_key_v1:')));
      await secrets.deleteAll();
      await pumpEventQueue();
      check(await secrets.readAll()).isEmpty();
    });

    test(
      'a lone legacy trust principal does not create a connection',
      () async {
        PreferencesStore.debugOverride(
          InMemoryKeyValueStore(<String, Object?>{
            PreferenceKeys.hermesLocalDocumentTrustPrincipal: _legacyPrincipal,
          }),
        );
        final container = await _ready(_Secrets());
        addTearDown(container.dispose);

        check(container.read(hermesConfigProvider).connectionId).isNull();
        check(container.read(hermesConnectionsProvider)).isEmpty();
        check(HermesConnectionStore.readDocument()).isNull();
      },
    );
  });

  group('switching', () {
    test(
      'cancels runs, bumps the generation, and releases the session',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example'),
          _profile(_b, 'Beta', 'https://beta.example'),
        ], active: _a);
        final secrets = _Secrets({
          'hermes_api_key_v1:$_a': 'alpha-key',
          'hermes_api_key_v1:$_b': 'beta-key',
        });
        final container = await _ready(secrets);
        addTearDown(container.dispose);
        container
            .read(hermesActiveSessionProvider.notifier)
            .set('alpha-session');
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel(name: 'Alpha'));
        final run = container
            .read(hermesRunRegistryProvider)
            .registerPending(
              legacyHermesRunKey('alpha-run'),
              onCancelled: () {},
            );
        final generation = container.read(hermesConnectionGenerationProvider);

        await container
            .read(hermesConfigProvider.notifier)
            .setActiveConnection(_b);

        check(run.isCancelled).isTrue();
        check(container.read(hermesConnectionGenerationProvider))
            .isGreaterThan(generation);
        check(container.read(hermesActiveSessionProvider)).isNull();
        final config = container.read(hermesConfigProvider);
        check(config.connectionId).equals(_b);
        check(config.name).equals('Beta');
        check(config.baseUrl).equals('https://beta.example');
        check(config.apiKey).equals('beta-key');
        check(container.read(hermesActiveConnectionIdProvider)).equals(_b);
        check(container.read(hermesActiveConnectionNameProvider))
            .equals('Beta');
        check(container.read(selectedModelProvider)?.name).equals('Beta');
        check(HermesConnectionStore.readActiveId()).equals(_b);
        final beta = container
            .read(hermesConnectionsProvider)
            .singleWhere((profile) => profile.id == _b);
        check(beta.lastUsedAt).isNotNull();
        check(
          container
              .read(hermesConfigProvider.notifier)
              .documentTrustPrincipalId(),
        ).equals(_principalFor(_b));
      },
    );

    test(
      'keeps the current connection when the target secrets are unreadable',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example'),
          _profile(_b, 'Beta', 'https://beta.example'),
        ], active: _a);
        final secrets = _Secrets({'hermes_api_key_v1:$_a': 'alpha-key'});
        final container = await _ready(secrets);
        addTearDown(container.dispose);
        final run = container
            .read(hermesRunRegistryProvider)
            .registerPending(
              legacyHermesRunKey('alpha-run'),
              onCancelled: () {},
            );
        secrets.failReadPrefixes.add('hermes_api_key_v1:$_b');

        await check(
          container.read(hermesConfigProvider.notifier).setActiveConnection(_b),
        ).throws<StateError>();

        check(run.isCancelled).isFalse();
        check(container.read(hermesConfigProvider).connectionId).equals(_a);
        check(container.read(hermesConfigProvider).apiKey).equals('alpha-key');
        check(HermesConnectionStore.readActiveId()).equals(_a);
      },
    );
  });

  group('deleting', () {
    test(
      'the active connection activates the most recently used one',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example'),
          _profile(
            _b,
            'Beta',
            'https://beta.example',
            lastUsedAt: DateTime.utc(2025),
          ),
          _profile(
            _c,
            'Gamma',
            'https://gamma.example',
            lastUsedAt: DateTime.utc(2026),
          ),
        ], active: _a);
        final secrets = _Secrets({
          'hermes_api_key_v1:$_a': 'alpha-key',
          'hermes_session_key_v1:$_a': 'alpha-memory',
          'hermes_api_key_v1:$_b': 'beta-key',
          'hermes_api_key_v1:$_c': 'gamma-key',
        });
        final container = await _ready(secrets);
        addTearDown(container.dispose);
        final alphaIdentity = _identityFor(_a, 'https://alpha.example');
        final betaIdentity = _identityFor(_b, 'https://beta.example');
        await _rememberDocumentTrust(alphaIdentity);
        await _rememberDocumentTrust(betaIdentity);
        await _rememberSessionBinding(alphaIdentity);
        final run = container
            .read(hermesRunRegistryProvider)
            .registerPending(
              legacyHermesRunKey('alpha-run'),
              onCancelled: () {},
            );
        final generation = container.read(hermesConnectionGenerationProvider);
        final controller = container.read(hermesConfigProvider.notifier);

        await controller.deleteConnection(_a);

        check(run.isCancelled).isTrue();
        check(container.read(hermesConnectionGenerationProvider))
            .isGreaterThan(generation);
        final config = container.read(hermesConfigProvider);
        check(config.connectionId).equals(_c);
        check(config.apiKey).equals('gamma-key');
        check(HermesConnectionStore.readActiveId()).equals(_c);
        check(
          container
              .read(hermesConnectionsProvider)
              .map((profile) => profile.id),
        ).deepEquals([_b, _c]);
        check(await secrets.read(key: 'hermes_api_key_v1:$_a')).isNull();
        check(await secrets.read(key: 'hermes_session_key_v1:$_a')).isNull();
        check(
          HermesLocalDocumentTrustStore.trustedDocumentKeys(
            connectionIdentity: alphaIdentity,
            sessionId: 'session',
          ),
        ).isEmpty();
        check(
          HermesLocalDocumentTrustStore.trustedDocumentKeys(
            connectionIdentity: betaIdentity,
            sessionId: 'session',
          ),
        ).isNotEmpty();
        check(_sessionBindingTrusted(alphaIdentity)).isFalse();

        await controller.deleteConnection(_c);
        check(container.read(hermesConfigProvider).connectionId).equals(_b);

        await controller.deleteConnection(_b);
        final empty = container.read(hermesConfigProvider);
        check(empty.connectionId).isNull();
        check(empty.baseUrl).isEmpty();
        check(empty.isUsable).isFalse();
        check(container.read(hermesApiServiceProvider)).isNull();
        check(HermesConnectionStore.readActiveId()).isNull();
        check(container.read(hermesConnectionsProvider)).isEmpty();
      },
    );

    test('a failed delete keeps the connection active', () async {
      _seedConnections([
        _profile(_a, 'Alpha', 'https://alpha.example'),
        _profile(_b, 'Beta', 'https://beta.example'),
      ], active: _a);
      final secrets = _Secrets({
        'hermes_api_key_v1:$_a': 'alpha-key',
        'hermes_api_key_v1:$_b': 'beta-key',
      });
      final container = await _ready(secrets);
      addTearDown(container.dispose);
      PreferencesStore.debugOverride(
        PreferencesStore.instance,
        writeInterceptor: (_, key, _) async =>
            key == PreferenceKeys.hermesConnections ? false : null,
      );

      await check(
        container.read(hermesConfigProvider.notifier).deleteConnection(_a),
      ).throws<StateError>();

      check(container.read(hermesConfigProvider).connectionId).equals(_a);
      check(HermesConnectionStore.readActiveId()).equals(_a);
      check(container.read(hermesConnectionsProvider)).length.equals(2);
      check(await secrets.read(key: 'hermes_api_key_v1:$_a'))
          .equals('alpha-key');
    });

    test(
      'clears dashboard cookies only when no connection shares the origin',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://shared.example/one'),
          _profile(_b, 'Beta', 'https://shared.example/two'),
        ], active: _a);
        final cookies = _RecordingCookieJar();
        final container = await _ready(_Secrets(), cookies: cookies);
        addTearDown(container.dispose);
        final controller = container.read(hermesConfigProvider.notifier);

        await controller.deleteConnection(_b);
        check(cookies.clearedOrigins).isEmpty();

        await controller.deleteConnection(_a);
        check(cookies.clearedOrigins)
            .deepEquals(['https://shared.example/one']);
      },
    );

    test(
      'keeps pending decisions from before the upgrade while a connection '
      'shares their origin',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://shared.example/one'),
          _profile(_b, 'Beta', 'https://shared.example/two'),
        ], active: _a);
        final container = await _ready(_Secrets());
        addTearDown(container.dispose);
        final controller = container.read(hermesConfigProvider.notifier);
        // Written before saved connections existed, so it has no id.
        await HermesPendingDecisionStore.upsert(
          origin: 'https://shared.example:443',
          storedSessionId: 'stored-1',
          runtimeId: 'runtime-1',
          requestId: 'request-1',
          kind: HermesPendingDesktopDecisionKind.approval,
        );
        Future<int> pending() async =>
            (await HermesPendingDecisionStore.forSession(
              origin: 'https://shared.example:443',
              storedSessionId: 'stored-1',
            )).length;

        await controller.deleteConnection(_b);
        check(await pending()).equals(1);

        await controller.deleteConnection(_a);
        check(await pending()).equals(0);
      },
    );

    test(
      'an edit moving off a shared origin keeps its pending decisions from '
      'before the upgrade',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://shared.example/one'),
          _profile(_b, 'Beta', 'https://shared.example/two'),
        ], active: _a);
        final container = await _ready(
          _Secrets({
            'hermes_api_key_v1:$_a': 'alpha-key',
            'hermes_api_key_v1:$_b': 'beta-key',
          }),
          cookies: _RecordingCookieJar(),
        );
        addTearDown(container.dispose);
        final controller = container.read(hermesConfigProvider.notifier);
        // Written before saved connections existed, so it has no id.
        await HermesPendingDecisionStore.upsert(
          origin: 'https://shared.example:443',
          storedSessionId: 'stored-1',
          runtimeId: 'runtime-1',
          requestId: 'request-1',
          kind: HermesPendingDesktopDecisionKind.approval,
        );
        Future<int> pending() async =>
            (await HermesPendingDecisionStore.forSession(
              origin: 'https://shared.example:443',
              storedSessionId: 'stored-1',
            )).length;

        await controller.saveConnection(
          connectionId: _b,
          baseUrl: 'https://beta.example',
        );
        check(await pending()).equals(1);

        await controller.saveConnection(
          connectionId: _a,
          baseUrl: 'https://alpha.example',
        );
        check(await pending()).equals(0);
      },
    );

    test('keeps a connection whose dashboard cookies stay set', () async {
      _seedConnections([
        _profile(_a, 'Alpha', 'https://alpha.example'),
        _profile(_b, 'Beta', 'https://beta.example'),
      ], active: _a);
      final secrets = _Secrets({
        'hermes_api_key_v1:$_a': 'alpha-key',
        'hermes_api_key_v1:$_b': 'beta-key',
      });
      final cookies = _RecordingCookieJar(clears: false);
      final container = await _ready(secrets, cookies: cookies);
      addTearDown(container.dispose);

      await check(
        container.read(hermesConfigProvider.notifier).deleteConnection(_b),
      ).throws<StateError>();

      check(cookies.clearedOrigins).deepEquals(['https://beta.example']);
      check(
        container.read(hermesConnectionsProvider).map((profile) => profile.id),
      ).deepEquals([_a, _b]);
      check(await secrets.read(key: 'hermes_api_key_v1:$_b'))
          .equals('beta-key');
      check(container.read(hermesConfigProvider).connectionId).equals(_a);
    });

    test(
      'keeps dashboard cookies when the replacement cannot be read',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example'),
          _profile(_b, 'Beta', 'https://beta.example'),
        ], active: _a);
        final secrets = _Secrets({
          'hermes_api_key_v1:$_a': 'alpha-key',
          'hermes_api_key_v1:$_b': 'beta-key',
        });
        final cookies = _RecordingCookieJar();
        final container = await _ready(secrets, cookies: cookies);
        addTearDown(container.dispose);
        secrets.failReadPrefixes.add('hermes_api_key_v1:$_b');

        await check(
          container.read(hermesConfigProvider.notifier).deleteConnection(_a),
        ).throws<StateError>();

        check(cookies.clearedOrigins).isEmpty();
        check(container.read(hermesConfigProvider).connectionId).equals(_a);
        check(HermesConnectionStore.readActiveId()).equals(_a);
        check(
          container
              .read(hermesConnectionsProvider)
              .map((profile) => profile.id),
        ).deepEquals([_a, _b]);
        check(await secrets.read(key: 'hermes_api_key_v1:$_a'))
            .equals('alpha-key');
      },
    );
  });

  group('inactive connections', () {
    test('are created and edited without touching the runtime', () async {
      _seedConnections([
        _profile(_a, 'Alpha', 'https://alpha.example'),
      ], active: _a);
      final secrets = _Secrets({'hermes_api_key_v1:$_a': 'alpha-key'});
      final container = await _ready(secrets);
      addTearDown(container.dispose);
      container.read(hermesActiveSessionProvider.notifier).set('alpha-session');
      final run = container
          .read(hermesRunRegistryProvider)
          .registerPending(legacyHermesRunKey('alpha-run'), onCancelled: () {});
      final generation = container.read(hermesConnectionGenerationProvider);
      final controller = container.read(hermesConfigProvider.notifier);
      final before = container.read(hermesConfigProvider);

      final created = await controller.createConnection(
        baseUrl: 'https://beta.example',
        apiKey: 'beta-key',
      );
      final createdProfile = container
          .read(hermesConnectionsProvider)
          .singleWhere((profile) => profile.id == created);
      check(createdProfile.name).equals('beta.example');
      check(createdProfile.nameSource)
          .equals(HermesConnectionNameSource.derived);
      check(await secrets.read(key: 'hermes_api_key_v1:$created'))
          .equals('beta-key');

      await controller.saveConnection(
        connectionId: created,
        baseUrl: 'https://beta-two.example',
        name: 'Beta',
        apiKeyChanged: true,
        apiKey: 'beta-two-key',
      );
      final edited = container
          .read(hermesConnectionsProvider)
          .singleWhere((profile) => profile.id == created);
      check(edited.name).equals('Beta');
      check(edited.nameSource).equals(HermesConnectionNameSource.user);
      check(edited.baseUrl).equals('https://beta-two.example');
      check(edited.documentTrustPrincipalId)
          .not((it) => it.equals(createdProfile.documentTrustPrincipalId));
      check(await secrets.read(key: 'hermes_api_key_v1:$created'))
          .equals('beta-two-key');
      check((await controller.savedConnectionConfig(created)).apiKey)
          .equals('beta-two-key');

      check(container.read(hermesConfigProvider)).equals(before);
      check(run.isCancelled).isFalse();
      check(container.read(hermesActiveSessionProvider))
          .equals('alpha-session');
      check(container.read(hermesConnectionGenerationProvider))
          .equals(generation);
      check(HermesConnectionStore.readActiveId()).equals(_a);
    });

    test('a stale client cannot undo a token rotation', () async {
      _seedConnections([
        _profile(_a, 'Alpha', 'https://alpha.example'),
        _profile(_b, 'Beta', 'https://beta.example').copyWith(
          mode: HermesBackendMode.desktopGateway,
          desktopAuthKind: HermesDesktopAuthKind.nativePkce,
        ),
      ], active: _a);
      final secrets = _Secrets({
        'hermes_api_key_v1:$_a': 'alpha-key',
        'hermes_desktop_credentials_v1:$_b': jsonEncode(
          _nativeCredentials('refresh-0').toJson(),
        ),
      });
      final container = await _ready(secrets);
      addTearDown(container.dispose);
      final controller = container.read(hermesConfigProvider.notifier);
      Future<String?> storedRefreshToken() async {
        final stored = await controller.savedConnectionConfig(_b);
        return stored.desktopCredentials?.nativeTokens?.refreshToken;
      }

      // Two temporary clients built from the same stored tokens.
      final beta = await controller.savedConnectionConfig(_b);
      final first = controller.credentialsWriterFor(beta);
      final second = controller.credentialsWriterFor(beta);

      await first(_nativeCredentials('refresh-1'));
      // The second client's refresh token is spent; its sign-out after the
      // resulting 401 must not erase the rotated tokens.
      await check(second(HermesDesktopCredentials())).throws<StateError>();
      check(await storedRefreshToken()).equals('refresh-1');

      // The client that rotated keeps persisting its own rotations.
      await first(_nativeCredentials('refresh-2'));
      check(await storedRefreshToken()).equals('refresh-2');
    });

    // A client of the active connection refreshes its tokens; the server
    // has spent the old refresh token by the time the new ones land.
    for (final (change, leave)
        in <(String, Future<void> Function(HermesConfigController))>[
      ('a switch away', (controller) => controller.setActiveConnection(_b)),
      ('turning Hermes off', (controller) => controller.setEnabled(false)),
    ]) {
      test('a token rotation landing after $change is kept', () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example').copyWith(
            mode: HermesBackendMode.desktopGateway,
            desktopAuthKind: HermesDesktopAuthKind.nativePkce,
          ),
          _profile(_b, 'Beta', 'https://beta.example'),
        ], active: _a);
        final secrets = _Secrets({
          'hermes_desktop_credentials_v1:$_a': jsonEncode(
            _nativeCredentials('refresh-0').toJson(),
          ),
          'hermes_api_key_v1:$_b': 'beta-key',
        });
        final container = await _ready(secrets);
        addTearDown(container.dispose);
        final controller = container.read(hermesConfigProvider.notifier);
        final write = controller.credentialsWriterFor(
          container.read(hermesConfigProvider),
        );

        await leave(controller);
        await write(_nativeCredentials('refresh-1'));

        final stored = await controller.savedConnectionConfig(_a);
        check(
          stored.desktopCredentials?.nativeTokens?.refreshToken,
        ).equals('refresh-1');
      });
    }

    group('the live Desktop client', () {
      late ProviderContainer container;
      late HermesConfigController controller;

      setUp(() async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example').copyWith(
            mode: HermesBackendMode.desktopGateway,
            desktopAuthKind: HermesDesktopAuthKind.nativePkce,
          ),
          _profile(_b, 'Beta', 'https://beta.example'),
        ], active: _a);
        container = await _ready(
          _Secrets({
            'hermes_desktop_credentials_v1:$_a': jsonEncode(
              _nativeCredentials('refresh-0').toJson(),
            ),
            'hermes_api_key_v1:$_b': 'beta-key',
          }),
        );
        controller = container.read(hermesConfigProvider.notifier);
      });
      tearDown(() => container.dispose());

      HermesDesktopApiService live() =>
          container.read(hermesApiServiceProvider)! as HermesDesktopApiService;
      Future<String?> storedRefreshToken() async =>
          (await controller.savedConnectionConfig(
            _a,
          )).desktopCredentials?.nativeTokens?.refreshToken;

      test('takes the tokens another client rotated', () async {
        final before = live();
        await controller.credentialsWriterFor(
          container.read(hermesConfigProvider),
        )(_nativeCredentials('refresh-1'));

        final after = live();
        check(identical(after, before)).isFalse();
        check(
          after.config.desktopCredentials?.nativeTokens?.refreshToken,
        ).equals('refresh-1');
      });

      test('cannot erase the tokens another client rotated', () async {
        final stale = live();
        await controller.credentialsWriterFor(
          container.read(hermesConfigProvider),
        )(_nativeCredentials('refresh-1'));

        // Its own refresh with the spent token was refused; it signs out.
        await stale.onCredentialsChanged!(HermesDesktopCredentials());

        check(await storedRefreshToken()).equals('refresh-1');
      });

      test('keeps its rotation when it lands after a switch away', () async {
        final client = live();
        await controller.setActiveConnection(_b);

        await client.onCredentialsChanged!(_nativeCredentials('refresh-1'));

        check(await storedRefreshToken()).equals('refresh-1');
      });
    });

    test(
      'a read during a rolled-back save never pairs the new address with '
      'the old secrets',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example'),
          _profile(_b, 'Beta', 'https://beta.example'),
        ], active: _a);
        final secrets = _Secrets({
          'hermes_api_key_v1:$_a': 'alpha-key',
          'hermes_api_key_v1:$_b': 'beta-key',
        });
        // The dashboard sign-out of the old address fails, so the save that
        // moved Beta to another server is undone.
        final cookies = _GatedCookieJar();
        final container = await _ready(secrets, cookies: cookies);
        addTearDown(container.dispose);
        final controller = container.read(hermesConfigProvider.notifier);

        final saving = controller.saveConnection(
          connectionId: _b,
          baseUrl: 'https://gamma.example',
          apiKeyChanged: true,
          apiKey: 'gamma-key',
        );
        await cookies.called.future;

        // An editor opens Beta while it points at the new server.
        final keyRead = Completer<void>();
        secrets.heldReads['hermes_api_key_v1:$_b'] = keyRead.future;
        final opening = controller.savedConnectionConfig(_b);
        await pumpEventQueue();

        // The rollback stops just before Beta's old address is written back.
        final restoring = Completer<void>();
        final restored = Completer<void>();
        PreferencesStore.debugOverride(
          PreferencesStore.instance,
          writeInterceptor: (_, key, value) async {
            if (key == PreferenceKeys.hermesConnections &&
                '$value'.contains('https://beta.example') &&
                !restoring.isCompleted) {
              restoring.complete();
              await restored.future;
            }
            return null;
          },
        );
        cookies.release.complete(false);
        await restoring.future;
        keyRead.complete();
        final opened = await opening;
        restored.complete();
        await check(saving).throws<StateError>();

        // Either consistent pair, or no address while the secrets change:
        // a key paired with the other address would go to the wrong server.
        check((opened.baseUrl, opened.apiKey)).has((pair) => switch (pair) {
          ('https://beta.example', 'beta-key') ||
          ('https://gamma.example', 'gamma-key') ||
          ('', _) => true,
          _ => false,
        }, 'consistent').isTrue();
        check(
          (await controller.savedConnectionConfig(_b)).baseUrl,
        ).equals('https://beta.example');
      },
    );

    test(
      'a read during a save never pairs the old address with new secrets',
      () async {
        _seedConnections([
          _profile(_a, 'Alpha', 'https://alpha.example'),
          _profile(_b, 'Beta', 'https://beta.example'),
        ], active: _a);
        final secrets = _Secrets({
          'hermes_api_key_v1:$_a': 'alpha-key',
          'hermes_api_key_v1:$_b': 'beta-key',
        });
        final container = await _ready(secrets);
        addTearDown(container.dispose);
        final controller = container.read(hermesConfigProvider.notifier);
        final keyRead = Completer<void>();
        secrets.heldReads['hermes_api_key_v1:$_b'] = keyRead.future;

        // An editor opens Beta while a save moves it to another server.
        final opening = controller.savedConnectionConfig(_b);
        await controller.saveConnection(
          connectionId: _b,
          baseUrl: 'https://gamma.example',
          apiKeyChanged: true,
          apiKey: 'gamma-key',
        );
        keyRead.complete();
        final opened = await opening;

        check(opened.baseUrl).equals('https://gamma.example');
        check(opened.apiKey).equals('gamma-key');
      },
    );

    test('a server URL too long to reload is refused', () async {
      _seedConnections([
        _profile(_a, 'Alpha', 'https://alpha.example'),
        _profile(_b, 'Beta', 'https://beta.example'),
      ], active: _a);
      final container = await _ready(
        _Secrets({'hermes_api_key_v1:$_a': 'alpha-key'}),
      );
      addTearDown(container.dispose);
      final controller = container.read(hermesConfigProvider.notifier);
      final document = PreferencesStore.getString(
        PreferenceKeys.hermesConnections,
      );
      final tooLong = 'https://beta.example/${'a' * 2100}';

      await check(
        controller.saveConnection(connectionId: _b, baseUrl: tooLong),
      ).throws<ArgumentError>();
      await check(
        controller.createConnection(baseUrl: tooLong, apiKey: 'key'),
      ).throws<ArgumentError>();

      check(
        PreferencesStore.getString(PreferenceKeys.hermesConnections),
      ).equals(document);
    });

    test('a rename of the active connection keeps its session', () async {
      _seedConnections([
        _profile(_a, 'Alpha', 'https://alpha.example'),
      ], active: _a);
      final container = await _ready(
        _Secrets({'hermes_api_key_v1:$_a': 'alpha-key'}),
      );
      addTearDown(container.dispose);
      container.read(hermesActiveSessionProvider.notifier).set('alpha-session');

      await container
          .read(hermesConfigProvider.notifier)
          .saveConnection(baseUrl: 'https://alpha.example', name: 'Renamed');

      check(container.read(hermesConfigProvider).name).equals('Renamed');
      check(container.read(hermesActiveSessionProvider))
          .equals('alpha-session');
      check(
        container
            .read(hermesConfigProvider.notifier)
            .documentTrustPrincipalId(),
      ).equals(_principalFor(_a));
    });

    test('the first saved connection becomes active', () async {
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
      final container = await _ready(_Secrets());
      addTearDown(container.dispose);

      await container
          .read(hermesConfigProvider.notifier)
          .saveConnection(
            baseUrl: 'https://first.example',
            apiKeyChanged: true,
            apiKey: 'first-key',
          );

      final config = container.read(hermesConfigProvider);
      check(config.connectionId).isNotNull();
      check(config.name).equals('first.example');
      check(config.apiKey).equals('first-key');
      check(HermesConnectionStore.readActiveId()).equals(config.connectionId);
    });

    test('two new connections saved back to back are both kept', () async {
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
      final secrets = _Secrets();
      final container = await _ready(secrets);
      addTearDown(container.dispose);
      final gateway = container.read(hermesConnectionGatewayProvider);
      HermesConnectionDraft draft(String host) => HermesConnectionDraft(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://$host.example',
          apiKey: '$host-key',
        ),
        apiKeyChanged: true,
        sessionKeyChanged: true,
        desktopCredentialsChanged: true,
      );

      // Two editors save new connections before the first save has run, as
      // with slow storage.
      final [firstId, secondId] = await Future.wait([
        gateway.persist(draft('first')),
        gateway.persist(draft('second')),
      ]);

      check(
        container.read(hermesConnectionsProvider).map((profile) => profile.id),
      ).deepEquals([firstId, secondId]);
      final config = container.read(hermesConfigProvider);
      check(config.connectionId).equals(firstId);
      check(config.baseUrl).equals('https://first.example');
      check(config.apiKey).equals('first-key');
      check(await secrets.read(key: 'hermes_api_key_v1:$secondId'))
          .equals('second-key');
    });

    test('a save without an active connection respects the limit', () async {
      // The active id names a profile that was never written, as after a
      // process kill while the first save of that connection committed.
      _seedConnections([
        for (var i = 0; i < kMaxHermesConnections; i++)
          _profile(
            '${'$i'.padLeft(8, '0')}-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'Agent $i',
            'https://agent$i.example',
          ),
      ], active: _c);
      final container = await _ready(_Secrets());
      addTearDown(container.dispose);
      check(container.read(hermesConfigProvider).connectionId).isNull();
      final document = PreferencesStore.getString(
        PreferenceKeys.hermesConnections,
      );

      await check(
        container
            .read(hermesConfigProvider.notifier)
            .saveConnection(
              baseUrl: 'https://extra.example',
              apiKeyChanged: true,
              apiKey: 'extra-key',
            ),
      ).throws<StateError>();

      check(
        container.read(hermesConnectionsProvider),
      ).length.equals(kMaxHermesConnections);
      check(
        PreferencesStore.getString(PreferenceKeys.hermesConnections),
      ).equals(document);
      check(HermesConnectionStore.readActiveId()).equals(_c);
      check(container.read(hermesConfigProvider).connectionId).isNull();
    });
  });

  test(
    'a name lookup after a test keeps the sign-in the test refreshed',
    () async {
      // Each refresh spends the refresh token it replaces.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final spent = <String>{};
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/api/status':
            request.response.write('{"auth_required":true}');
          case '/auth/native/refresh':
            final body = jsonDecode(await utf8.decodeStream(request)) as Map;
            final refreshToken = body['refresh_token'] as String;
            if (spent.add(refreshToken)) {
              request.response.write(
                jsonEncode({
                  'access_token': 'access-$refreshToken-next',
                  'refresh_token': '$refreshToken-next',
                  'expires_at':
                      DateTime.utc(2100).millisecondsSinceEpoch ~/ 1000,
                }),
              );
            } else {
              request.response.statusCode = HttpStatus.unauthorized;
            }
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      _seedConnections(
        [
          _profile(_a, 'Alpha', 'http://127.0.0.1:${server.port}').copyWith(
            mode: HermesBackendMode.desktopGateway,
            desktopAuthKind: HermesDesktopAuthKind.nativePkce,
          ),
        ],
        active: _a,
        enabled: false,
      );
      final secrets = _Secrets({
        'hermes_desktop_credentials_v1:$_a': jsonEncode(
          HermesDesktopCredentials(
            nativeTokens: HermesDesktopTokenSet(
              accessToken: 'access-refresh-0',
              refreshToken: 'refresh-0',
              expiresAt: DateTime.utc(2020),
            ),
          ).toJson(),
        ),
      });
      final container = await _ready(secrets);
      addTearDown(container.dispose);
      final gateway = container.read(hermesConnectionGatewayProvider);
      // With Hermes off there is no live client, so the test and the name
      // lookup each build one from the same draft and its expired tokens.
      final draft = container.read(hermesConfigProvider);

      await gateway.probe(draft);
      await gateway.suggestDisplayName(draft);

      check(
        container
            .read(hermesConfigProvider)
            .desktopCredentials
            ?.nativeTokens
            ?.refreshToken,
      ).equals('refresh-0-next');
      final stored = HermesDesktopCredentials.fromJson(
        jsonDecode(
          (await secrets.read(key: 'hermes_desktop_credentials_v1:$_a'))!,
        ),
      );
      check(stored.nativeTokens?.refreshToken).equals('refresh-0-next');
    },
  );

  test('maps a session identity back to its saved connection', () async {
    _seedConnections([
      _profile(_a, 'Alpha', 'https://alpha.example'),
      _profile(_b, 'Beta', 'https://beta.example/v1'),
    ], active: _a);
    final container = await _ready(_Secrets());
    addTearDown(container.dispose);
    final controller = container.read(hermesConfigProvider.notifier);

    check(
      controller
          .connectionForIdentity(_identityFor(_b, 'https://beta.example/v1'))
          ?.id,
    ).equals(_b);
    check(
      controller.connectionForIdentity(
        _identityFor(_c, 'https://beta.example/v1'),
      ),
    ).isNull();
  });
}

HermesDesktopCredentials _nativeCredentials(String refreshToken) =>
    HermesDesktopCredentials(
      nativeTokens: HermesDesktopTokenSet(
        accessToken: 'access-$refreshToken',
        refreshToken: refreshToken,
        expiresAt: DateTime.utc(2100),
      ),
    );

String _principalFor(String id) =>
    '${id.substring(0, 8)}-0000-4000-8000-000000000000';

HermesConnectionProfile _profile(
  String id,
  String name,
  String baseUrl, {
  DateTime? lastUsedAt,
}) => HermesConnectionProfile(
  id: id,
  name: name,
  nameSource: HermesConnectionNameSource.user,
  baseUrl: baseUrl,
  documentTrustPrincipalId: _principalFor(id),
  lastUsedAt: lastUsedAt,
);

void _seedConnections(
  List<HermesConnectionProfile> profiles, {
  required String active,
  bool enabled = true,
}) {
  PreferencesStore.debugOverride(
    InMemoryKeyValueStore(<String, Object?>{
      PreferenceKeys.hermesEnabled: enabled,
      PreferenceKeys.hermesConnections: HermesConnectionsDocument(
        connections: profiles,
      ).encode(),
      PreferenceKeys.hermesActiveConnectionId: active,
    }),
  );
}

String _identityFor(String id, String baseUrl) =>
    HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: HermesConfig.connectionEndpoint(baseUrl)!,
      principalId: _principalFor(id),
    );

const _envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_1>>>notes';

Future<void> _rememberDocumentTrust(String connectionIdentity) =>
    HermesLocalDocumentTrustStore.remember(
      connectionIdentity: connectionIdentity,
      sessionId: 'session',
      messageId: 'message',
      promptText: 'Summarize\n\n$_envelope',
      documentEnvelopes: const [_envelope],
    );

final _storageAccount =
    HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
      serverId: 'server',
      userId: 'user',
      tokenFingerprint: 'fingerprint',
    );

Future<void> _rememberSessionBinding(String connectionIdentity) =>
    HermesMixedSessionBindingTrustStore.remember(
      storageAccountIdentity: _storageAccount,
      conversationId: 'chat',
      assistantMessageId: 'assistant',
      sessionId: 'session',
      connectionIdentity: connectionIdentity,
    );

bool _sessionBindingTrusted(String connectionIdentity) =>
    HermesMixedSessionBindingTrustStore.trusts(
      storageAccountIdentity: _storageAccount,
      conversationId: 'chat',
      assistantMessageId: 'assistant',
      sessionId: 'session',
      connectionIdentity: connectionIdentity,
    );

Future<ProviderContainer> _ready(
  SecureKeyValueStore secrets, {
  CookieJarPort cookies = const NullCookieJarPort(),
}) async {
  final container = ProviderContainer(
    overrides: [
      secureStorageProvider.overrideWithValue(secrets),
      cookieJarProvider.overrideWithValue(cookies),
    ],
  );
  container.read(hermesConfigProvider);
  for (
    var i = 0;
    i < 100 && container.read(hermesSecretsLoadingProvider);
    i++
  ) {
    await Future<void>.delayed(Duration.zero);
  }
  check(container.read(hermesSecretsLoadingProvider)).isFalse();
  return container;
}

/// Secure storage that can fail, drop, or refuse reads by key prefix.
final class _Secrets extends InMemorySecureKeyValueStore {
  _Secrets([super.seed]);

  /// Each matching write throws once.
  final Set<String> failWritePrefixes = <String>{};

  /// Matching writes report success without storing anything.
  final Set<String> dropWritePrefixes = <String>{};

  final Set<String> failReadPrefixes = <String>{};

  /// The next read of each of these exact keys waits for its future.
  final Map<String, Future<void>> heldReads = <String, Future<void>>{};

  @override
  Future<String?> read({required String key}) async {
    if (failReadPrefixes.any(key.startsWith)) {
      throw StateError('secure storage unavailable');
    }
    await heldReads.remove(key);
    return super.read(key: key);
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    final failing = failWritePrefixes.where(key.startsWith).firstOrNull;
    if (failing != null) {
      failWritePrefixes.remove(failing);
      throw StateError('write failed');
    }
    if (dropWritePrefixes.any(key.startsWith)) return;
    await super.write(key: key, value: value);
  }
}

final class _RecordingCookieJar extends NullCookieJarPort {
  _RecordingCookieJar({this.clears = true});

  /// What [clearForOrigin] reports.
  final bool clears;
  final List<String> clearedOrigins = <String>[];

  @override
  Future<bool> clearForOrigin(String origin) async {
    clearedOrigins.add(origin);
    return clears;
  }
}

final class _GatedCookieJar extends NullCookieJarPort {
  final Completer<void> called = Completer<void>();

  /// What [clearForOrigin] reports, once it is completed.
  final Completer<bool> release = Completer<bool>();

  @override
  Future<bool> clearForOrigin(String origin) {
    if (!called.isCompleted) called.complete();
    return release.future;
  }
}
