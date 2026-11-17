@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/local_owui.dart';
import 'support/null_sink.dart';

/// An Open WebUI account behind a sign-in proxy whose session expires: the
/// account is kept, the daemon reports a connection issue it can renew, and
/// `auth.renewProxy` with the next proxy session signs it back in place.
///
/// Needs `tool/local_owui/owui.sh up && owui.sh proxy start` (a plain
/// instance, not two-step). Skipped without it.
void main() {
  final owui = LocalOwui.read();
  final values = owui?.values ?? const <String, String>{};
  final proxyUrl = values['OWUI_PROXY_URL'];

  group(
    'a proxy session that expires',
    skip: proxyUrl == null || values['OWUI_TWO_STEP'] == '1'
        ? 'no fake sign-in proxy (owui.sh proxy start) on a plain instance'
        : null,
    () {
      late Directory temporary;
      late CoreRuntime runtime;
      late AccountsService accounts;
      late AuthService auth;
      final events = EventBus();
      final seen = <String>[];
      final http = HttpClient();
      final proxy = Uri.parse(proxyUrl ?? 'http://127.0.0.1:1');

      Future<void> control(String action) async {
        final request = await http.postUrl(proxy.resolve('/__proxy/$action'));
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 200, reason: action);
      }

      /// Signs in at the proxy's page as a browser would: Continue, then
      /// back at the proxy, which sets its session cookie.
      Future<String> proxySession() async {
        final page = await http.getUrl(
          Uri.parse(
            'http://127.0.0.1:${proxy.port + 1}/approve'
            '?rd=%2F&port=${proxy.port}',
          ),
        );
        page.followRedirects = false;
        final approved = await page.close();
        await approved.drain<void>();
        final back = await http.getUrl(
          Uri.parse(approved.headers.value('location')!),
        );
        back.followRedirects = false;
        final callback = await back.close();
        await callback.drain<void>();
        return callback.cookies
            .firstWhere((c) => c.name == 'conduit_proxy')
            .value;
      }

      setUpAll(() async {
        temporary = Directory.systemTemp.createTempSync('conduitd-proxy');
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
        events.attach('window', (envelope) => seen.add(envelope.event));
        auth = AuthService(runtime.container, events: events);
        await auth.status();
        await accounts.list();
        await control('open');
      });

      tearDownAll(() async {
        await control('open');
        http.close(force: true);
        auth.dispose();
        await runtime.dispose();
        temporary.deleteSync(recursive: true);
      });

      test('signs in through the proxy, then renews it in place', () async {
        final added = await accounts.add(
          AddAccount(
            server: ServerDraft(name: 'Behind a proxy', url: proxyUrl!),
          ),
        );
        expect(added.outcome, AccountChangeOutcome.needsSignIn);
        final accountId = (await accounts.list()).activeAccountId;

        // The proxy guards the server from now on; a sign-in window gets
        // past it, then signs in to Open WebUI there.
        await control('guard');
        final first = await proxySession();
        final signIn = await http.postUrl(
          proxy.resolve('/api/v1/auths/signin'),
        );
        signIn.headers
          ..contentType = ContentType.json
          ..add('cookie', 'conduit_proxy=$first');
        signIn.write(
          jsonEncode({'email': owui!.email, 'password': owui.password}),
        );
        final signedInResponse = await signIn.close();
        final body = jsonDecode(
          await utf8.decodeStream(signedInResponse),
        ) as Map<String, dynamic>;
        final token = body['token'] as String;
        final signedIn = await auth.completeExternal(
          ExternalAuthCompletion(
            origin: proxyUrl,
            cookies: {'conduit_proxy': first, 'token': token},
            token: token,
          ),
        );
        expect(signedIn.isAuthenticated, isTrue);
        expect(signedIn.canRenewProxy, isTrue);

        // The proxy's session ends; the next check of the session is sent
        // to its sign-in page.
        await control('expire');
        // The server check (on launch, and when the window asks again)
        // finds the proxy's sign-in page where the server was.
        seen.clear();
        await ServersService(runtime.container).status();
        final issue = await auth.status();
        expect(issue.isAuthenticated, isFalse);
        expect(issue.phase, AuthPhase.error);
        expect(issue.hasToken, isTrue, reason: 'the session is kept');
        expect(issue.canRenewProxy, isTrue);
        expect(issue.errorCode, ConduitErrorCodes.connectionFailed);
        // Every window hears it, though the account list is unchanged.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(seen, contains(ConduitEvents.authChanged));
        expect((await accounts.list()).activeAccountId, accountId);

        // Retry alone cannot get past the proxy.
        final retried = await auth.retry();
        expect(retried.isAuthenticated, isFalse);

        // A new proxy session, from a sign-in window that stopped at the
        // server's page (no Open WebUI session of its own).
        final second = await proxySession();
        final renewed = await auth.renewProxy(
          ExternalAuthCompletion(
            origin: proxyUrl,
            cookies: {'conduit_proxy': second},
            account: accountId,
          ),
        );
        expect(renewed.isAuthenticated, isTrue);
        expect(renewed.user?.email, owui.email);
        expect((await accounts.list()).activeAccountId, accountId);
        // The renewed cookie is the one the account sends now.
        final user = await runtime.container
            .read(apiServiceProvider)!
            .getCurrentUser();
        expect(user.email, owui.email);
      });

      test('a renewal from another origin is refused', () async {
        final accountId = (await accounts.list()).activeAccountId;
        await expectLater(
          auth.renewProxy(
            ExternalAuthCompletion(
              origin: 'http://127.0.0.1:9',
              cookies: const {'conduit_proxy': 'x'},
              account: accountId,
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
      });
    },
  );
}
