import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
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
  });

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
}) {
  PreferencesStore.debugOverride(
    InMemoryKeyValueStore(<String, Object?>{
      PreferenceKeys.hermesEnabled: true,
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

  @override
  Future<String?> read({required String key}) {
    if (failReadPrefixes.any(key.startsWith)) {
      throw StateError('secure storage unavailable');
    }
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
  _RecordingCookieJar();

  final List<String> clearedOrigins = <String>[];

  @override
  Future<bool> clearForOrigin(String origin) async {
    clearedOrigins.add(origin);
    return true;
  }
}
