import 'package:checks/checks.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = ServerConfig(
  id: 'account-a',
  name: 'A',
  url: 'https://a.example',
);

const _saved = <String, String>{
  'serverId': 'account-a',
  'username': 'a@example.test',
  'password': 'saved-password',
  'authType': 'credentials',
};

/// Open WebUI 0.12 answers a sign-in with a `next_step` and no session when
/// the account must finish two-step verification, or awaits approval with it
/// on. Signing in again with the saved password on launch must stop on the
/// sign-in page with the reason, once, rather than retry or fail silently.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.activeServerId: 'account-a',
    });
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });

  tearDown(PreferencesStore.debugReset);

  for (final (step, message) in [
    ('verify', 'twoStepVerificationUnsupported'),
    ('enroll', 'twoStepVerificationUnsupported'),
    ('pending', 'accountPendingApproval'),
  ]) {
    test('a saved sign-in answered with next_step $step ends on sign-in', () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => null);
      when(() => storage.getSavedCredentialsStrict())
          .thenAnswer((_) async => _saved);
      when(() => storage.getActiveServerId())
          .thenAnswer((_) async => 'account-a');
      when(() => storage.getEffectiveActiveServerId())
          .thenAnswer((_) async => 'account-a');
      when(() => storage.captureSavedServerSessionOwnership('account-a'))
          .thenAnswer(
            (_) async =>
                (revision: 1, serverConfig: _server, requireActive: false),
          );
      when(() => storage.deleteSavedCredentialsIfMatches(_saved))
          .thenAnswer((_) async => true);
      when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _ChallengingApi(workerManager, step);

      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          apiServiceProvider.overrideWithValue(null),
          activeServerProvider.overrideWith((ref) async => null),
          savedCredentialAuthApiFactoryProvider.overrideWithValue(
            ({required serverConfig, required workerManager}) => api,
          ),
        ],
      );
      addTearDown(container.dispose);

      final auth = await _settledAuth(container);

      check(auth.status).equals(AuthStatus.credentialError);
      check(auth.error).equals(message);
      check(auth.token).isNull();
      check(api.logins).equals(1);
      // The password can no longer sign in from Conduit, and each try counts
      // toward the account's sign-in limit, so exactly what was tried goes.
      verify(() => storage.deleteSavedCredentialsIfMatches(_saved)).called(1);
      verifyNever(() => storage.deleteSavedCredentials());
    });
  }
}

/// The auth state once its first restore, and the background sign-in it
/// starts, have finished.
Future<AuthState> _settledAuth(ProviderContainer container) async {
  await container.read(authStateManagerProvider.future);
  for (var i = 0; i < 200; i++) {
    final auth = container.read(authStateManagerProvider).requireValue;
    if (!auth.isLoading && auth.status != AuthStatus.loading) return auth;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return container.read(authStateManagerProvider).requireValue;
}

final class _Storage extends Mock implements OptimizedStorageService {}

/// A server whose sign-in answers with [step] instead of a session.
final class _ChallengingApi extends ApiService {
  _ChallengingApi(WorkerManager workerManager, this.step)
    : super(workerManager: workerManager, serverConfig: _server);

  final String step;
  int logins = 0;

  @override
  Future<Map<String, dynamic>> login(String username, String password) async {
    logins++;
    return step == 'pending'
        ? {'next_step': 'pending'}
        : {
            'next_step': step,
            'challenge_token': 'user-a.challenge-token-value',
            'expires_in': 300,
          };
  }
}
