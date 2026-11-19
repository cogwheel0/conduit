@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/proxy_renewal.dart';
import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart' show AsyncValue;
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

/// `auth.renewProxy` writes for the account whose sign-in window it was:
/// two accounts on one server, and a capture for the first is never saved
/// into the second's, nor its session committed once the second is in
/// charge.
///
/// One daemon for the file, and the tests run in order: `PreferencesStore`
/// and Hive are process-wide.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late AccountsService accounts;
  late AuthService auth;
  late String robin;
  late String sky;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('proxy-renewal-account');
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
          password: 'pw-r',
        ),
        'sky@example.com': (id: 'user-sky', name: 'Sky', password: 'pw-s'),
      },
    );
    accounts = AccountsService(runtime.container, events: EventBus());
    auth = AuthService(runtime.container);
    Future<String> account(String email, String password) async {
      final added = await accounts.add(
        AddAccount(
          server: ServerDraft(name: 'Harbour', url: owui.url),
        ),
      );
      final signedIn = await auth.loginWithPassword(
        PasswordLogin(username: email, password: password),
      );
      check(signedIn.isAuthenticated).isTrue();
      return added.accounts.activeAccountId!;
    }

    robin = await account('robin@example.com', 'pw-r');
    sky = await account('sky@example.com', 'pw-s');
  });

  tearDownAll(() async {
    accounts.dispose();
    await owui.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  /// The proxy cookie saved for [accountId].
  Future<String?> cookieOf(String accountId) async {
    final configs = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getServerConfigsStrict();
    final ServerConfig config = configs.firstWhere((c) => c.id == accountId);
    return config.customHeaders['Cookie'];
  }

  /// A session the server issues for [email], as a proxy window's own
  /// Open WebUI sign-in would capture.
  Future<String> sessionFor(String email, String password) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('${owui.url}/api/v1/auths/signin'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'email': email, 'password': password}));
      final response = await request.close();
      final body =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
      return body['token'] as String;
    } finally {
      client.close();
    }
  }

  test(
    'a capture for one account is not saved once another is in charge',
    () async {
      // Sky is in charge; Robin's window comes back.
      final before = await cookieOf(sky);
      await check(
        auth.renewProxy(
          ExternalAuthCompletion(
            origin: owui.url,
            cookies: const {'proxy_session': 'robin-window'},
            account: robin,
          ),
        ),
      ).throws<RpcError>(
        (e) => e
            .has((e) => e.code, 'code')
            .equals(ConduitErrorCodes.sessionExpired),
      );
      check(await cookieOf(sky)).equals(before);
    },
  );

  test('an account switch while the captured session is checked commits '
      'nothing for it', () async {
    await accounts.switchTo(AccountRef(accountId: robin));
    final token = await sessionFor('robin@example.com', 'pw-r');
    final hold = owui.holdSessionCheck = Completer<void>();
    owui.sessionChecked = Completer<void>();
    final renewing = auth.renewProxy(
      ExternalAuthCompletion(
        origin: owui.url,
        cookies: const {'proxy_session': 'robin-late'},
        token: token,
        account: robin,
      ),
    );
    await owui.sessionChecked.future;
    // Another window puts Sky in charge while Robin's session is checked.
    owui.holdSessionCheck = null;
    await accounts.switchTo(AccountRef(accountId: sky));
    hold.complete();
    await check(renewing).throws<RpcError>(
      (e) =>
          e.has((e) => e.code, 'code').equals(ConduitErrorCodes.sessionExpired),
    );
    final status = await auth.status();
    check(status.user?.name).equals('Sky');
  });

  test('a newer sign-in on the account while the renewal is checked keeps '
      'the newer session', () async {
    // Sky is in charge; a renewal of Sky's proxy session is checked while
    // Sky signs in again elsewhere.
    final captured = await sessionFor('sky@example.com', 'pw-s');
    final cookie = await cookieOf(sky);
    final hold = owui.holdSessionCheck = Completer<void>();
    owui.sessionChecked = Completer<void>();
    final renewing = auth.renewProxy(
      ExternalAuthCompletion(
        origin: owui.url,
        cookies: const {'proxy_session': 'sky-late'},
        token: captured,
        account: sky,
      ),
    );
    await owui.sessionChecked.future;
    final newer = await auth.loginWithPassword(
      const PasswordLogin(username: 'sky@example.com', password: 'pw-s'),
    );
    check(newer.isAuthenticated).isTrue();
    final newerToken = runtime.container
        .read(authStateManagerProvider)
        .value
        ?.token;
    hold.complete();
    await check(renewing).throws<RpcError>(
      (e) =>
          e.has((e) => e.code, 'code').equals(ConduitErrorCodes.sessionExpired),
    );
    check(runtime.container.read(authStateManagerProvider).value?.token)
        .equals(newerToken);
    check(await cookieOf(sky)).equals(cookie);
  });

  test('a capture of another user\'s session on the same server saves and '
      'commits nothing', () async {
    // Sky is in charge; Robin signs in at Sky's proxy window.
    final token = await sessionFor('robin@example.com', 'pw-r');
    final cookie = await cookieOf(sky);
    final before = runtime.container.read(authStateManagerProvider).value;
    await check(
      auth.renewProxy(
        ExternalAuthCompletion(
          origin: owui.url,
          cookies: const {'proxy_session': 'robin-at-skys-window'},
          token: token,
          account: sky,
        ),
      ),
    ).throws<RpcError>(
      (e) =>
          e.has((e) => e.code, 'code').equals(ConduitErrorCodes.sessionExpired),
    );
    check(await cookieOf(sky)).equals(cookie);
    final after = runtime.container.read(authStateManagerProvider).value;
    check(after?.token).equals(before?.token);
    check((await auth.status()).user?.name).equals('Sky');
  });

  test('a renewal that does not say its account is refused', () async {
    final cookie = await cookieOf(sky);
    await check(
      auth.renewProxy(
        ExternalAuthCompletion(
          origin: owui.url,
          cookies: const {'proxy_session': 'no-account'},
        ),
      ),
    ).throws<RpcError>(
      (e) =>
          e.has((e) => e.code, 'code').equals(ConduitErrorCodes.invalidParams),
    );
    check(await cookieOf(sky)).equals(cookie);
  });

  test('a renewal for the account in charge is saved and signs in', () async {
    await accounts.switchTo(AccountRef(accountId: robin));
    final token = await sessionFor('robin@example.com', 'pw-r');
    final renewed = await auth.renewProxy(
      ExternalAuthCompletion(
        origin: owui.url,
        cookies: const {'proxy_session': 'robin-fresh'},
        token: token,
        account: robin,
      ),
    );
    check(renewed.isAuthenticated).isTrue();
    check(renewed.user?.name).equals('Robin');
    check(await cookieOf(robin)).isNotNull().contains('robin-fresh');
  });

  // The two cases below renew for whichever account is in charge, as the
  // connection issue page does, and switch nothing: putting an account in
  // charge takes up its session again (`switchToAccount` refreshes it and
  // checks it with the server in the background), and that check landing
  // while a renewal runs is a newer session the renewal rightly refuses.
  test(
    'a renewal the proxy still turns away keeps the connection issue',
    () async {
      final inCharge = (await accounts.list()).activeAccountId!;
      // Its proxy session has expired: the proxy turns every request away.
      owui.proxyRefuses = true;
      owui.proxyAccepts = null;
      addTearDown(() => owui.proxyRefuses = false);
      runtime.container.read(authStateManagerProvider.notifier).onAuthIssue();
      final cookie = await cookieOf(inCharge);
      await check(
        auth.renewProxy(
          ExternalAuthCompletion(
            origin: owui.url,
            cookies: const {'proxy_session': 'still-refused'},
            account: inCharge,
          ),
        ),
      ).throws<RpcError>();
      check(await cookieOf(inCharge)).equals(cookie);
      check(
        runtime.container.read(authStateManagerProvider).value?.isAuthenticated,
      ).equals(false);
    },
  );

  test('once the proxy takes the session, the renewal signs back in', () async {
    final inCharge = (await accounts.list()).activeAccountId!;
    final name = (await auth.status()).user?.name;
    check(name).isNotNull();
    // On the connection issue an expired proxy session showed; the proxy
    // takes only the renewed session's cookie, so nothing but this renewal
    // can sign the account back in.
    owui.proxyRefuses = true;
    owui.proxyAccepts = 'proxy_session=renewed';
    addTearDown(() {
      owui.proxyRefuses = false;
      owui.proxyAccepts = null;
    });
    runtime.container.read(authStateManagerProvider.notifier).onAuthIssue();
    check(
      runtime.container.read(authStateManagerProvider).value?.isAuthenticated,
    ).equals(false);
    final renewed = await auth.renewProxy(
      ExternalAuthCompletion(
        origin: owui.url,
        cookies: const {'proxy_session': 'renewed'},
        account: inCharge,
      ),
    );
    check(renewed.isAuthenticated).isTrue();
    check(renewed.user?.name).equals(name);
    check(await cookieOf(inCharge)).isNotNull().contains('renewed');
  });

  test(
    'a sign-in begun once a renewal has saved is not superseded by it',
    () async {
      final inCharge = (await accounts.list()).activeAccountId!;
      final (email, password) = inCharge == robin
          ? ('robin@example.com', 'pw-r')
          : ('sky@example.com', 'pw-s');
      // On the connection issue; the moment the renewal's server is in use
      // with its cookies, the account signs in again (its check held).
      runtime.container.read(authStateManagerProvider.notifier).onAuthIssue();
      final active = await runtime.container.read(activeServerProvider.future);
      final hold = Completer<void>();
      Future<bool>? signingIn;
      // The renewed server in use: from here the renewal only has its
      // retry left.
      final saved = runtime.container.listen<AsyncValue<ServerConfig?>>(
        activeServerProvider,
        (_, next) {
          final server = next.value;
          final renewed =
              server?.id == inCharge &&
              (server?.customHeaders['Cookie'] ?? '').contains(
                'saved-meanwhile',
              );
          if (renewed && signingIn == null) {
            owui.holdSessionCheck = hold;
            owui.sessionChecked = Completer<void>();
            signingIn = runtime.container
                .read(authStateManagerProvider.notifier)
                .login(email, password);
          }
        },
      );
      addTearDown(saved.close);
      await renewProxySessionInPlace(
        runtime.container,
        activeServer: active!,
        capture: ProxyAuthCapture(
          cookies: const {'proxy_session': 'saved-meanwhile'},
        ),
      );
      check(signingIn).isNotNull();
      await owui.sessionChecked.future;
      final newer = owui.lastIssued;
      hold.complete();
      check(await signingIn!).isTrue();
      check(runtime.container.read(authStateManagerProvider).value?.token)
          .equals(newer);
    },
  );
}
