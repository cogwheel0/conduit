@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/local_owui.dart';
import 'support/null_sink.dart';
import 'support/totp.dart';

/// Signs in to a local Open WebUI with two-step verification on, through
/// the daemon's `auth.*`: an authenticator code, a wrong one, a recovery
/// code, adding an authenticator, an administrator's reset, leaving the
/// step, an account awaiting approval, and the Token sign-in.
///
/// Needs `tool/local_owui/owui.sh reset && owui.sh two-step` (which signs
/// every session out and makes password sign-ins ask for a second step, so
/// the other live tests need a plain instance). Skipped without it. Each
/// run spends a recovery code and an authenticator step: reset before
/// running it again.
void main() {
  final owui = LocalOwui.read();
  final values = owui?.values ?? const <String, String>{};
  String value(String key) => values[key]!;

  group(
    'two-step sign-in against a local Open WebUI',
    skip: values['OWUI_TWO_STEP'] != '1'
        ? 'no two-step local Open WebUI (owui.sh two-step)'
        : null,
    () {
      late Directory temporary;
      late CoreRuntime runtime;
      late AccountsService accounts;
      late AuthService auth;

      setUpAll(() async {
        temporary = Directory.systemTemp.createTempSync('conduitd-two-step');
        runtime = await CoreRuntime.start(
          config: BootstrapConfig(
            sessionToken: 'a' * 43,
            masterKey: base64.encode(List<int>.generate(32, (i) => i)),
            userDataDir: temporary.path,
          ),
          directories: DaemonDirectories.create(temporary.path),
          log: DaemonLog(level: 'error', sink: NullSink()),
        );
        accounts = AccountsService(runtime.container, events: EventBus());
        auth = AuthService(runtime.container);
        await auth.status();
        await accounts.list();
      });

      tearDownAll(() async {
        await runtime.dispose();
        temporary.deleteSync(recursive: true);
      });

      /// An account on the server, signed out, to sign in to.
      Future<void> anAccount() async {
        final list = await accounts.list();
        if (list.activeAccountId != null) {
          final status = await auth.status();
          if (!status.isAuthenticated) return;
          await accounts.signOut(const AccountSignOut(force: true));
          if ((await accounts.list()).activeAccountId != null) return;
        }
        final added = await accounts.add(
          AddAccount(server: ServerDraft(name: 'Two-step', url: owui!.url)),
        );
        expect(added.outcome, AccountChangeOutcome.needsSignIn);
      }

      Future<AuthSnapshot> password(String who) => auth.loginWithPassword(
        PasswordLogin(
          username: value('OWUI_${who}_EMAIL'),
          password: value('OWUI_${who}_PASSWORD'),
        ),
      );

      Matcher refusedWith(String code) =>
          isA<RpcError>().having((e) => e.code, 'code', code);

      test('a wrong password is refused as wrong credentials', () async {
        await anAccount();
        await expectLater(
          auth.loginWithPassword(
            PasswordLogin(
              username: value('OWUI_TWO_STEP_EMAIL'),
              password: 'not-the-password-${DateTime.now().microsecond}',
            ),
          ),
          throwsA(refusedWith(ConduitErrorCodes.invalidCredentials)),
        );
      });

      test('an account awaiting approval says so', () async {
        await anAccount();
        await expectLater(
          password('PENDING'),
          throwsA(refusedWith(ConduitErrorCodes.pendingApproval)),
        );
        expect((await auth.status()).twoStep, isNull);
      });

      test('an API key is refused before the server is asked', () async {
        await anAccount();
        await expectLater(
          auth.loginWithApiKey(const ApiKeyLogin(apiKey: 'sk-0123456789ab')),
          throwsA(refusedWith(ConduitErrorCodes.apiKeyNotSupported)),
        );
        await expectLater(
          auth.loginWithApiKey(const ApiKeyLogin(apiKey: 'eyJ.short')),
          throwsA(refusedWith(ConduitErrorCodes.tokenTooShort)),
        );
      });

      test('the password leads to the second step, and back out', () async {
        await anAccount();
        final step = await password('TWO_STEP');
        expect(step.isAuthenticated, isFalse);
        expect(step.errorCode, isNull);
        expect(step.twoStep?.stage, TwoStepStage.verify);
        expect(step.twoStep?.account, value('OWUI_TWO_STEP_EMAIL'));
        expect(step.twoStep!.expiresInSeconds, greaterThan(0));
        // Still there when the window asks again.
        expect((await auth.status()).twoStep?.stage, TwoStepStage.verify);

        final back = await auth.twoStepCancel();
        expect(back.twoStep, isNull);
        await expectLater(
          auth.twoStepVerify(const TwoStepCode(code: '123456')),
          throwsA(refusedWith(ConduitErrorCodes.twoStepExpired)),
        );
      });

      test('a wrong code is refused, then a recovery code signs in', () async {
        await anAccount();
        await password('TWO_STEP');
        await expectLater(
          auth.twoStepVerify(const TwoStepCode(code: '000000')),
          throwsA(refusedWith(ConduitErrorCodes.twoStepInvalidCode)),
        );
        // The step stays for another try.
        expect((await auth.status()).twoStep?.stage, TwoStepStage.verify);
        final codes = value('OWUI_TWO_STEP_RECOVERY_CODES').split(',');
        final signedIn = await auth.twoStepVerify(
          TwoStepCode(code: codes.last, recovery: true),
        );
        expect(signedIn.isAuthenticated, isTrue);
        expect(signedIn.twoStep, isNull);
        expect(signedIn.user?.email, value('OWUI_TWO_STEP_EMAIL'));
      });

      test('an authenticator code signs in', () async {
        await anAccount();
        final step = await password('TWO_STEP');
        expect(step.twoStep?.stage, TwoStepStage.verify);
        final signedIn = await auth.twoStepVerify(
          TwoStepCode(
            code: totpCode(value('OWUI_TWO_STEP_SECRET'), stepsAhead: 1),
          ),
        );
        expect(signedIn.isAuthenticated, isTrue);
      });

      test('a first sign-in adds an authenticator, then shows the recovery '
          'codes before signing in', () async {
        await anAccount();
        final step = await password('ENROL');
        expect(step.twoStep?.stage, TwoStepStage.enroll);
        final setup = await auth.twoStepSetup();
        expect(setup.manualKey, matches(RegExp(r'^[A-Z2-7]{16,}$')));
        expect(setup.qrSvg, contains('<svg'));
        expect(
          setup.authenticatorUri,
          startsWith('otpauth://totp/Open%20WebUI:'),
        );
        expect(setup.authenticatorUri, contains('secret=${setup.manualKey}'));
        await expectLater(
          auth.twoStepVerify(const TwoStepCode(code: '000000')),
          throwsA(refusedWith(ConduitErrorCodes.twoStepInvalidCode)),
        );
        final codes = await auth.twoStepVerify(
          TwoStepCode(code: totpCode(setup.manualKey)),
        );
        expect(codes.isAuthenticated, isFalse);
        expect(codes.twoStep?.stage, TwoStepStage.recoveryCodes);
        expect(codes.twoStep?.recoveryCodes, hasLength(10));
        final signedIn = await auth.twoStepFinish();
        expect(signedIn.isAuthenticated, isTrue);
        expect(signedIn.twoStep, isNull);
      });

      test('an administrator\'s reset asks for their recovery token, then '
          'a new authenticator', () async {
        await anAccount();
        final step = await password('RESET');
        expect(step.twoStep?.stage, TwoStepStage.recover);
        await expectLater(
          auth.twoStepRedeem(
            const TwoStepResetToken(resetToken: 'not-the-token'),
          ),
          throwsA(refusedWith(ConduitErrorCodes.twoStepInvalidCode)),
        );
        final enrol = await auth.twoStepRedeem(
          TwoStepResetToken(resetToken: value('OWUI_RESET_TOKEN')),
        );
        expect(enrol.twoStep?.stage, TwoStepStage.enroll);
        final setup = await auth.twoStepSetup();
        final codes = await auth.twoStepVerify(
          TwoStepCode(code: totpCode(setup.manualKey)),
        );
        expect(codes.twoStep?.stage, TwoStepStage.recoveryCodes);
        expect((await auth.twoStepFinish()).isAuthenticated, isTrue);
      });

      test('a session token signs in without a second step', () async {
        await anAccount();
        final signedIn = await auth.loginWithApiKey(
          ApiKeyLogin(apiKey: value('OWUI_TWO_STEP_JWT')),
        );
        expect(signedIn.isAuthenticated, isTrue);
        expect(signedIn.user?.email, value('OWUI_TWO_STEP_EMAIL'));
      });
    },
  );

  test('authenticator codes follow RFC 6238', () {
    // RFC 6238's SHA-1 vector: the ASCII secret 12345678901234567890 at
    // 59 s gives 94287082; authenticator apps show its last six digits.
    expect(
      totpCode(
        'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
        at: DateTime.fromMillisecondsSinceEpoch(59000),
      ),
      '287082',
    );
  });
}
