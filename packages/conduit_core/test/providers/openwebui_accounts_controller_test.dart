import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _Storage implements OptimizedStorageService {
  @override
  Future<String?> getEffectiveActiveServerId() async => 'a';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

final class _Auth extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  @override
  Future<bool> signOutAccount(String accountId, {String? thenActivate}) async =>
      false;
}

final class _Hermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

/// Signs out of the only account, with Direct profiles still loading
/// synchronously and resolving to [direct] once awaited.
Future<PreferredBackend> _signOutOfLastAccount(
  Future<List<DirectConnectionProfile>> Function() direct,
) async {
  final container = ProviderContainer(
    overrides: [
      optimizedStorageServiceProvider.overrideWithValue(_Storage()),
      authStateManagerProvider.overrideWith(_Auth.new),
      hermesConfigProvider.overrideWith(_Hermes.new),
      openWebUiAccountsProvider.overrideWith((ref) async => const []),
      accountChangeReplyGuardProvider.overrideWithValue(() => false),
      effectiveDirectConnectionProfilesProvider.overrideWithValue(
        const AsyncLoading(),
      ),
      effectiveDirectConnectionProfilesFutureProvider.overrideWith(
        (ref) => direct(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await container.read(openWebUiAccountsControllerProvider).signOut('a');
  return container.read(preferredBackendProvider);
}

void main() {
  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
  });

  tearDown(PreferencesStore.debugReset);

  test(
    'signing out of the last account waits for Direct profiles still loading',
    () async {
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example/v1',
      );
      check(profile.isUsable).isTrue();

      check(await _signOutOfLastAccount(() async => [profile]))
          .equals(PreferredBackend.direct);
    },
  );

  test('Direct profiles that fail to load count as no Direct', () async {
    check(await _signOutOfLastAccount(() async => throw StateError('locked')))
        .equals(PreferredBackend.unset);
  });
}
