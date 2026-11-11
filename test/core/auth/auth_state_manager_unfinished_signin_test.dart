import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
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
  setUpAll(() {
    registerFallbackValue(
      const User(
        id: 'fallback',
        username: 'f',
        email: 'f@example.test',
        role: 'user',
      ),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.activeServerId: 'account-a',
    });
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });

  tearDown(PreferencesStore.debugReset);

  for (final (step, message) in [
    ('verify', 'twoStepVerificationRequired'),
    ('enroll', 'twoStepVerificationRequired'),
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

  test('a password sign-in stops at the second step, and its code signs in '
      'with what the sign-in was asked to remember', () async {
    final storage = _CommittingStorage();
    when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => null);
    when(() => storage.getSavedCredentialsStrict())
        .thenAnswer((_) async => null);
    when(() => storage.getActiveServerId())
        .thenAnswer((_) async => 'account-a');
    when(() => storage.getEffectiveActiveServerId())
        .thenAnswer((_) async => 'account-a');
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    final workerManager = WorkerManager();
    addTearDown(workerManager.dispose);
    final api = _ChallengingApi(workerManager, 'verify');

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) async => _server),
      ],
    );
    addTearDown(container.dispose);
    await _settledAuth(container);
    final auth = container.read(authStateManagerProvider.notifier);

    OpenWebUiTwoStepChallenge? challenge;
    try {
      await auth.login('a@example.test', 'pw', rememberCredentials: true);
    } on OpenWebUiTwoStepRequired catch (e) {
      challenge = e.challenge;
    }

    check(challenge).isNotNull().has((c) => c.kind, 'kind').equals(
      OpenWebUiTwoStepKind.verify,
    );
    var state = container.read(authStateManagerProvider).requireValue;
    check(state.status).equals(AuthStatus.unauthenticated);
    check(state.error).isNull();
    check(state.isLoading).isFalse();
    check(storage.committedToken).isNull();

    final session = await auth.submitTwoStepCode(challenge!, ' 123456 ');
    check(api.verified).deepEquals([
      ('user-a.challenge-token-value', '123456', false),
    ]);

    // A session the server then refuses is not a wrong password.
    api.rejectsSession = true;
    await check(auth.finishTwoStepSignIn(session)).throws<Exception>();
    state = container.read(authStateManagerProvider).requireValue;
    check(state.status).equals(AuthStatus.error);
    check(state.error).equals('twoStepSessionRejected');
    check(storage.committedToken).isNull();

    // The step is kept for another try.
    api.rejectsSession = false;
    check(await auth.finishTwoStepSignIn(session)).isTrue();
    state = container.read(authStateManagerProvider).requireValue;
    check(state.status).equals(AuthStatus.authenticated);
    check(state.token).equals(_issuedToken);
    check(storage.committedToken).equals(_issuedToken);
    check(storage.remembered).isNotNull().deepEquals({
      'serverId': 'account-a',
      'username': 'a@example.test',
      'password': 'pw',
      'authType': 'credentials',
    });
  });
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

/// Storage that owns the server and commits whatever session it is given.
final class _CommittingStorage extends _Storage {
  String? committedToken;
  Map<String, String>? remembered;

  @override
  Future<ServerSessionOwnershipSnapshot?> captureServerSessionOwnership({
    required ServerConfig validatedConfig,
    required bool requireActive,
  }) async => (
    revision: 1,
    serverConfig: validatedConfig,
    requireActive: requireActive,
  );

  @override
  Future<bool> commitExistingServerSession({
    required ServerSessionOwnershipSnapshot ownership,
    required String token,
    required bool Function() canCommit,
    required FutureOr<void> Function() publish,
    Map<String, String>? rememberedCredentials,
    Map<String, String>? expectedSavedCredentials,
    void Function()? onRollbackUncertain,
  }) async {
    if (!canCommit()) return false;
    committedToken = token;
    remembered = rememberedCredentials;
    await publish();
    return true;
  }
}

// Shaped like a JWT so the token format check accepts it.
const _issuedToken =
    'eyJhbGciOiJIUzI1NiJ9.eyJpZCI6ImEifQ.signature-for-account-a';

/// A server whose sign-in answers with [step] instead of a session.
final class _ChallengingApi extends ApiService {
  _ChallengingApi(WorkerManager workerManager, this.step)
    : super(workerManager: workerManager, serverConfig: _server);

  final String step;
  int logins = 0;
  final verified = <(String, String, bool)>[];

  /// Whether the session endpoint refuses the session a code issued.
  bool rejectsSession = false;

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

  @override
  Future<OpenWebUiTwoStepSession> verifyTwoStepCode(
    String challengeToken,
    String code, {
    bool recovery = false,
  }) async {
    verified.add((challengeToken, code, recovery));
    return const OpenWebUiTwoStepSession(token: _issuedToken);
  }

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    if (rejectsSession) {
      final options = RequestOptions(path: '/api/v1/auths/');
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 401),
        type: DioExceptionType.badResponse,
      );
    }
    return const User(
      id: 'user-a',
      username: 'a',
      email: 'a@example.test',
      role: 'user',
    );
  }
}
