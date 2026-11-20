@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show accountAdditionOriginProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:checks/checks.dart' as checks;
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
    'bob@example.com': (id: 'user-bob', name: 'Bob', password: 'pw-bob'),
  };

  setUpAll(() async {
    // Each resource is put back by its own teardown, registered as soon as
    // it is acquired (they run last first), so a later step that throws
    // leaves nothing behind.
    temporary = Directory.systemTemp.createTempSync('server-addresses-test');
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
    other = await FakeOwuiAuthServer.start(users: users);
    addTearDown(other.close);
    proxied = await FakeOwuiAuthServer.start(
      users: users,
      proxyCookie: '_lab_proxy=let-in',
    );
    addTearDown(proxied.close);
    events = EventBus();
    events.tap((event, _, payload) {
      if (event == ConduitEvents.serversChanged) {
        changed.add(ServersChanged.fromJson(payload).serverId);
      }
    });
    accounts = AccountsService(runtime.container, events: events);
    addTearDown(accounts.dispose);
    auth = AuthService(runtime.container);
    addTearDown(auth.dispose);
    servers = ServersService(runtime.container, events: events);
    addTearDown(servers.dispose);
    replies = _Replies();
    servers.replies = replies;
    await accounts.list();
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
        // The bind begins as the certification is announced and holds
        // storage's lock before this read: unbound now, it failed.
        final bound = await storage.getOpenWebUiRegistryStrict();
        if (bound.account(accountId)?.userId != null) return;
        fail('the account user of $accountId was not bound');
      } finally {
        watch.close();
      }
    }
  }

  setUp(() async {
    replies.reset();
    changed.clear();
    // Every account a test adds goes with it, and with its last account
    // its saved server and addresses: a fake started later on a port freed
    // here never joins a server an earlier test saved.
    final kept = {for (final a in (await accounts.list()).accounts) a.id};
    addTearDown(() async {
      for (final account in (await accounts.list()).accounts) {
        if (kept.contains(account.id)) continue;
        await accounts.remove(AccountRef(accountId: account.id));
      }
    });
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

  test('a rename leaves the live client, every reply it carries, and the '
      'addresses alone', () async {
    final client = runtime.container.read(apiServiceProvider);
    expect(client, isNotNull);
    final active = (await accounts.list()).activeAccountId;
    final before = (await list()).addresses;
    // A server's id renames it, nothing else: the URL is not taken.
    final summary = await servers.update(
      ServerDraft(id: serverId, name: 'Bench', url: 'https://ignored.test'),
    );
    final after = await list();
    expect(after.name, 'Bench');
    expect(after.addresses.map((a) => a.url), before.map((a) => a.url));
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
    final row = listed.accounts.singleWhere((a) => a.id == active);
    expect(row.serverId, serverId);
    expect(row.connection.name, 'Bench');
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

  final accountChanged = throwsA(
    isA<RpcError>()
        .having((e) => e.code, 'code', ConduitErrorCodes.sessionExpired)
        .having((e) => e.args['reason'], 'reason', 'account'),
  );

  // Asked under one session, a forced addition never stops the replies, or
  // begins from, the session another window put in charge while it read
  // the server's address.
  test('an addition on this server is refused once another session takes '
      'charge while its address is read', () async {
    final before = await accounts.list();
    final adding = accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        serverId: serverId,
        force: true,
      ),
    );
    runtime.container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..read(openWebUiAuthSessionEpochProvider);
    await expectLater(adding, accountChanged);
    final after = await accounts.list();
    expect(after.addingAccount, isFalse);
    expect(after.activeAccountId, before.activeAccountId);
    expect(after.accounts, hasLength(before.accounts.length));
  });

  // Another window left the addition while its selection waited for
  // storage: nothing was selected, and nothing waits for a sign-in.
  test('an addition left while it is saved is not reported as waiting for a '
      'sign-in', () async {
    final before = await accounts.list();
    final watch = runtime.container.listen<String?>(
      accountAdditionOriginProvider,
      (_, origin) {
        if (origin == null) return;
        scheduleMicrotask(
          () => runtime.container
              .read(accountAdditionOriginProvider.notifier)
              .end(origin),
        );
      },
    );
    addTearDown(watch.close);
    await expectLater(
      accounts.add(
        AddAccount(
          server: ServerDraft(name: 'Shed', url: other.url),
        ),
      ),
      accountChanged,
    );
    watch.close();
    final after = await accounts.list();
    expect(after.addingAccount, isFalse);
    expect(after.activeAccountId, before.activeAccountId);
    expect((await auth.status()).isAuthenticated, isTrue);
  });

  // Two windows add an account from the same one in charge, the second
  // before the first is saved: the first gives way, and leaves the second's
  // addition going.
  test('an addition overtaken by another from the same account leaves that '
      'one going', () async {
    final first = accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Shed', url: other.url),
      ),
    );
    final second = accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Shed', url: other.url),
      ),
    );
    await expectLater(first, accountChanged);
    final added = await second;
    expect(added.outcome, AccountChangeOutcome.needsSignIn);
    expect(added.accounts.addingAccount, isTrue);
    expect((await accounts.cancelAdd()).outcome, AccountChangeOutcome.done);
  });

  test('a rename while another window switches accounts rebuilds no client '
      'after the switch', () async {
    final lab = (await accounts.list()).activeAccountId!;
    // A second signed-in account, on another server.
    final shed = await FakeOwuiAuthServer.start(users: users);
    addTearDown(shed.close);
    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Shed', url: shed.url),
        force: true,
      ),
    );
    final other = added.accounts.activeAccountId!;
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    await userKnown(other);
    await accounts.switchTo(AccountRef(accountId: lab));
    await runtime.container.read(activeServerProvider.future);

    final clients = <Object?>[];
    final watch = runtime.container.listen<Object?>(
      apiServiceProvider,
      (_, next) => clients.add(next),
    );
    addTearDown(watch.close);
    int? afterSwitch;
    // The rename is published only once the switch is sampled: a client it
    // rebuilt could not hide among the switch's own.
    final sampled = Completer<void>();
    final switching = accounts.switchTo(AccountRef(accountId: other)).then((
      _,
    ) async {
      await runtime.container.read(activeServerProvider.future);
      afterSwitch = clients.length;
      sampled.complete();
    });
    final renaming = sampled.future.then(
      (_) => servers.update(
        ServerDraft(id: serverId, name: 'Barn', url: 'https://ignored.test'),
      ),
    );
    await Future.wait([renaming, switching]);
    await runtime.container.read(activeServerProvider.future);
    expect(
      clients.length,
      afterSwitch,
      reason: 'a client built after the switch ends the reply it carries',
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

    test('the same header twice, in any case', () async {
      final found = await check(
        ServerAddressForm(
          url: localhost(),
          headers: const [
            ServerAddressHeader(name: 'X-Lab', value: 'one'),
            ServerAddressHeader(name: 'x-lab', value: 'two'),
          ],
        ),
      );
      checks.check(found)
        ..has(
          (f) => f.problem,
          'problem',
        ).equals(ServerAddressProblemCode.headerAlreadyAdded)
        ..has((f) => f.headerName, 'headerName').equals('x-lab');
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

  test('an edit keeps a header value it was not given, its name in any '
      'case', () async {
    final second = await addSecond();
    final found = await check(
      ServerAddressForm(
        url: second.url,
        label: 'Renamed route',
        // Saved as `X-Lab`.
        headers: const [ServerAddressHeader(name: 'x-lab')],
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
    final headers = registry
        .server(serverId)!
        .endpoint(second.id)!
        .customHeaders;
    expect(
      [
        for (final e in headers.entries)
          if (e.key.toLowerCase() == 'x-lab') e.value,
      ],
      ['one'],
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

  test('a host typed without a scheme is checked at the address its server '
      'redirects to, and a saved value never goes over plain http', () async {
    final port = Uri.parse(owui.url).port;
    // Saved: this server's https address, with a gate header.
    await runtime.container
        .read(optimizedStorageServiceProvider)
        .editServerEndpoints(
          serverId,
          (endpoints) => [
            ...endpoints,
            OpenWebUiEndpoint(
              id: 'route-secure',
              url: 'https://127.0.0.1:$port',
              customHeaders: const {'X-Gate': 'kept-value'},
            ),
          ],
        );
    // The first plain /health is sent to https; any later one is not.
    owui.redirectHealthToHttpsOnce = true;
    final before = owui.headersSeen.length;
    final found = await check(
      ServerAddressForm(
        url: '127.0.0.1:$port',
        headers: const [ServerAddressHeader(name: 'X-Gate')],
      ),
      endpointId: 'route-secure',
    );
    expect(
      owui.headersSeen.skip(before).where((h) => h.containsKey('x-gate')),
      isEmpty,
      reason: 'the saved value went to http://127.0.0.1:$port',
    );
    // Checked at https only (which this plain fake cannot answer).
    expect(found.outcome, ServerAddressCheckOutcome.unusable);
  });

  test('an address moved to another origin takes no saved client identity '
      'there', () async {
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    // A second address at localhost with a client certificate and key.
    await storage.editServerEndpoints(
      serverId,
      (endpoints) => [
        ...endpoints,
        OpenWebUiEndpoint(
          id: 'route-with-identity',
          url: localhost(),
          mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\nlab\n',
          mtlsCertificateLabel: 'lab.crt',
          mtlsPrivateKeyPem: '-----BEGIN PRIVATE KEY-----\nlab\n',
          mtlsPrivateKeyLabel: 'lab.key',
          mtlsPrivateKeyPassword: 'key-pass',
        ),
      ],
    );
    // Moved to the server's 127.0.0.1 origin, no new files given.
    final found = await check(
      ServerAddressForm(url: '${owui.url}/', label: 'Moved'),
      endpointId: 'route-with-identity',
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    final saved = await servers.save(
      ServerAddressSaveRequest(
        checkId: found.checkId!,
        sendSessionConfirmed: true,
      ),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.done);
    final moved = (await storage.getOpenWebUiRegistryStrict())
        .server(serverId)!
        .endpoint('route-with-identity')!;
    expect(moved.mtlsCertificateChainPem, isNull);
    expect(moved.mtlsPrivateKeyPem, isNull);
    expect(moved.mtlsPrivateKeyPassword, isNull);
  });

  test('a cookie typed in an address, in any case, is refused', () async {
    final found = await check(
      ServerAddressForm(
        url: localhost(),
        headers: const [ServerAddressHeader(name: 'cookie', value: 'sid=x')],
      ),
    );
    expect(found.outcome, ServerAddressCheckOutcome.unusable);
    expect(found.problem, ServerAddressProblemCode.headerNameReserved);
    expect(found.headerName, 'cookie');
  });

  test('a saved header value is kept byte for byte by a label edit', () async {
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    await storage.editServerEndpoints(
      serverId,
      (endpoints) => [
        ...endpoints,
        OpenWebUiEndpoint(
          id: 'route-spaced',
          url: localhost(),
          customHeaders: const {'X-Lab': ' padded value '},
        ),
      ],
    );
    final found = await check(
      ServerAddressForm(
        url: localhost(),
        label: 'Renamed',
        headers: const [ServerAddressHeader(name: 'X-Lab')],
      ),
      endpointId: 'route-spaced',
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    final saved = await servers.save(
      ServerAddressSaveRequest(checkId: found.checkId!),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.done);
    final route = (await storage.getOpenWebUiRegistryStrict())
        .server(serverId)!
        .endpoint('route-spaced')!;
    expect(route.label, 'Renamed');
    expect(route.customHeaders['X-Lab'], ' padded value ');
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

  // The sign-in window names the account it was for, or none. Named, its
  // cookie is that account's once its own session proves the address,
  // whichever account is active; a named account that cannot is asked to
  // sign in.
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
    final ada = registry.accountsOn(serverId).single.id;
    expect(
      registry.account(ada)!.capturedHeaders[route.id]?['Cookie'],
      '_lab_proxy=let-in',
    );
    await servers.remove(
      ServerAddressRemoveRequest(serverId: serverId, endpointId: route.id),
    );

    // Bob's account on the same server, signed in; Ada's in charge again.
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        serverId: serverId,
        force: true,
      ),
    );
    await auth.loginWithPassword(
      const PasswordLogin(username: 'bob@example.com', password: 'pw-bob'),
    );
    final bob = (await accounts.list()).activeAccountId!;
    await userKnown(bob);
    await accounts.switchTo(AccountRef(accountId: ada));
    await runtime.container.read(activeServerProvider.future);

    Future<ServerAddressSaveResult> signedInFor(String account) async {
      final found = await check(ServerAddressForm(url: proxied.url));
      return servers.save(
        ServerAddressSaveRequest(
          checkId: found.checkId!,
          sendSessionConfirmed: true,
          proxy: ExternalAuthCompletion(
            origin: proxied.url,
            cookies: const {'_lab_proxy': 'let-in'},
            account: account,
          ),
        ),
      );
    }

    final refused = await signedInFor('an-account-not-signed-in-here');
    expect(refused.outcome, ServerAddressChangeOutcome.notSaved);
    expect(refused.problem, ServerAddressProblemCode.needsSignIn);

    // Ada's session would prove it too; only Bob's is asked.
    final forBob = await signedInFor(bob);
    expect(forBob.outcome, ServerAddressChangeOutcome.done);
    final bobRoute = forBob.addresses!.addresses.last;
    final kept = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    expect(
      kept.account(bob)!.capturedHeaders[bobRoute.id]?['Cookie'],
      '_lab_proxy=let-in',
    );
    expect(kept.account(ada)!.capturedHeaders, isNot(contains(bobRoute.id)));
    await servers.remove(
      ServerAddressRemoveRequest(serverId: serverId, endpointId: bobRoute.id),
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

  test('an address edit after a rename leaves the live client alone', () async {
    await servers.update(
      ServerDraft(id: serverId, name: 'Annex', url: 'https://ignored.test'),
    );
    final client = runtime.container.read(apiServiceProvider);
    expect(client, isNotNull);
    final order = (await list()).addresses.map((a) => a.id).toList();
    await servers.reorder(
      ServerAddressReorderRequest(serverId: serverId, order: order),
    );
    expect(
      identical(runtime.container.read(apiServiceProvider), client),
      isTrue,
      reason: 'the name is no connection: a new client ends a reply',
    );
  });

  test(
    'renaming the address in use neither asks about nor stops a reply',
    () async {
      final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
      replies.answering = true;
      addTearDown(() => replies.answering = false);
      final found = await check(
        ServerAddressForm(url: inUse.url, label: 'Desk'),
        endpointId: inUse.id,
      );
      expect(found.outcome, ServerAddressCheckOutcome.answered);
      final saved = await servers.save(
        ServerAddressSaveRequest(checkId: found.checkId!),
      );
      expect(saved.outcome, ServerAddressChangeOutcome.done);
      expect(replies.stopped, 0);
      expect(
        saved.addresses!.addresses.singleWhere((a) => a.id == inUse.id).label,
        'Desk',
      );
    },
  );

  test('a reply started while Save waits to write is asked about, never cut '
      'off', () async {
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    final found = await check(
      ServerAddressForm(
        url: inUse.url,
        label: 'Desk',
        headers: const [ServerAddressHeader(name: 'X-Desk', value: 'two')],
      ),
      endpointId: inUse.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    // No reply when Save asks first; one starts before storage writes.
    replies.next.addAll([false, true]);
    addTearDown(replies.next.clear);
    final saved = await servers.save(
      ServerAddressSaveRequest(checkId: found.checkId!),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.needsConfirmation);
    expect(saved.confirmation, ServerAddressConfirmation.replyInProgress);
    expect(replies.stopped, 0);
    final registry = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    expect(
      registry.server(serverId)!.endpoint(inUse.id)!.customHeaders,
      isNot(contains('X-Desk')),
    );
  });

  // Another saved server is reached exactly as the edit would reach this
  // one: refused as that server's address before any question, so no reply
  // is stopped for a save that never happens.
  test('an in-use edit to another saved server\'s connection stops no reply',
      () async {
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    await storage.saveServerConfigs([
      ...await storage.getServerConfigs(),
      ServerConfig(id: 'annex-account', name: 'Annex', url: localhost()),
    ]);
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    final found = await check(
      ServerAddressForm(url: localhost()),
      endpointId: inUse.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    replies.answering = true;
    addTearDown(() => replies.answering = false);
    final saved = await servers.save(
      ServerAddressSaveRequest(
        checkId: found.checkId!,
        sendSessionConfirmed: true,
        stopReplies: true,
      ),
    );
    expect(replies.stopped, 0, reason: 'a reply was stopped for nothing');
    expect(saved.outcome, ServerAddressChangeOutcome.notSaved);
    expect(saved.problem, ServerAddressProblemCode.differentServer);
    expect(
      (await list()).addresses.singleWhere((a) => a.id == inUse.id).url,
      inUse.url,
    );
  });

  /// Saves [found] with its account check held: [meanwhile] runs while the
  /// save waits on the server's answer, as another window's edit would.
  Future<ServerAddressSaveResult> saveWhileChecked(
    ServerAddressCheckResult found,
    Future<void> Function() meanwhile, {
    bool stopReplies = false,
  }) async {
    final hold = Completer<void>();
    owui
      ..sessionChecked = Completer<void>()
      ..holdSessionCheck = hold;
    addTearDown(() {
      owui.holdSessionCheck = null;
      if (!hold.isCompleted) hold.complete();
    });
    final saving = servers.save(
      ServerAddressSaveRequest(
        checkId: found.checkId!,
        sendSessionConfirmed: true,
        stopReplies: stopReplies,
      ),
    );
    await owui.sessionChecked.future;
    await meanwhile();
    hold.complete();
    return saving;
  }

  /// Saves the address in use with [headers], before an edit of it.
  Future<ServerAddressDto> gateInUse(Map<String, String> headers) async {
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    await runtime.container
        .read(optimizedStorageServiceProvider)
        .editServerEndpoints(
          serverId,
          (endpoints) => [
            for (final e in endpoints)
              e.id == inUse.id
                  ? OpenWebUiEndpoint(
                      id: e.id,
                      url: e.url,
                      customHeaders: headers,
                    )
                  : e,
          ],
        );
    return (await list()).addresses.singleWhere((a) => a.inUse);
  }

  /// Another saved server at this server's address, with [headers].
  Future<void> annexAt(Map<String, String> headers) async {
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    await storage.saveServerConfigs([
      ...await storage.getServerConfigs(),
      ServerConfig(
        id: 'annex-account',
        name: 'Annex',
        url: owui.url,
        customHeaders: headers,
      ),
    ]);
  }

  /// Adds [header] to the address [id] as another window's save would.
  Future<void> addHeaderElsewhere(String id, MapEntry<String, String> header) =>
      runtime.container
          .read(optimizedStorageServiceProvider)
          .editServerEndpoints(
            serverId,
            (endpoints) => [
              for (final e in endpoints)
                e.id == id
                    ? e.withConnectionOf(
                        OpenWebUiEndpoint(
                          id: e.id,
                          url: e.url,
                          customHeaders: {
                            ...e.customHeaders,
                            header.key: header.value,
                          },
                        ),
                      )
                    : e,
            ],
          );

  // The address checked for being another saved server's is the one the
  // write saves: the edit onto the address as stored when it saves, with
  // what another window saved meanwhile.
  test('a header saved during the check makes an in-use edit another '
      'server\'s: refused, and no reply is stopped', () async {
    final inUse = await gateInUse(const {'X-Gate': 'one'});
    await annexAt(const {'X-Gate': 'two', 'X-Extra': 'present'});
    final found = await check(
      ServerAddressForm(
        url: inUse.url,
        headers: const [ServerAddressHeader(name: 'X-Gate', value: 'two')],
      ),
      endpointId: inUse.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    replies.answering = true;
    addTearDown(() => replies.answering = false);
    final saved = await saveWhileChecked(
      found,
      () => addHeaderElsewhere(inUse.id, const MapEntry('X-Extra', 'present')),
      stopReplies: true,
    );
    expect(replies.stopped, 0, reason: 'a reply was stopped for nothing');
    expect(saved.outcome, ServerAddressChangeOutcome.notSaved);
    expect(saved.problem, ServerAddressProblemCode.differentServer);
  });

  test('a header saved during the check keeps an in-use edit its own: '
      'saved', () async {
    final inUse = await gateInUse(const {'X-Gate': 'one'});
    await annexAt(const {'X-Gate': 'two'});
    final found = await check(
      ServerAddressForm(
        url: inUse.url,
        headers: const [ServerAddressHeader(name: 'X-Gate', value: 'two')],
      ),
      endpointId: inUse.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    final saved = await saveWhileChecked(
      found,
      () => addHeaderElsewhere(inUse.id, const MapEntry('X-Extra', 'present')),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.done);
    final registry = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    expect(registry.server(serverId)!.endpoint(inUse.id)!.customHeaders, {
      'X-Gate': 'two',
      'X-Extra': 'present',
    });
  });

  test('an address removed during the check answers that it is gone', () async {
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
    final saved = await saveWhileChecked(
      found,
      () => runtime.container
          .read(optimizedStorageServiceProvider)
          .editServerEndpoints(
            serverId,
            (endpoints) => [
              for (final e in endpoints)
                if (e.id != second.id) e,
            ],
          ),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.notSaved);
    expect(saved.problem, ServerAddressProblemCode.serverMissing);
  });

  test('a save that fails before it is known to be written can be tried '
      'again', () async {
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    final found = await check(
      ServerAddressForm(
        url: inUse.url,
        label: 'Desk',
        headers: const [ServerAddressHeader(name: 'X-Desk', value: 'two')],
      ),
      endpointId: inUse.id,
    );
    // Save asks first, then the write fails while it asks again.
    replies.next.add(false);
    replies.fails = 1;
    addTearDown(replies.reset);
    final failed = await servers.save(
      ServerAddressSaveRequest(checkId: found.checkId!),
    );
    expect(failed.outcome, ServerAddressChangeOutcome.notSaved);
    expect(failed.problem, ServerAddressProblemCode.serverError);
    final saved = await servers.save(
      ServerAddressSaveRequest(checkId: found.checkId!),
    );
    expect(saved.outcome, ServerAddressChangeOutcome.done);
    final registry = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    expect(
      registry.server(serverId)!.endpoint(inUse.id)!.customHeaders['X-Desk'],
      'two',
    );
  });

  test('a move written before its answer failed is saved when tried again',
      () async {
    final inUse = (await list()).addresses.singleWhere((a) => a.inUse);
    final found = await check(
      ServerAddressForm(url: localhost()),
      endpointId: inUse.id,
    );
    expect(found.outcome, ServerAddressCheckOutcome.answered);
    // The move is written; the answer then fails (here, as the change is
    // announced).
    var failing = true;
    final untap = events.tap((event, _, _) {
      if (event == ConduitEvents.serversChanged && failing) {
        failing = false;
        throw StateError('the answer could not be put together');
      }
    });
    addTearDown(untap);
    final request = ServerAddressSaveRequest(
      checkId: found.checkId!,
      sendSessionConfirmed: true,
    );
    await expectLater(servers.save(request), throwsA(isA<StateError>()));
    final retried = await servers.save(request);
    expect(retried.outcome, ServerAddressChangeOutcome.done);
    expect(
      retried.addresses!.addresses.singleWhere((a) => a.id == inUse.id).url,
      localhost(),
    );
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
  test('a server saved over while a sign-in window is proved keeps its edit, '
      'and the window signs in again', () async {
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
    final pending = adding.accounts.activeAccountId;
    final gate = adding.accounts.accounts
        .singleWhere((a) => a.id == pending)
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
    // Released and joined whatever an assertion below does.
    addTearDown(() async {
      proxyOnly.hold = null;
      if (!release.isCompleted) release.complete();
      await finishing.then<void>((_) {}, onError: (Object _) {});
    });
    await held.future;
    await servers.update(
      ServerDraft(id: gate, name: 'Gate Two', url: 'https://ignored.test'),
    );
    proxyOnly.hold = null;
    release.complete();
    await expectLater(
      finishing,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    final listed = await accounts.list();
    final row = listed.accounts.singleWhere((a) => a.id == pending);
    expect(row.serverId, gate);
    expect(
      row.connection.name,
      'Gate Two',
      reason: 'the rename made while the sign-in was proved stays',
    );
    final registry = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    expect(
      registry.account(pending!)!.capturedHeaders,
      isEmpty,
      reason: 'nothing of the capture is kept',
    );
  });

  test('a header edited while a signed-in window is proved is kept, and the '
      'window signs in again', () async {
    final proxyOnly = await FakeOwuiAuthServer.start(
      users: const {
        'jo@example.com': (id: 'user-jo', name: 'Jo', password: 'pw-jo'),
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
    final pending = adding.accounts.activeAccountId!;
    final gate = adding.accounts.accounts
        .singleWhere((a) => a.id == pending)
        .serverId;
    final release = Completer<void>();
    final held = proxyOnly.onHeld = Completer<void>();
    proxyOnly.hold = release.future;
    final finishing = auth.completeExternal(
      ExternalAuthCompletion(
        origin: proxyOnly.url,
        cookies: const {'_gate': 'open'},
        token: proxyOnly.sessionFor('jo@example.com'),
      ),
    );
    addTearDown(() async {
      proxyOnly.hold = null;
      if (!release.isCompleted) release.complete();
      await finishing.then<void>((_) {}, onError: (Object _) {});
    });
    await held.future;
    // Another window gives the address a header the proxy now wants.
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    await storage.editServerEndpoints(
      gate,
      (endpoints) => [
        for (final endpoint in endpoints)
          OpenWebUiEndpoint(
            id: endpoint.id,
            url: endpoint.url,
            label: endpoint.label,
            customHeaders: const {'X-Gate': 'two'},
          ),
      ],
    );
    proxyOnly.hold = null;
    release.complete();
    await expectLater(
      finishing,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    final registry = await storage.getOpenWebUiRegistryStrict();
    expect(
      registry.server(gate)!.endpoints.single.customHeaders['X-Gate'],
      'two',
      reason: 'the edit made while the session was proved stays',
    );
    expect((await auth.status()).user?.email, isNot('jo@example.com'));
  });

  test('a sign-out queued while the active server is read revokes the '
      'capture', () async {
    final proxyOnly = await FakeOwuiAuthServer.start(
      users: const {
        'kit@example.com': (id: 'user-kit', name: 'Kit', password: 'pw-kit'),
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
    final pending = adding.accounts.activeAccountId!;
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    // The sign-out takes storage first; the active server is read again
    // behind it, while the window's capture is being handled.
    final signingOut = storage.clearActiveAccountAuthDataIf(
      canClear: () => true,
    );
    runtime.container.invalidate(activeServerProvider);
    final finishing = auth.completeExternal(
      ExternalAuthCompletion(
        origin: proxyOnly.url,
        cookies: const {'_gate': 'open'},
      ),
    );
    await signingOut;
    await expectLater(
      finishing,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    final registry = await storage.getOpenWebUiRegistryStrict();
    expect(registry.account(pending)!.capturedHeaders, isEmpty);
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
    await expectLater(
      finishing,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
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
    fails = 0;
  }

  /// What the next asks answer, first to last, before [answering] does.
  final List<bool> next = <bool>[];

  /// How many asks fail, after [next] is used up, before they answer again.
  int fails = 0;

  @override
  bool get addressAnswering {
    if (next.isNotEmpty) return next.removeAt(0);
    if (fails > 0) {
      fails--;
      throw StateError('the answers could not be read');
    }
    return answering;
  }

  @override
  Future<void> stopAddressAnswers() async {
    stopped++;
    answering = false;
  }
}
