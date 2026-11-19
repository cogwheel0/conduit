@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// `auth.*` over a manager whose server answers are held by the test.
///
/// A two-step sign-in is one attempt: an answer that comes back after the
/// attempt was cancelled, replaced by another sign-in or moved on to
/// another step finishes nothing. The connection issue's Retry signs back in
/// only once the server takes the kept session.
void main() {
  late _Manager manager;
  late ProviderContainer container;
  late AuthService auth;

  setUp(() async {
    manager = _Manager();
    container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(() => manager),
        activeServerProvider.overrideWith((ref) async => null),
        reviewerModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    auth = AuthService(container);
  });

  Future<void> signIn(OpenWebUiTwoStepKind kind) async {
    manager.next = kind;
    final snapshot = await auth.loginWithPassword(
      const PasswordLogin(username: 'robin', password: 'tide-tables'),
    );
    check(snapshot.twoStep).isNotNull();
  }

  test('a code checked after Cancel signs nobody in', () async {
    await signIn(OpenWebUiTwoStepKind.verify);
    final verifying = auth.twoStepVerify(const TwoStepCode(code: '123456'));
    await manager.asked.future;
    await auth.twoStepCancel();
    manager.answer.complete(const OpenWebUiTwoStepSession(token: 'late'));
    await check(verifying).throws<RpcError>(
      (e) =>
          e.has((e) => e.code, 'code').equals(ConduitErrorCodes.twoStepExpired),
    );
    check(manager.finished).isEmpty();
  });

  test('a code checked for an attempt another sign-in replaced signs nobody '
      'in', () async {
    await signIn(OpenWebUiTwoStepKind.verify);
    final verifying = auth.twoStepVerify(const TwoStepCode(code: '123456'));
    await manager.asked.future;
    await signIn(OpenWebUiTwoStepKind.verify);
    manager.answer.complete(const OpenWebUiTwoStepSession(token: 'late'));
    await check(verifying).throws<RpcError>(
      (e) =>
          e.has((e) => e.code, 'code').equals(ConduitErrorCodes.twoStepExpired),
    );
    check(manager.finished).isEmpty();
  });

  test('an authenticator key asked for a cancelled enrolment is not '
      'handed over', () async {
    await signIn(OpenWebUiTwoStepKind.enroll);
    final loading = auth.twoStepSetup();
    await manager.setupAsked.future;
    await auth.twoStepCancel();
    await signIn(OpenWebUiTwoStepKind.enroll);
    manager.setup.complete(
      const OpenWebUiTwoStepSetup(manualKey: 'OLDKEY', qrCode: ''),
    );
    await check(loading).throws<RpcError>(
      (e) =>
          e.has((e) => e.code, 'code').equals(ConduitErrorCodes.twoStepExpired),
    );
  });

  test('Retry on a connection issue signs back in only once the server takes '
      'the kept session', () async {
    manager.kept = true;
    container.invalidate(authStateManagerProvider);
    await container.read(authStateManagerProvider.future);
    // The proxy still turns the session away.
    final snapshot = await auth.retry();
    check(snapshot.isAuthenticated).isFalse();
    check(snapshot.phase).equals(AuthPhase.error);
  });

  test('a sign-in started while the server is still read keeps its second '
      'step', () async {
    // Startup: the active server is still being read when the sign-in goes.
    final read = Completer<ServerConfig?>();
    final starter = _Manager();
    final starting = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(() => starter),
        activeServerProvider.overrideWith((ref) => read.future),
        reviewerModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(starting.dispose);
    await starting.read(authStateManagerProvider.future);
    final early = AuthService(starting);
    starter.next = OpenWebUiTwoStepKind.verify;
    final signingIn = early.loginWithPassword(
      const PasswordLogin(username: 'robin', password: 'tide-tables'),
    );
    read.complete(
      const ServerConfig(
        id: 'account-robin',
        name: 'Harbour',
        url: 'https://harbour.example',
      ),
    );
    check((await signingIn).twoStep).isNotNull();
    final verifying = early.twoStepVerify(const TwoStepCode(code: '123456'));
    await starter.asked.future;
    starter.answer.complete(const OpenWebUiTwoStepSession(token: 'fresh'));
    await verifying;
    check(starter.finished).deepEquals(<String>['fresh']);
  });

  // A credential error is a refused sign-in, but a browser sign-in whose
  // renewal ended is signed in to again.
  for (final (error, code) in [
    ('Invalid credentials', ConduitErrorCodes.invalidCredentials),
    ('browserSignInSessionExpired', ConduitErrorCodes.sessionExpired),
  ]) {
    test('a credential error "$error" is told as $code', () async {
      manager.built = AuthState(
        status: AuthStatus.credentialError,
        error: error,
      );
      container.invalidate(authStateManagerProvider);
      await container.read(authStateManagerProvider.future);
      check((await auth.status()).errorCode).equals(code);
    });
  }

  test('a code checked for the attempt still in charge signs in', () async {
    await signIn(OpenWebUiTwoStepKind.verify);
    final verifying = auth.twoStepVerify(const TwoStepCode(code: '123456'));
    await manager.asked.future;
    manager.answer.complete(const OpenWebUiTwoStepSession(token: 'fresh'));
    await verifying;
    check(manager.finished).deepEquals(<String>['fresh']);
  });
}

/// The core's manager, with each second step's answer held by the test.
final class _Manager extends AuthStateManager {
  OpenWebUiTwoStepKind next = OpenWebUiTwoStepKind.verify;
  var asked = Completer<void>();
  var answer = Completer<OpenWebUiTwoStepSession>();
  var setupAsked = Completer<void>();
  var setup = Completer<OpenWebUiTwoStepSetup>();
  final finished = <String>[];
  var _challenges = 0;

  /// A session kept on a connection issue, which the server (behind its
  /// sign-in proxy) still refuses.
  var kept = false;

  static const _issue = AuthState(
    status: AuthStatus.error,
    token: 'kept-token',
    error: 'connection issue',
  );

  /// What the next build publishes, when not [kept].
  AuthState? built;

  @override
  Future<AuthState> build() async => kept
      ? _issue
      : built ?? const AuthState(status: AuthStatus.unauthenticated);

  /// Trusts the kept token at once, as the core's refresh does.
  @override
  Future<void> refresh() async {
    state = const AsyncData(
      AuthState(status: AuthStatus.authenticated, token: 'kept-token'),
    );
  }

  /// Asks the server first: refused, the issue stays.
  @override
  Future<void> retryConnectionIssue() async {}

  @override
  Future<bool> login(
    String username,
    String password, {
    bool rememberCredentials = false,
    bool showLoading = true,
    bool publishErrors = true,
  }) async {
    _challenges++;
    throw OpenWebUiTwoStepRequired(
      OpenWebUiTwoStepChallenge(
        kind: next,
        challengeToken: 'challenge-$_challenges',
        expiresIn: const Duration(minutes: 5),
      ),
    );
  }

  @override
  Future<OpenWebUiTwoStepSession> submitTwoStepCode(
    OpenWebUiTwoStepChallenge challenge,
    String code, {
    bool recovery = false,
  }) {
    asked.complete();
    return answer.future;
  }

  @override
  Future<OpenWebUiTwoStepSetup> startTwoStepEnrollment(
    OpenWebUiTwoStepChallenge challenge,
  ) {
    setupAsked.complete();
    return setup.future;
  }

  @override
  Future<bool> finishTwoStepSignIn(OpenWebUiTwoStepSession session) async {
    finished.add(session.token);
    return true;
  }
}
