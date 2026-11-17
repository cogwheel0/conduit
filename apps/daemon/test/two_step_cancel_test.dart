@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

/// Back to Sign In while the core is still checking the session a second
/// step issued: the core's own commit refuses it, so nobody is signed in,
/// and the next attempt still signs in. Against a fake Open WebUI whose
/// session check the test holds.
///
/// One daemon for the file, and the tests run in order: `PreferencesStore`
/// and Hive are process-wide.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late AccountsService accounts;
  late AuthService auth;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('two-step-cancel-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    owui = await FakeOwuiAuthServer.start(
      users: const {
        'robin@example.com': (
          id: 'user-robin',
          name: 'Robin',
          password: 'tide-tables',
        ),
      },
      twoStep: const {'robin@example.com'},
    );
    accounts = AccountsService(runtime.container, events: EventBus());
    auth = AuthService(runtime.container);
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Harbour', url: owui.url),
      ),
    );
  });

  tearDownAll(() async {
    accounts.dispose();
    await owui.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  bool coreSignedIn() =>
      runtime.container.read(authStateManagerProvider).value?.isAuthenticated ??
      false;

  Future<void> atSecondStep() async {
    final snapshot = await auth.loginWithPassword(
      const PasswordLogin(
        username: 'robin@example.com',
        password: 'tide-tables',
      ),
    );
    check(snapshot.twoStep).isNotNull();
  }

  test(
    'Back to Sign In while the session is checked signs nobody in',
    () async {
      await atSecondStep();
      final hold = owui.holdSessionCheck = Completer<void>();
      final verifying = auth.twoStepVerify(const TwoStepCode(code: '123456'));
      // The code was right; the core is checking the session it brought.
      await owui.sessionChecked.future;
      await auth.twoStepCancel();
      owui.holdSessionCheck = null;
      hold.complete();
      await check(verifying).throws<RpcError>();
      check((await auth.status()).isAuthenticated).isFalse();
      check(coreSignedIn()).isFalse();
    },
  );

  test('the next attempt still signs in', () async {
    await atSecondStep();
    final snapshot = await auth.twoStepVerify(
      const TwoStepCode(code: '123456'),
    );
    check(snapshot.isAuthenticated).isTrue();
    check(coreSignedIn()).isTrue();
  });
}
