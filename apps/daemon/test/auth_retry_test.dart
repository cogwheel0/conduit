@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

/// The connection issue's Retry (`auth.retry`) against a fake Open WebUI
/// that can answer as a sign-in proxy whose session expired: the kept
/// session is not shown signed in while the server still turns it away,
/// and signs back in once the server takes it again.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late AccountsService accounts;
  late AuthService auth;

  // Each case starts its own core and server, signed in as Ada, so it
  // passes alone and in its shard.
  setUp(() async {
    // Each thing is put back as soon as it exists, so a setup that fails
    // part way still cleans up what it made.
    temporary = Directory.systemTemp.createTempSync('auth-retry-test');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    addTearDown(runtime.dispose);
    owui = await FakeOwuiAuthServer.start(
      users: const {
        'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
      },
    );
    addTearDown(owui.close);
    accounts = AccountsService(runtime.container, events: EventBus());
    addTearDown(accounts.dispose);
    auth = AuthService(runtime.container);
    addTearDown(auth.dispose);

    await auth.status();
    await accounts.list();
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    final signedIn = await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    expect(signedIn.isAuthenticated, isTrue);
  });

  test(
    'Retry asks the server before showing a kept session signed in',
    () async {
      // The server's session is turned away, as by a sign-in proxy whose own
      // session expired, and the core shows the connection issue.
      owui.turnAway = true;
      runtime.container.read(authStateManagerProvider.notifier).onAuthIssue();
      final issue = await auth.status();
      expect(issue.phase, AuthPhase.error);
      expect(issue.hasToken, isTrue);

      final seen = <AuthStatus?>[];
      final watch = runtime.container.listen(
        authStateManagerProvider,
        (_, next) => seen.add(next.value?.status),
      );
      addTearDown(watch.close);

      final sessions = owui.signIns;
      final asked = owui.requests.length;
      final retried = await auth.retry();
      expect(
        owui.requests.skip(asked),
        contains('GET /api/v1/auths/'),
        reason: 'Retry asked the server about the session',
      );
      expect(retried.isAuthenticated, isFalse);
      expect(retried.phase, AuthPhase.error);
      expect(retried.hasToken, isTrue, reason: 'the session is kept');
      expect(
        seen,
        isNot(contains(AuthStatus.authenticated)),
        reason: 'never shown signed in while the server turns it away',
      );

      // The server takes the session again: Retry signs back in.
      owui.turnAway = false;
      final back = await auth.retry();
      expect(back.isAuthenticated, isTrue);
      expect(back.user?.email, 'ada@example.com');
      expect(owui.signIns, sessions, reason: 'the kept session was used again');
    },
  );

  test('Retry drops a session the server no longer takes and signs in '
      'again with the saved sign-in', () async {
    owui.revokeSessions();
    runtime.container.read(authStateManagerProvider.notifier).onAuthIssue();
    expect((await auth.status()).phase, AuthPhase.error);
    final issued = owui.signIns;

    final retried = await auth.retry();
    expect(owui.signIns, issued + 1, reason: 'a new session was asked for');
    expect(retried.isAuthenticated, isTrue);
    expect(retried.user?.email, 'ada@example.com');
  });
}
