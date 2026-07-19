import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _passwordSecret = 'foreground-password-secret';
const _tokenSecret = 'foreground-token-secret-long-enough';
const _responseSecret = 'provider-reflected-auth-secret';
const _headerSecret = 'provider-reflected-header-secret';
const _uriSecret = 'provider-reflected-uri-secret';
const _ldapDiagnosticSecret = 'ldap-upstream-diagnostic-secret';

void main() {
  setUpAll(() {
    registerFallbackValue(() => true);
    registerFallbackValue(
      const ServerConfig(
        id: 'fallback',
        name: 'Fallback',
        url: 'https://fallback.test',
      ),
    );
  });

  test(
    'foreground auth flows never publish, throw, or log reflected secrets',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      addTearDown(PreferencesStore.debugReset);

      final captured = StringBuffer();
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) captured.writeln(message);
      };

      try {
        for (final mode in _AuthMode.values) {
          final storage = _Storage();
          when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
          when(
            () => storage.getSavedCredentialsStrict(),
          ).thenAnswer((_) async => null);
          when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
          when(() => storage.clearAuthData()).thenAnswer((_) async {});
          when(
            () => storage.clearAuthDataIf(canClear: any(named: 'canClear')),
          ).thenAnswer((invocation) async {
            final canClear =
                invocation.namedArguments[#canClear] as bool Function();
            if (!canClear()) return false;
            await storage.clearAuthData();
            return true;
          });

          final api = _ReflectingAuthApi(mode);
          _stubOwnershipCapture(storage, api.serverConfig);
          final container = ProviderContainer(
            overrides: [
              apiServiceProvider.overrideWithValue(api),
              optimizedStorageServiceProvider.overrideWithValue(storage),
            ],
          );
          try {
            await container.read(authStateManagerProvider.future);
            final notifier = container.read(authStateManagerProvider.notifier);

            Object? thrown;
            try {
              switch (mode) {
                case _AuthMode.password:
                  await notifier.login('person@example.test', _passwordSecret);
                  break;
                case _AuthMode.token:
                  await notifier.loginWithApiKey(_tokenSecret);
                  break;
                case _AuthMode.ldap:
                  await notifier.ldapLogin('directory-user', _passwordSecret);
                  break;
              }
            } catch (error) {
              thrown = error;
            }

            check(thrown).isNotNull();
            final auth = container.read(authStateManagerProvider).requireValue;
            check(auth.status).equals(AuthStatus.error);
            check(auth.error).isNotNull();

            final visible = '${thrown.toString()}\n${auth.error}';
            for (final secret in const [
              _passwordSecret,
              _tokenSecret,
              _responseSecret,
              _headerSecret,
              _uriSecret,
            ]) {
              check(visible).not((value) => value.contains(secret));
            }

            await notifier.logout();
            check(
              container.read(authStateManagerProvider).requireValue.status,
            ).equals(AuthStatus.unauthenticated);
          } finally {
            container.dispose();
          }
        }
      } finally {
        debugPrint = previousDebugPrint;
      }

      final logs = captured.toString();
      check(logs).contains('api-key-login-failed');
      check(logs).contains('login-failed');
      check(logs).contains('ldap-login-failed');
      check(logs).contains('server-logout-failed');
      check(logs).contains('stack=');
      for (final secret in const [
        _passwordSecret,
        _tokenSecret,
        _responseSecret,
        _headerSecret,
        _uriSecret,
      ]) {
        check(logs).not((value) => value.contains(secret));
      }
    },
  );

  test(
    'background stored-token validation never logs reflected secrets',
    () async {
      final storage = _Storage();
      when(
        () => storage.getAuthTokenStrict(),
      ).thenAnswer((_) async => _tokenSecret);
      when(
        () => storage.getLocalUserWithAvatar(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});

      final api = _ReflectingAuthApi(_AuthMode.token);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      final previousDebugPrint = debugPrint;
      final captured = StringBuffer();
      debugPrint = (message, {wrapWidth}) {
        if (message != null) captured.writeln(message);
      };

      try {
        await container.read(authStateManagerProvider.future);
        for (var attempt = 0; attempt < 100; attempt++) {
          if (captured.toString().contains(
            'background-auth-validation-deferred',
          )) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } finally {
        debugPrint = previousDebugPrint;
      }

      final auth = container.read(authStateManagerProvider).requireValue;
      check(auth.status).equals(AuthStatus.unauthenticated);
      check(auth.error).equals('Sign in again to load your account');
      final visible = '${captured.toString()}\n${auth.error}';
      check(visible).contains('background-auth-validation-deferred');
      for (final secret in const [
        _passwordSecret,
        _tokenSecret,
        _responseSecret,
        _headerSecret,
        _uriSecret,
      ]) {
        check(visible).not((value) => value.contains(secret));
      }
    },
  );

  test(
    'LDAP-disabled 400 publishes only the recognized safe message',
    () async {
      final storage = _Storage();
      when(() => storage.getAuthTokenStrict()).thenAnswer((_) async => '');
      when(
        () => storage.getSavedCredentialsStrict(),
      ).thenAnswer((_) async => null);
      when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
      final api = _LdapDisabledAuthApi();
      _stubOwnershipCapture(storage, api.serverConfig);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);

      Object? thrown;
      try {
        await container
            .read(authStateManagerProvider.notifier)
            .ldapLogin('directory-user', _passwordSecret);
      } catch (error) {
        thrown = error;
      }

      check(thrown).isNotNull();
      check(
        thrown.toString(),
      ).equals('Exception: LDAP authentication is not enabled');
      final auth = container.read(authStateManagerProvider).requireValue;
      check(auth.status).equals(AuthStatus.error);
      check(auth.error).equals('LDAP authentication is not enabled');
      final visible = '${thrown.toString()}\n${auth.error}';
      check(visible).not((value) => value.contains(_passwordSecret));
      check(visible).not((value) => value.contains(_ldapDiagnosticSecret));
    },
  );
}

void _stubOwnershipCapture(
  OptimizedStorageService storage,
  ServerConfig config,
) {
  when(
    () => storage.captureServerSessionOwnership(
      validatedConfig: any(named: 'validatedConfig'),
      requireActive: true,
    ),
  ).thenAnswer(
    (_) async => (revision: 1, serverConfig: config, requireActive: true),
  );
}

enum _AuthMode { password, token, ldap }

final class _Storage extends Mock implements OptimizedStorageService {}

final class _ReflectingAuthApi extends ApiService {
  _ReflectingAuthApi(this.mode)
    : super(
        serverConfig: const ServerConfig(
          id: 'auth-error-test',
          name: 'Auth error test',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  final _AuthMode mode;

  DioException get _reflectedFailure {
    final request = RequestOptions(
      path: 'https://example.test/$_uriSecret?secret=$_uriSecret',
      headers: const {'x-reflected': _headerSecret},
      data: const {'password': _passwordSecret, 'token': _tokenSecret},
    );
    return DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      message: _responseSecret,
      response: Response<Object?>(
        requestOptions: request,
        statusCode: mode == _AuthMode.token ? 500 : 400,
        data: const {'detail': _responseSecret},
        headers: Headers.fromMap(const {
          'location': [_headerSecret],
        }),
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> login(String username, String password) async {
    throw _reflectedFailure;
  }

  @override
  Future<Map<String, dynamic>> ldapLogin(
    String username,
    String password,
  ) async {
    throw _reflectedFailure;
  }

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) {
    throw _reflectedFailure;
  }

  @override
  Future<bool> checkHealth() async => true;

  @override
  Future<void> logout({ApiAuthSnapshot? authSnapshot}) async {
    throw _reflectedFailure;
  }
}

final class _LdapDisabledAuthApi extends ApiService {
  _LdapDisabledAuthApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'ldap-disabled-test',
          name: 'LDAP disabled test',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  @override
  Future<Map<String, dynamic>> ldapLogin(
    String username,
    String password,
  ) async {
    final request = RequestOptions(
      path: 'https://example.test/api/v1/auths/ldap',
      data: {'user': username, 'password': password},
    );
    throw DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      message: _ldapDiagnosticSecret,
      response: Response<Object?>(
        requestOptions: request,
        statusCode: 400,
        data: const {
          'detail': 'LDAP authentication is not enabled',
          'diagnostic': _ldapDiagnosticSecret,
        },
      ),
    );
  }
}
