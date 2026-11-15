@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

/// `servers.update` on an account that is not in use, on the same server as
/// the signed-in one, against a fake Open WebUI with two synthetic users.
/// Accounts on one server share its address, so moving the other account's
/// moves the signed-in one's too, and its session must end before anything
/// is sent there.
///
/// One daemon for the file, and the tests run in order: `PreferencesStore`
/// and Hive are process-wide.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late HttpServer elsewhere;
  late AccountsService accounts;
  late AuthService auth;
  late ServersService servers;
  late String account;
  // The Authorization header of every request the other address received.
  final sentElsewhere = <String?>[];

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('servers-shared-test');
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
        'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
        'bob@example.com': (id: 'user-bob', name: 'Bob', password: 'pw-bob'),
      },
    );
    elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    elsewhere.listen((request) {
      sentElsewhere.add(request.headers.value('authorization'));
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    });
    accounts = AccountsService(runtime.container, events: EventBus());
    auth = AuthService(runtime.container);
    servers = ServersService(runtime.container);

    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    account = added.accounts.activeAccountId!;
    final signedIn = await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    expect(signedIn.isAuthenticated, isTrue);
  });

  tearDownAll(() async {
    accounts.dispose();
    await elsewhere.close(force: true);
    await owui.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('moving another account on the same server ends the session', () async {
    final second = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    final bob = second.accounts.activeAccountId!;
    final signedIn = await auth.loginWithPassword(
      const PasswordLogin(username: 'bob@example.com', password: 'pw-bob'),
    );
    expect(signedIn.isAuthenticated, isTrue);
    await accounts.switchTo(AccountRef(accountId: account));
    expect((await auth.status()).user?.name, 'Ada');

    final moved = 'http://127.0.0.1:${elsewhere.port}';
    await servers.update(ServerDraft(id: bob, name: 'Moved', url: moved));
    final status = await servers.status();
    expect(status.activeServerId, account);
    expect(sentElsewhere, isNotEmpty, reason: 'the status asks the new one');
    expect(sentElsewhere.whereType<String>(), isEmpty);
    expect((await auth.status()).isAuthenticated, isFalse);
  });
}
