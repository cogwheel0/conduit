import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart'
    show recheckActiveAccountSession;
import 'package:conduit_core/auth/api_auth_interceptor.dart' show ApiAuthSnapshot;
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An account's client whose server refuses the session check once the
/// test lets it answer.
final class _RefusingApi extends ApiService {
  _RefusingApi({required String accountId, required this.token})
    : super(
        serverConfig: ServerConfig(
          id: accountId,
          name: accountId,
          url: 'https://$accountId.test',
        ),
        workerManager: WorkerManager(),
      );

  final String token;
  final Completer<void> answer = Completer<void>();

  @override
  String? get authToken => token;

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    await answer.future;
    final request = RequestOptions(path: '/api/v1/auths/');
    throw DioException(
      requestOptions: request,
      response: Response<Object?>(requestOptions: request, statusCode: 401),
    );
  }
}

/// The client in use, which a switch or a sign-in replaces.
final class _CurrentApi extends Notifier<ApiService?> {
  _CurrentApi(this._initial);

  final ApiService _initial;

  @override
  ApiService? build() => _initial;

  void replace(ApiService? api) => state = api;
}

final class _SpyAuth extends AuthStateManager {
  int invalidations = 0;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'token-a');

  @override
  Future<void> onTokenInvalidated() async => invalidations++;

  /// A sign-out or a sign-in finishing.
  void publish(AuthState next) => state = AsyncData(next);
}

void main() {
  late _RefusingApi asked;
  late _SpyAuth auth;
  late ProviderContainer container;
  late NotifierProvider<_CurrentApi, ApiService?> currentApi;

  setUp(() async {
    asked = _RefusingApi(accountId: 'acct-1', token: 'token-a');
    auth = _SpyAuth();
    currentApi = NotifierProvider<_CurrentApi, ApiService?>(
      () => _CurrentApi(asked),
    );
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => ref.watch(currentApi)),
        authStateManagerProvider.overrideWith(() => auth),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
  });

  test('a session its server refuses goes to sign in again', () async {
    final checking = recheckActiveAccountSession(container);
    asked.answer.complete();

    check(await checking).isFalse();
    check(auth.invalidations).equals(1);
  });

  test('a refusal after switching accounts leaves the new one be', () async {
    final checking = recheckActiveAccountSession(container);
    container
        .read(currentApi.notifier)
        .replace(_RefusingApi(accountId: 'acct-2', token: 'token-b'));
    asked.answer.complete();

    check(await checking).isTrue();
    check(auth.invalidations).equals(0);
  });

  test('a refusal after signing in again leaves the new session be', () async {
    final checking = recheckActiveAccountSession(container);
    container
        .read(currentApi.notifier)
        .replace(_RefusingApi(accountId: 'acct-1', token: 'token-c'));
    asked.answer.complete();

    check(await checking).isTrue();
    check(auth.invalidations).equals(0);
  });

  test('a refusal after signing out and in with the same key leaves it be', () async {
    final checking = recheckActiveAccountSession(container);
    // An API key signs in with the same token every time.
    auth.publish(const AuthState(status: AuthStatus.unauthenticated));
    container
        .read(currentApi.notifier)
        .replace(_RefusingApi(accountId: 'acct-1', token: 'token-a'));
    await Future<void>.delayed(Duration.zero);
    auth.publish(
      const AuthState(status: AuthStatus.authenticated, token: 'token-a'),
    );
    asked.answer.complete();

    check(await checking).isTrue();
    check(auth.invalidations).equals(0);
  });
}
