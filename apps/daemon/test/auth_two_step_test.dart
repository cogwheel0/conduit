@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A two-step sign-in is one attempt: an answer that comes back after the
/// attempt was cancelled, replaced by another sign-in or moved on to
/// another step finishes nothing.
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

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

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
