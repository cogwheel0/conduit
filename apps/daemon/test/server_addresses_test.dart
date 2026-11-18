@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

/// `servers.addresses.*` and the server's name (`servers.update` with a
/// server's id) against a fake Open WebUI on loopback, reached as
/// 127.0.0.1 and as localhost: the same server at two addresses. A second
/// fake is another server, which does not know the first one's sessions.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late FakeOwuiAuthServer other;
  late FakeOwuiAuthServer proxied;
  late EventBus events;
  late AccountsService accounts;
  late AuthService auth;
  late ServersService servers;
  late _Replies replies;
  final changed = <String?>[];
  late String serverId;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('server-addresses-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    const users = {
      'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
    };
    owui = await FakeOwuiAuthServer.start(users: users);
    other = await FakeOwuiAuthServer.start(users: users);
    proxied = await FakeOwuiAuthServer.start(
      users: users,
      proxyCookie: '_lab_proxy=let-in',
    );
    events = EventBus();
    events.tap((event, _, payload) {
      if (event == ConduitEvents.serversChanged) {
        changed.add(ServersChanged.fromJson(payload).serverId);
      }
    });
    accounts = AccountsService(runtime.container, events: events);
    auth = AuthService(runtime.container);
    servers = ServersService(runtime.container, events: events);
    replies = _Replies();
    servers.replies = replies;

    await accounts.list();
    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
      ),
    );
    serverId = added.accounts.accounts
        .singleWhere((a) => a.id == added.accounts.activeAccountId)
        .serverId;
    final signedIn = await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    expect(signedIn.isAuthenticated, isTrue);
  });

  tearDownAll(() async {
    servers.dispose();
    accounts.dispose();
    auth.dispose();
    await owui.close();
    await other.close();
    await proxied.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  Future<ServerAddresses> list() =>
      servers.addresses(ServerRef(serverId: serverId));

  Future<ServerAddressCheckResult> check(
    ServerAddressForm form, {
    String? endpointId,
  }) => servers.check(
    ServerAddressCheckRequest(
      serverId: serverId,
      endpointId: endpointId,
      form: form,
    ),
  );

  String localhost() => owui.url.replaceFirst('127.0.0.1', 'localhost');

  test('a server starts with the address it was added at, in use', () async {
    final addresses = await list();
    expect(addresses.name, 'Lab');
    expect(addresses.addresses, hasLength(1));
    expect(addresses.addresses.single.url, owui.url);
    expect(addresses.addresses.single.inUse, isTrue);
    expect(addresses.removable, isFalse, reason: 'one is always left');
  });

  group('check refuses with the core problem', () {
    test('no address', () async {
      final found = await check(const ServerAddressForm());
      expect(found.outcome, ServerAddressCheckOutcome.unusable);
      expect(found.problem, ServerAddressProblemCode.addressEmpty);
    });

    test('an IP address that is not one', () async {
      final found = await check(const ServerAddressForm(url: '300.1.2.3'));
      expect(found.problem, ServerAddressProblemCode.invalidIpAddress);
    });

    test('a header the app sets itself, named', () async {
      final found = await check(
        ServerAddressForm(
          url: localhost(),
          headers: const [
            ServerAddressHeader(name: 'Authorization', value: 'x'),
          ],
        ),
      );
      expect(found.problem, ServerAddressProblemCode.headerNameReserved);
      expect(found.headerName, 'Authorization');
    });

    test('the same header twice', () async {
      final found = await check(
        ServerAddressForm(
          url: localhost(),
          headers: const [
            ServerAddressHeader(name: 'X-Lab', value: 'one'),
            ServerAddressHeader(name: 'X-Lab', value: 'two'),
          ],
        ),
      );
      expect(found.problem, ServerAddressProblemCode.headerAlreadyAdded);
      expect(found.headerName, 'X-Lab');
    });

    test('a key without its certificate', () async {
      final found = await check(
        ServerAddressForm(
          url: localhost(),
          mtlsPrivateKeyPem:
              '-----BEGIN PRIVATE'
              ' KEY-----\nmade-up\n',
          mtlsPrivateKeyLabel: 'lab-key.pem',
        ),
      );
      expect(found.problem, ServerAddressProblemCode.mutualTlsIncomplete);
    });

    test('nothing listening there', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final found = await check(
        ServerAddressForm(url: 'http://127.0.0.1:$port'),
      );
      expect(found.outcome, ServerAddressCheckOutcome.unusable);
      expect(found.problem, ServerAddressProblemCode.unreachable);
    });
  });

  test('a new host is asked about before a session goes there, then saved '
      'with its header', () async {
    final found = await check(
      ServerAddressForm(
        url: localhost(),
        label: 'Loopback name',
        headers: const [ServerAddressHeader(name: 'X-Lab', value: 'one')],
      ),
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    expect(found.url, localhost());

    final asked = await servers.save(
      ServerAddressSaveRequest(checkId: found.checkId!),
    );
    expect(asked.outcome, ServerAddressChangeOutcome.needsConfirmation);
    expect(asked.confirmation, ServerAddressConfirmation.sendSession);
    expect(asked.host, Uri.parse(localhost()).authority);
    expect((await list()).addresses, hasLength(1), reason: 'not yet');

    changed.clear();
    final saved = await servers.save(
      ServerAddressSaveRequest(
        checkId: found.checkId!,
        sendSessionConfirmed: true,
      ),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.done);
    final second = saved.addresses!.addresses.last;
    expect(second.url, localhost());
    expect(second.label, 'Loopback name');
    expect(second.customHeaderNames, ['X-Lab']);
    expect(second.inUse, isFalse);
    expect(saved.addresses!.removable, isTrue);
    expect(changed, contains(serverId));

    // Saved once: the check is used up.
    expect(
      () => servers.save(ServerAddressSaveRequest(checkId: found.checkId!)),
      throwsA(isA<RpcError>()),
    );
  });

  test('an edit keeps a header value it was not given', () async {
    final second = (await list()).addresses.last;
    final found = await check(
      ServerAddressForm(
        url: second.url,
        label: 'Renamed route',
        headers: const [ServerAddressHeader(name: 'X-Lab')],
      ),
      endpointId: second.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    final saved = await servers.save(
      ServerAddressSaveRequest(checkId: found.checkId!),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.done);
    expect(saved.addresses!.addresses.last.label, 'Renamed route');
    final registry = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    expect(
      registry.server(serverId)!.endpoint(second.id)!.customHeaders['X-Lab'],
      'one',
    );
  });

  test('another server does not know the session: sign in first', () async {
    final found = await check(ServerAddressForm(url: other.url));
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    final saved = await servers.save(
      ServerAddressSaveRequest(
        checkId: found.checkId!,
        sendSessionConfirmed: true,
      ),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.notSaved);
    expect(saved.problem, ServerAddressProblemCode.needsSignIn);
    expect(saved.addresses!.addresses, hasLength(2));
  });

  test('an address behind a sign-in proxy is saved with what its sign-in '
      'captured, the cookie kept for the account', () async {
    // The same server, behind a proxy.
    proxied.shareSessionsOf(owui);
    final found = await check(ServerAddressForm(url: proxied.url));
    expect(found.outcome, ServerAddressCheckOutcome.behindProxy);
    expect(found.url, proxied.url);
    expect(
      () => servers.save(ServerAddressSaveRequest(checkId: found.checkId!)),
      throwsA(isA<RpcError>()),
      reason: 'the proxy wants its sign-in first',
    );
    final capture = ExternalAuthCompletion(
      origin: proxied.url,
      cookies: const {'_lab_proxy': 'let-in'},
    );
    final asked = await servers.save(
      ServerAddressSaveRequest(checkId: found.checkId!, proxy: capture),
    );
    expect(asked.confirmation, ServerAddressConfirmation.sendSession);
    // Answered without the window again: the proxy's sign-in is kept.
    final saved = await servers.save(
      ServerAddressSaveRequest(
        checkId: found.checkId!,
        sendSessionConfirmed: true,
      ),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.done);
    final route = saved.addresses!.addresses.last;
    expect(route.url, proxied.url);
    expect(route.customHeaderNames, isEmpty, reason: 'the cookie is not one');

    final registry = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    expect(
      registry.server(serverId)!.endpoint(route.id)!.customHeaders,
      isNot(contains('Cookie')),
    );
    final account = registry.accountsOn(serverId).single;
    expect(account.capturedHeaders[route.id]?['Cookie'], '_lab_proxy=let-in');

    await servers.remove(
      ServerAddressRemoveRequest(serverId: serverId, endpointId: route.id),
    );
  });

  test('reorder puts them in the order given, and it is kept', () async {
    final before = (await list()).addresses;
    final result = await servers.reorder(
      ServerAddressReorderRequest(
        serverId: serverId,
        order: [before.last.id, before.first.id],
      ),
    );
    expect(result.outcome, ServerAddressChangeOutcome.done);
    expect(result.addresses.addresses.map((a) => a.id), [
      before.last.id,
      before.first.id,
    ]);
    expect((await list()).addresses.map((a) => a.id), [
      before.last.id,
      before.first.id,
    ]);
  });

  test('removing the address in use asks while a reply arrives', () async {
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    replies.answering = true;
    addTearDown(() => replies.answering = false);
    final asked = await servers.remove(
      ServerAddressRemoveRequest(serverId: serverId, endpointId: inUse.id),
    );
    expect(asked.outcome, ServerAddressChangeOutcome.needsConfirmation);
    expect(asked.confirmation, ServerAddressConfirmation.replyInProgress);
    expect(replies.stopped, 0);
    expect((await list()).addresses, hasLength(2));

    final removed = await servers.remove(
      ServerAddressRemoveRequest(
        serverId: serverId,
        endpointId: inUse.id,
        stopReplies: true,
      ),
    );
    expect(replies.stopped, 1);
    expect(removed.outcome, ServerAddressChangeOutcome.done);
    expect(removed.addresses.addresses, hasLength(1));
    expect(removed.addresses.removable, isFalse);
    expect(
      () => servers.remove(
        ServerAddressRemoveRequest(
          serverId: serverId,
          endpointId: removed.addresses.addresses.single.id,
        ),
      ),
      throwsA(isA<RpcError>()),
      reason: 'the last address stays',
    );
  });

  test("a server's id renames it, nothing else", () async {
    final before = (await list()).addresses;
    await servers.update(
      ServerDraft(id: serverId, name: 'Workshop', url: 'https://ignored.test'),
    );
    final after = await list();
    expect(after.name, 'Workshop');
    expect(after.addresses.map((a) => a.url), before.map((a) => a.url));
  });

  test(
    'Add Account on This Server joins it through its first address',
    () async {
      final first = (await list()).addresses.first;
      final result = await accounts.add(
        AddAccount(
          server: const ServerDraft(
            name: 'ignored',
            url: 'https://ignored.test',
          ),
          serverId: serverId,
          force: true,
        ),
      );
      final added = result.accounts.accounts.singleWhere(
        (a) => a.id == result.accounts.activeAccountId,
      );
      expect(added.serverId, serverId);
      expect(added.connection.url, first.url);
      await accounts.cancelAdd();
    },
  );

  test('a proxy that lets a sign-in window through keeps its cookie for the '
      'password sign-in that follows', () async {
    final proxyOnly = await FakeOwuiAuthServer.start(
      users: const {
        'grace@example.com': (
          id: 'user-grace',
          name: 'Grace',
          password: 'pw-grace',
        ),
      },
      proxyCookie: '_gate=open',
    );
    addTearDown(proxyOnly.close);
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Gate', url: proxyOnly.url),
        force: true,
      ),
    );
    // The window's proxy sign-in captured the cookie; Open WebUI still
    // wants a password.
    final through = await auth.completeExternal(
      ExternalAuthCompletion(
        origin: proxyOnly.url,
        cookies: const {'_gate': 'open'},
      ),
    );
    expect(through.isAuthenticated, isFalse);
    final signedIn = await auth.loginWithPassword(
      const PasswordLogin(username: 'grace@example.com', password: 'pw-grace'),
    );
    expect(signedIn.isAuthenticated, isTrue, reason: 'through the proxy');
    expect(signedIn.user?.email, 'grace@example.com');
  });
  test('the cookie a sign-in window keeps puts nothing else of what it read '
      'back', () async {
    final proxyOnly = await FakeOwuiAuthServer.start(
      users: const {
        'ivy@example.com': (id: 'user-ivy', name: 'Ivy', password: 'pw-ivy'),
      },
      proxyCookie: '_gate=open',
    );
    addTearDown(proxyOnly.close);
    final adding = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Gate', url: proxyOnly.url),
        force: true,
      ),
    );
    final gate = adding.accounts.accounts
        .singleWhere((a) => a.id == adding.accounts.activeAccountId)
        .serverId;
    // The window's proxy sign-in is proved while another window renames
    // the server.
    final release = Completer<void>();
    final held = proxyOnly.onHeld = Completer<void>();
    proxyOnly.hold = release.future;
    final finishing = auth.completeExternal(
      ExternalAuthCompletion(
        origin: proxyOnly.url,
        cookies: const {'_gate': 'open'},
      ),
    );
    await held.future;
    await servers.update(
      ServerDraft(id: gate, name: 'Gate Two', url: 'https://ignored.test'),
    );
    proxyOnly.hold = null;
    release.complete();
    final through = await finishing;
    expect(through.isAuthenticated, isFalse);
    final listed = await accounts.list();
    expect(
      listed.accounts.where((a) => a.serverId == gate).map(
        (a) => a.connection.name,
      ),
      everyElement('Gate Two'),
      reason: 'the rename made while the sign-in was proved stays',
    );
    final signedIn = await auth.loginWithPassword(
      const PasswordLogin(username: 'ivy@example.com', password: 'pw-ivy'),
    );
    expect(signedIn.isAuthenticated, isTrue, reason: 'the cookie was kept');
  });

  test('a sign-in window finished after its addition was cancelled '
      'commits nothing', () async {
    final proxyOnly = await FakeOwuiAuthServer.start(
      users: const {
        'hal@example.com': (id: 'user-hal', name: 'Hal', password: 'pw-hal'),
      },
      proxyCookie: '_gate=open',
    );
    addTearDown(proxyOnly.close);
    final before = await accounts.list();
    final adding = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Gate', url: proxyOnly.url),
        force: true,
      ),
    );
    final pending = adding.accounts.activeAccountId;
    // The window signed in through the proxy and Open WebUI both; proving
    // that session is held up while another window cancels the addition.
    final release = Completer<void>();
    proxyOnly.hold = release.future;
    final asked = proxyOnly.requests.length;
    final finishing = auth.completeExternal(
      ExternalAuthCompletion(
        origin: proxyOnly.url,
        cookies: const {'_gate': 'open'},
        token: proxyOnly.sessionFor('hal@example.com'),
      ),
    );
    for (var i = 0; i < 100 && proxyOnly.requests.length == asked; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(proxyOnly.requests.length, greaterThan(asked));
    final cancelling = accounts.cancelAdd();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    release.complete();
    proxyOnly.hold = null;
    await cancelling;
    final snapshot = await finishing;
    expect(snapshot.user?.email, isNot('hal@example.com'));
    final after = await accounts.list();
    expect(after.activeAccountId, before.activeAccountId);
    expect(after.accounts.map((a) => a.id), isNot(contains(pending)));
    // The account it was added from is back, whatever its own session's
    // state (the server of the account before this one is gone by now).
    expect((await auth.status()).user?.email, isNot('hal@example.com'));
  });
}

final class _Replies implements AddressReplies {
  bool answering = false;
  int stopped = 0;

  @override
  bool get addressAnswering => answering;

  @override
  Future<void> stopAddressAnswers() async {
    stopped++;
    answering = false;
  }
}
