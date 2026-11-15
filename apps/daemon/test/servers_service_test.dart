@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

/// `servers.update` on the signed-in account, against a fake Open WebUI with
/// one synthetic user: an edit that keeps the server's identity keeps the
/// session, and one that moves it to another address ends the session
/// before anything is sent there.
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
    temporary = Directory.systemTemp.createTempSync('servers-test');
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

  test('a rename keeps the session', () async {
    final renamed = await servers.update(
      ServerDraft(id: account, name: 'Renamed', url: owui.url),
    );
    expect(renamed.name, 'Renamed');
    expect(renamed.hasStoredSession, isTrue);
    expect((await auth.status()).isAuthenticated, isTrue);
  });

  test('an address with a user or password in it is refused', () async {
    for (final url in <String>[
      'https://someone:made-up-pass@example.com',
      'https://:made-up-pass@example.com',
      'https://someone@example.com',
    ]) {
      await expectLater(
        servers.update(ServerDraft(id: account, name: 'Fake', url: url)),
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', ConduitErrorCodes.invalidParams)
              .having((e) => '$e', 'text', isNot(contains('made-up-pass'))),
        ),
        reason: url,
      );
    }
  });

  test('moving to another address ends the session first', () async {
    final moved = 'http://127.0.0.1:${elsewhere.port}';
    final summary = await servers.update(
      ServerDraft(id: account, name: 'Moved', url: moved),
    );
    expect(summary.hasStoredSession, isFalse);
    final status = await servers.status();
    expect(status.activeServerId, account);
    expect(sentElsewhere, isNotEmpty, reason: 'the status asks the new one');
    // The session belongs to the old address; its bearer never goes to the
    // new one.
    expect(sentElsewhere.whereType<String>(), isEmpty);
    expect((await auth.status()).isAuthenticated, isFalse);
  });
}
