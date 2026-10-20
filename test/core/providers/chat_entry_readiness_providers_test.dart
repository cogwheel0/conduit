import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FixedPreferredBackend extends PreferredBackendController {
  _FixedPreferredBackend(this._backend);

  final PreferredBackend _backend;

  @override
  PreferredBackend build() => _backend;
}

final class _FixedHermesConfig extends HermesConfigController {
  _FixedHermesConfig(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

final _usableDirectProfile = DirectConnectionProfile(
  id: 'direct-profile',
  name: 'Local Ollama',
  adapterKey: 'ollama',
  baseUrl: 'http://localhost:11434',
  manualModelIds: const ['llama3'],
);

const _usableHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'hermes-key',
);

final _refProvider = Provider<Ref>((ref) => ref);

final class _MutableDirectProfiles
    extends Notifier<AsyncValue<List<DirectConnectionProfile>>> {
  @override
  AsyncValue<List<DirectConnectionProfile>> build() =>
      const AsyncValue.loading();

  void publish(AsyncValue<List<DirectConnectionProfile>> next) => state = next;
}

final _mutableDirectProfilesProvider =
    NotifierProvider<
      _MutableDirectProfiles,
      AsyncValue<List<DirectConnectionProfile>>
    >(_MutableDirectProfiles.new);

ProviderContainer _container({
  required PreferredBackend backend,
  AuthNavigationState auth = AuthNavigationState.needsLogin,
  AsyncValue<List<DirectConnectionProfile>> directProfiles =
      const AsyncValue.data(<DirectConnectionProfile>[]),
  HermesConfig hermes = const HermesConfig(),
}) {
  final container = ProviderContainer(
    overrides: [
      authNavigationStateProvider.overrideWithValue(auth),
      preferredBackendProvider.overrideWith(
        () => _FixedPreferredBackend(backend),
      ),
      effectiveDirectConnectionProfilesProvider.overrideWithValue(
        directProfiles,
      ),
      hermesConfigProvider.overrideWith(() => _FixedHermesConfig(hermes)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('signed-out Direct-only installs are chat-ready', () {
    final container = _container(
      backend: PreferredBackend.direct,
      directProfiles: AsyncValue.data([_usableDirectProfile]),
    );

    check(container.read(chatEntryReadyProvider)).isTrue();
  });

  test('signed-out Hermes-only installs are chat-ready', () {
    final container = _container(
      backend: PreferredBackend.hermes,
      hermes: _usableHermes,
    );

    check(container.read(chatEntryReadyProvider)).isTrue();
  });

  test('Direct profiles that are still loading are not chat-ready', () {
    final container = _container(
      backend: PreferredBackend.direct,
      directProfiles: const AsyncValue.loading(),
    );

    check(container.read(chatEntryReadyProvider)).isFalse();
  });

  test('an Open WebUI install still waits for sign-in', () {
    final container = _container(
      backend: PreferredBackend.owui,
      directProfiles: AsyncValue.data([_usableDirectProfile]),
      hermes: _usableHermes,
    );

    check(container.read(chatEntryReadyProvider)).isFalse();
  });

  test('an authenticated Open WebUI session is chat-ready', () {
    final container = _container(
      backend: PreferredBackend.owui,
      auth: AuthNavigationState.authenticated,
    );

    check(container.read(chatEntryReadyProvider)).isTrue();
  });

  test('a cold launch waits for Direct profiles to finish loading', () async {
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.needsLogin,
        ),
        preferredBackendProvider.overrideWith(
          () => _FixedPreferredBackend(PreferredBackend.direct),
        ),
        effectiveDirectConnectionProfilesProvider.overrideWith(
          (ref) => ref.watch(_mutableDirectProfilesProvider),
        ),
        hermesConfigProvider.overrideWith(
          () => _FixedHermesConfig(const HermesConfig()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final ready = waitForChatEntryReady(
      container.read(_refProvider),
      pollInterval: const Duration(milliseconds: 5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    container
        .read(_mutableDirectProfilesProvider.notifier)
        .publish(AsyncValue.data([_usableDirectProfile]));

    check(await ready).isTrue();
  });

  test('a signed-out Open WebUI install does not wait', () async {
    final container = _container(backend: PreferredBackend.owui);

    final started = DateTime.now();
    final ready = await waitForChatEntryReady(container.read(_refProvider));

    check(ready).isFalse();
    check(DateTime.now().difference(started))
        .isLessThan(const Duration(seconds: 1));
  });
}
