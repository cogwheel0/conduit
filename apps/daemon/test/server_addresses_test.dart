@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/models/openwebui_registry.dart';
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
///
/// Each test starts from its own state: a new fake Open WebUI saved as a new
/// server, signed in to, its account's user known, and with a second
/// address only when the test adds one. Nothing a test leaves is read by
/// another, in whatever order they run.
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
  const users = {
    'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
  };

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
  });

  tearDownAll(() async {
    servers.dispose();
    accounts.dispose();
    auth.dispose();
    await other.close();
    await proxied.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  /// Once [accountId]'s user is known to storage: the core binds it after
  /// the sign-in's database is certified, on its own time. An address check
  /// proves an address only with an account whose user is known.
  Future<void> userKnown(String accountId) async {
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    while (true) {
      final certified = Completer<void>();
      final watch = runtime.container.listen<Object?>(
        openWebUiCertifiedDatabaseServerProvider,
        (_, _) {
          if (!certified.isCompleted) certified.complete();
        },
      );
      try {
        // Read after any bind already begun: both take storage's lock.
        final registry = await storage.getOpenWebUiRegistryStrict();
        if (registry.account(accountId)?.userId != null) return;
        await certified.future;
      } finally {
        watch.close();
      }
    }
  }

  setUp(() async {
    replies.reset();
    changed.clear();
    owui = await FakeOwuiAuthServer.start(users: users);
    addTearDown(owui.close);
    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ),
    );
    final account = added.accounts.activeAccountId!;
    serverId = added.accounts.accounts
        .singleWhere((a) => a.id == account)
        .serverId;
    final signedIn = await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    expect(signedIn.isAuthenticated, isTrue);
    await userKnown(account);
    await runtime.container.read(activeServerProvider.future);
    changed.clear();
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

  /// Saves this server's second address, at localhost with the header
  /// `X-Lab: one`, as an earlier edit would have.
  Future<ServerAddressDto> addSecond() async {
    await runtime.container
        .read(optimizedStorageServiceProvider)
        .editServerEndpoints(
          serverId,
          (endpoints) => [
            ...endpoints,
            OpenWebUiEndpoint(
              id: 'route-loopback-name',
              url: localhost(),
              label: 'Loopback name',
              customHeaders: const {'X-Lab': 'one'},
            ),
          ],
        );
    return (await list()).addresses.last;
  }

  test('a server starts with the address it was added at, in use', () async {
    final addresses = await list();
    expect(addresses.name, 'Lab');
    expect(addresses.addresses, hasLength(1));
    expect(addresses.addresses.single.url, owui.url);
    expect(addresses.addresses.single.inUse, isTrue);
    expect(addresses.removable, isFalse, reason: 'one is always left');
  });

  test('a rename leaves the live client, and every reply it carries, '
      'alone', () async {
    final client = runtime.container.read(apiServiceProvider);
    expect(client, isNotNull);
    final active = (await accounts.list()).activeAccountId;
    final summary = await servers.update(
      ServerDraft(id: serverId, name: 'Bench', url: 'https://ignored.test'),
    );
    expect(
      identical(runtime.container.read(apiServiceProvider), client),
      isTrue,
      reason: 'a new client ends the replies the old one carries',
    );
    expect(
      await runtime.container
          .read(optimizedStorageServiceProvider)
          .accountIdsWithSession(),
      contains(active),
    );
    expect(summary.hasStoredSession, isTrue);
    final listed = await accounts.list();
    expect(
      listed.accounts
          .where((a) => a.serverId == serverId)
          .map((a) => a.connection.name),
      everyElement('Bench'),
    );
  });

  test('a sign-in window opened for another account files nothing on the '
      'one in charge', () async {
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    await expectLater(
      auth.completeExternal(
        ExternalAuthCompletion(
          origin: inUse.url,
          cookies: const {'_lab_proxy': 'someone-elses'},
          account: 'an-account-no-longer-in-charge',
        ),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
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
    final second = await addSecond();
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

  test('an address moved to another origin is sent no saved header value, '
      'and asks for it again', () async {
    final second = await addSecond();
    final asked = other.requests.length;
    final found = await check(
      ServerAddressForm(
        url: other.url,
        headers: const [ServerAddressHeader(name: 'X-Lab')],
      ),
      endpointId: second.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.unusable);
    expect(found.problem, ServerAddressProblemCode.headerFieldMissing);
    expect(found.headerName, 'X-Lab');
    expect(other.requests, hasLength(asked), reason: 'nothing went there');
  });

  test('a user and password typed before a host without a scheme are '
      'refused', () async {
    final port = Uri.parse(owui.url).port;
    final found = await check(
      ServerAddressForm(url: 'ada:secret@127.0.0.1:$port'),
    );
    expect(found.outcome, ServerAddressCheckOutcome.unusable);
    expect(found.problem, ServerAddressProblemCode.invalidAddress);
  });

  test('a saved header value is kept as saved, never checked as typed '
      'input', () async {
    final second = await addSecond();
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    // Longer than a typed value may be: saved before that limit, say.
    final long = 'v' * 2048;
    await storage.editServerEndpoints(
      serverId,
      (endpoints) => [
        for (final endpoint in endpoints)
          endpoint.id == second.id
              ? OpenWebUiEndpoint(
                  id: endpoint.id,
                  url: endpoint.url,
                  label: endpoint.label,
                  customHeaders: {'X-Lab': long},
                )
              : endpoint,
      ],
    );
    addTearDown(
      () => storage.editServerEndpoints(
        serverId,
        (endpoints) => [
          for (final endpoint in endpoints)
            endpoint.id == second.id
                ? OpenWebUiEndpoint(
                    id: endpoint.id,
                    url: endpoint.url,
                    label: endpoint.label,
                    customHeaders: const {'X-Lab': 'one'},
                  )
                : endpoint,
        ],
      ),
    );
    final found = await check(
      ServerAddressForm(
        url: second.url,
        label: 'Long header',
        headers: const [ServerAddressHeader(name: 'X-Lab')],
      ),
      endpointId: second.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
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
    expect(saved.addresses!.addresses, hasLength(1));
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
    await addSecond();
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

  test('a reply started after removing was asked about is asked about '
      'before the address goes', () async {
    await addSecond();
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    // No reply when the remove is asked for; another window's starts before
    // storage writes.
    replies.next.addAll([false, true]);
    addTearDown(replies.next.clear);
    final asked = await servers.remove(
      ServerAddressRemoveRequest(serverId: serverId, endpointId: inUse.id),
    );
    expect(asked.outcome, ServerAddressChangeOutcome.needsConfirmation);
    expect(asked.confirmation, ServerAddressConfirmation.replyInProgress);
    expect((await list()).addresses, hasLength(2));
  });

  test('an order that names an address twice is refused, the saved order '
      'kept', () async {
    await addSecond();
    final before = (await list()).addresses.map((a) => a.id).toList();
    expect(before, hasLength(2));
    await expectLater(
      servers.reorder(
        ServerAddressReorderRequest(
          serverId: serverId,
          order: [before.last, before.last, before.first],
        ),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.invalidParams,
        ),
      ),
    );
    expect((await list()).addresses.map((a) => a.id), before);
  });

  test('removing the address in use asks while a reply arrives', () async {
    await addSecond();
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
      listed.accounts
          .where((a) => a.serverId == gate)
          .map((a) => a.connection.name),
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
    final held = proxyOnly.onHeld = Completer<void>();
    proxyOnly.hold = release.future;
    final finishing = auth.completeExternal(
      ExternalAuthCompletion(
        origin: proxyOnly.url,
        cookies: const {'_gate': 'open'},
        token: proxyOnly.sessionFor('hal@example.com'),
      ),
    );
    // Released and joined whatever an assertion below does.
    addTearDown(() async {
      proxyOnly.hold = null;
      if (!release.isCompleted) release.complete();
      await finishing.then<void>((_) {}, onError: (Object _) {});
    });
    // The proof is on the wire; the addition ends before it is answered.
    await held.future;
    await accounts.cancelAdd();
    proxyOnly.hold = null;
    release.complete();
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

  void reset() {
    answering = false;
    stopped = 0;
    next.clear();
  }

  /// What the next asks answer, first to last, before [answering] does.
  final List<bool> next = <bool>[];

  @override
  bool get addressAnswering => next.isNotEmpty ? next.removeAt(0) : answering;

  @override
  Future<void> stopAddressAnswers() async {
    stopped++;
    answering = false;
  }
}
