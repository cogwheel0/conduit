import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/ports/browser_auth_port.dart';
import 'package:conduit_core/ports/external_url_port.dart';
import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:synchronized/synchronized.dart';
import 'package:test/test.dart';

void main() {
  group('profile list', () {
    test('a draft without a URL, or unencrypted unasked, lists nothing', () {
      check(
        hermesProfileListBlocker(const HermesConfig(baseUrl: '')),
      ).equals(HermesProfileListIssue.noUrl);
      check(
        hermesProfileListBlocker(
          const HermesConfig(baseUrl: 'http://gateway.example:8642'),
        ),
      ).equals(HermesProfileListIssue.testFirst);
      check(
        hermesProfileListBlocker(
          const HermesConfig(baseUrl: 'http://127.0.0.1:8642'),
        ),
      ).isNull();
      check(
        hermesProfileListBlocker(
          const HermesConfig(baseUrl: 'https://gateway.example'),
        ),
      ).isNull();
    });

    test('a refreshed list keeps the profile, else default, else first', () {
      check(
        hermesProfileAfterRefresh(['default', 'work'], 'work'),
      ).equals('work');
      check(
        hermesProfileAfterRefresh(['work', 'default'], 'gone'),
      ).equals('default');
      check(
        hermesProfileAfterRefresh(['work', 'home'], 'gone'),
      ).equals('work');
      check(hermesProfileAfterRefresh(const [], 'gone')).equals('gone');
    });
  });

  test(
    'first-time native sign-in saves tokens and connects the gateway WebSocket',
    () async {
      final gateway = await _Gateway.start();
      addTearDown(gateway.close);
      final container = ProviderContainer(
        overrides: [hermesConfigProvider.overrideWith(_DisabledConfig.new)],
      );
      addTearDown(container.dispose);
      final browser = _CallbackBrowser();
      final saved = <HermesDesktopCredentials>[];
      final coordinator = HermesDesktopConnectionCoordinator(
        openExternalUrl: browser,
      );

      final draft = HermesConfig(
        enabled: false,
        baseUrl: gateway.baseUrl,
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.nativePkce,
      );
      await coordinator.signInNative(
        draft,
        onCredentialsChanged: (credentials) async => saved.add(credentials),
      );

      check(browser.opened.single.path).equals('/auth/native/authorize');
      check(saved.single.nativeTokens?.accessToken).equals('access');
      check(saved.single.nativeTokens?.refreshToken).equals('refresh');
      check(container.read(hermesApiServiceProvider)).isNull();
      check(
        await container
            .read(hermesConnectionGatewayProvider)
            .probe(draft.copyWith(desktopCredentials: saved.single)),
      ).isTrue();
      check(gateway.ticketAuthorizations).deepEquals(['Bearer access']);
      check(gateway.socketTickets).deepEquals(['native-ticket']);
      check(gateway.rpcMethods).deepEquals(['client.capabilities', 'model.options']);
    },
  );

  // Every request from a draft carries its credentials, its access headers
  // at least: from a plain HTTP draft to another machine, none leaves
  // before the user has agreed, even the ones typing a URL fires.
  test('sends nothing from a plain HTTP draft without consent', () async {
    const coordinator = HermesDesktopConnectionCoordinator();
    final draft = HermesConfig(
      baseUrl: 'http://192.0.2.10:8642',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'lan-token',
        accessHeaders: const {'X-Lab-Gate': 'lab'},
      ),
    );

    await check(
      coordinator.profiles(draft),
    ).throws<HermesPlainHttpConsentRequired>();
    await check(
      coordinator.recommendedAuth(draft),
    ).throws<HermesPlainHttpConsentRequired>();
    await check(
      coordinator.signInNative(draft, onCredentialsChanged: (_) async {}),
    ).throws<HermesPlainHttpConsentRequired>();
  });

  test('first-time dashboard setup connects the gateway WebSocket', () async {
    final gateway = await _Gateway.start();
    addTearDown(gateway.close);
    final bridges = <_ProfileBridge>[];
    HermesDashboardBridge factory({
      required Uri root,
      required Map<String, String> accessHeaders,
    }) {
      final bridge = _ProfileBridge();
      bridges.add(bridge);
      return bridge;
    }

    final coordinator = HermesDesktopConnectionCoordinator(
      dashboardBridgeFactory: factory,
    );
    final container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(_DisabledConfig.new),
        hostHermesDashboardBridgeFactoryProvider.overrideWith((ref) => factory),
      ],
    );
    addTearDown(container.dispose);
    final draft = HermesConfig(
      enabled: false,
      baseUrl: gateway.baseUrl,
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
    );

    final profiles = await coordinator.profiles(draft);

    check(profiles).deepEquals(['default', 'work']);
    check(bridges.single.closed).isTrue();
    check(container.read(hermesApiServiceProvider)).isNull();
    check(await container.read(hermesConnectionGatewayProvider).probe(draft))
        .isTrue();
    check(bridges.expand((bridge) => bridge.requests).toList())
        .deepEquals(['GET /api/profiles', 'POST /api/auth/ws-ticket']);
    check(gateway.socketTickets).deepEquals(['dashboard-ticket']);
    check(gateway.rpcMethods).deepEquals(['client.capabilities', 'model.options']);
  });

  // Hermes redirects only to a loopback address: its listener sends the
  // browser sheet on to the app's own redirect, which ends the sheet.
  group('native sign-in in the browser sheet', () {
    late _Gateway gateway;
    late List<HermesDesktopCredentials> saved;

    setUp(() async {
      gateway = await _Gateway.start();
      saved = [];
    });
    tearDown(() => gateway.close());

    Future<bool> signIn(BrowserAuthPort sheet, {OpenExternalUrlPort? browser}) =>
        HermesDesktopConnectionCoordinator(
          openExternalUrl: browser,
          browserAuth: sheet,
        ).signInNative(
          HermesConfig(
            baseUrl: gateway.baseUrl,
            mode: HermesBackendMode.desktopGateway,
            desktopAuthKind: HermesDesktopAuthKind.nativePkce,
          ),
          onCredentialsChanged: (credentials) async => saved.add(credentials),
        );

    test('returns to the app with no secret, then exchanges the code', () async {
      final sheet = _Sheet();

      check(await signIn(sheet)).isTrue();

      final page = sheet.opened.single;
      check(page.path).equals('/auth/native/authorize');
      check(sheet.redirects.single).equals(Uri.parse(browserAuthDefaultRedirect));
      check(sheet.answers.single.status).equals(HttpStatus.found);
      // Only the state the bridge matches the sign-in by: no code, no token.
      check(sheet.answers.single.location).equals(
        '$browserAuthDefaultRedirect?state=${page.queryParameters['state']}',
      );
      check(gateway.exchangedCodes).deepEquals(['one-time-code']);
      check(saved.single.nativeTokens?.refreshToken).equals('refresh');
    });

    test('a closed sheet cancels, with no error, and stops listening', () async {
      final sheet = _Sheet(closedByUser: true);

      check(await signIn(sheet)).isFalse();

      check(saved).isEmpty();
      check(gateway.exchangedCodes).isEmpty();
      final listener = Uri.parse(
        sheet.opened.single.queryParameters['redirect_uri']!,
      );
      await check(
        Socket.connect(listener.host, listener.port),
      ).throws<SocketException>();
    });

    test('a callback with another state is refused, and the sign-in waits '
        'for its own', () async {
      final sheet = _Sheet(strayFirst: true);

      check(await signIn(sheet)).isTrue();

      final (stray, own) = (sheet.answers.first, sheet.answers.last);
      check(stray.status).equals(HttpStatus.notFound);
      check(stray.location).isNull();
      check(own.status).equals(HttpStatus.found);
      check(gateway.exchangedCodes).deepEquals(['one-time-code']);
    });

    test('a callback with no code fails, and closes the sheet', () async {
      final sheet = _Sheet(code: null);

      await check(signIn(sheet)).throws<StateError>();

      check(sheet.answers.single.status).equals(HttpStatus.found);
      check(saved).isEmpty();
      check(gateway.exchangedCodes).isEmpty();
    });

    test('without a browser sheet, opens the default browser', () async {
      final sheet = _Sheet(supported: false);
      final browser = _CallbackBrowser();

      check(await signIn(sheet, browser: browser)).isTrue();

      check(sheet.opened).isEmpty();
      check(browser.opened.single.path).equals('/auth/native/authorize');
      check(gateway.exchangedCodes).deepEquals(['one-time-code']);
      check((await browser.page.future).status).equals(HttpStatus.ok);
    });

    test('without a browser sheet, a callback with an empty code says on its '
        'page that sign-in failed, and fails', () async {
      final browser = _CallbackBrowser(code: '');

      await check(
        signIn(_Sheet(supported: false), browser: browser),
      ).throws<StateError>();

      final page = await browser.page.future;
      check(page.status).equals(HttpStatus.badRequest);
      check(page.body).contains('could not be verified');
      check(gateway.exchangedCodes).isEmpty();
    });
  });

  group('gateway tokens', () {
    final now = DateTime.utc(2026, 11, 15, 12);

    HermesDesktopApiService service(
      _TokenRest rest, {
      required DateTime expiresAt,
      required List<HermesDesktopCredentials> saved,
      BrowserAuthPort? browserAuth,
      HermesDesktopTokensReader? readStoredTokens,
      HermesDesktopCredentialsWriter? writeCredentials,
      HermesDesktopTokenGuard? guardTokens,
    }) {
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopAuthKind: HermesDesktopAuthKind.nativePkce,
          desktopCredentials: HermesDesktopCredentials(
            nativeTokens: HermesDesktopTokenSet(
              accessToken: 'access',
              refreshToken: 'refresh',
              expiresAt: expiresAt,
            ),
          ),
        ),
        dio: Dio()..httpClientAdapter = rest,
        browserAuth: browserAuth,
        readStoredTokens: readStoredTokens,
        guardTokens: guardTokens,
        onCredentialsChanged:
            writeCredentials ??
            (credentials) async => saved.add(credentials),
      );
      addTearDown(service.close);
      return service;
    }

    for (final (expiresIn, renews) in [
      (const Duration(minutes: 2), true),
      (const Duration(hours: 1), false),
    ]) {
      test(
        'coming back to the foreground ${renews ? 'renews' : 'keeps'} '
        'tokens that expire in ${expiresIn.inMinutes} minutes',
        () => withClock(Clock.fixed(now), () async {
          final rest = _TokenRest();
          final saved = <HermesDesktopCredentials>[];
          final lifecycle = _Lifecycle();
          final gateway = service(
            rest,
            expiresAt: now.add(expiresIn),
            saved: saved,
          )..startLifecycleObservation(lifecycle);

          lifecycle.emit(AppLifecyclePhase.resumed);
          await gateway.resumeRenewal;

          check(rest.paths.contains('/auth/native/refresh')).equals(renews);
          check(saved.length).equals(renews ? 1 : 0);
        }),
      );
    }

    // A request is still waiting on a renewal of the old tokens when a
    // sign-in finishes: whether Hermes renewed them, refused them or was
    // not ready, the sign-in's tokens stay, and the request sends them.
    for (final refreshStatus in [
      HttpStatus.ok,
      HttpStatus.unauthorized,
      HttpStatus.serviceUnavailable,
    ]) {
      test(
        'a renewal answered $refreshStatus after a sign-in leaves the sign-in',
        () => withClock(Clock.fixed(now), () async {
          final held = Completer<void>();
          final rest = _TokenRest(
            refreshStatus: refreshStatus,
            refreshGate: held.future,
          );
          final saved = <HermesDesktopCredentials>[];
          final gateway = service(
            rest,
            expiresAt: now.add(const Duration(seconds: 30)),
            saved: saved,
            browserAuth: _Sheet(),
          );

          final jobs = gateway.listJobs();
          await rest.refreshArrived.future;
          check(rest.refreshTokensSent).deepEquals(['refresh']);
          check(await gateway.signInNative()).isNotNull();
          held.complete();
          await jobs;

          check(
            saved.single.nativeTokens?.refreshToken,
          ).equals('signed-in-refresh');
          check(
            rest.jobsAuthorizations,
          ).deepEquals(['Bearer signed-in-access']);
        }),
      );
    }

    // Push renewed the same tokens while this client was busy, so the
    // refresh token it holds is spent: sending it would end the session at
    // a provider that detects reuse. It takes the stored tokens instead, and
    // renews only those.
    for (final (storedExpiresIn, renews) in [
      (const Duration(hours: 1), false),
      (const Duration(minutes: 2), true),
    ]) {
      test(
        'coming back after another client rotated the tokens '
        '${renews ? 'renews the stored ones' : 'takes the stored ones'}',
        () => withClock(Clock.fixed(now), () async {
          final rest = _TokenRest();
          final lifecycle = _Lifecycle();
          final gateway = service(
            rest,
            expiresAt: now.add(const Duration(minutes: 2)),
            saved: [],
            readStoredTokens: () async => HermesDesktopTokenSet(
              accessToken: 'pushed-access',
              refreshToken: 'pushed-refresh',
              expiresAt: now.add(storedExpiresIn),
            ),
          )..startLifecycleObservation(lifecycle);

          lifecycle.emit(AppLifecyclePhase.resumed);
          await gateway.resumeRenewal;
          await gateway.listJobs();

          check(
            rest.refreshTokensSent,
          ).deepEquals([if (renews) 'pushed-refresh']);
          check(rest.jobsAuthorizations).deepEquals([
            renews ? 'Bearer renewed-access' : 'Bearer pushed-access',
          ]);
        }),
      );
    }

    // Another client wrote the stored tokens since this one read its own:
    // rotated them, or cleared them after Hermes refused a renewal. A
    // renewal's save would be refused; a sign-in replaces them.
    for (final storedRefresh in [null, 'pushed-refresh']) {
      test('a sign-in replaces stored tokens another client '
          '${storedRefresh == null ? 'cleared' : 'rotated'}', () async {
        final store = _TokenStore(
          storedRefresh == null
              ? null
              : HermesDesktopTokenSet(
                  accessToken: 'pushed-access',
                  refreshToken: storedRefresh,
                  expiresAt: DateTime.utc(2099),
                ),
          expected: 'refresh',
        );
        final gateway = service(
          _TokenRest(),
          expiresAt: DateTime.utc(2099),
          saved: [],
          browserAuth: _Sheet(),
          readStoredTokens: store.read,
          writeCredentials: store.write,
        );

        check(await gateway.signInNative()).isNotNull();

        check(store.tokens?.refreshToken).equals('signed-in-refresh');
      });
    }

    // The live client and a push pass renew the same tokens as the app
    // resumes: the second waits for the first, then takes what it stored,
    // rather than send the refresh token the first just spent.
    test('two clients renewing at once send the refresh token once',
        () => withClock(Clock.fixed(now), () async {
      final held = Completer<void>();
      final rest = _TokenRest(refreshGate: held.future);
      final store = _SharedTokens(
        HermesDesktopTokenSet(
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt: now.add(const Duration(seconds: 30)),
        ),
      );
      HermesDesktopApiService client({Completer<void>? renewing}) {
        final (:read, :write) = store.client();
        void arrive() {
          if (!(renewing?.isCompleted ?? true)) renewing!.complete();
        }

        return service(
          rest,
          expiresAt: now.add(const Duration(seconds: 30)),
          saved: [],
          // Whichever it reaches first as it renews: the guard, or with
          // none, the stored tokens.
          readStoredTokens: () {
            arrive();
            return read();
          },
          writeCredentials: write,
          guardTokens: <T>(Future<T> Function() action) {
            arrive();
            return store.guard(action);
          },
        );
      }

      final pushRenewing = Completer<void>();
      final live = client();
      final push = client(renewing: pushRenewing);
      final jobs = [live.listJobs(), push.listJobs()];
      await rest.refreshArrived.future;
      await pushRenewing.future;
      held.complete();
      await Future.wait(jobs);

      check(rest.refreshTokensSent).deepEquals(['refresh']);
      check(rest.jobsAuthorizations).deepEquals([
        'Bearer renewed-access',
        'Bearer renewed-access',
      ]);
    }));

    // Another client's rotation that lands between a sign-in's read of the
    // stored tokens and its save would make that save expect tokens no
    // longer stored, and drop the sign-in.
    test('a sign-in holds off other clients from its read to its save',
        () async {
      final store = _SharedTokens(
        HermesDesktopTokenSet(
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt: DateTime.utc(2099),
        ),
      );
      final other = store.client();
      final (:read, :write) = store.client();
      Future<void>? competing;
      final gateway = service(
        _TokenRest(),
        expiresAt: DateTime.utc(2099),
        saved: [],
        browserAuth: _Sheet(),
        readStoredTokens: () async {
          final tokens = await read();
          competing = store.guard(
            () => other.write(
              HermesDesktopCredentials(
                nativeTokens: HermesDesktopTokenSet(
                  accessToken: 'pushed-access',
                  refreshToken: 'pushed-refresh',
                  expiresAt: DateTime.utc(2099),
                ),
              ),
            ),
          );
          // Its chance to land before the save. Not awaited: under the
          // sign-in's guard, it waits for the sign-in to end.
          await pumpEventQueue();
          return tokens;
        },
        writeCredentials: write,
        guardTokens: store.guard,
      );

      check(await gateway.signInNative()).isNotNull();
      await competing;

      check(store.tokens?.refreshToken).equals('signed-in-refresh');
    });

    // Another client stored tokens that have expired since, and Hermes
    // can't renew them for now: the request fails, and nothing signs out.
    test('a refused request whose renewal Hermes could not answer keeps the '
        'expired tokens another client stored',
        () => withClock(Clock.fixed(now), () async {
      final rest = _TokenRest(
        refreshStatus: HttpStatus.serviceUnavailable,
        requestStatus: HttpStatus.unauthorized,
      );
      final saved = <HermesDesktopCredentials>[];
      final gateway = service(
        rest,
        expiresAt: now.add(const Duration(hours: 1)),
        saved: saved,
        readStoredTokens: () async => HermesDesktopTokenSet(
          accessToken: 'pushed-access',
          refreshToken: 'pushed-refresh',
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      );

      await check(gateway.listJobs()).throws<DioException>();

      check(saved).isEmpty();
      check(rest.refreshTokensSent).deepEquals(['pushed-refresh']);
    }));

    // Saving this client's rotation failed, so storage still holds the
    // refresh token it spent. That one is older, not newer: the client
    // renews its own rotation, and never sends the spent token again.
    test('rotations that failed to save are renewed over the spent token '
        'storage kept', () async {
      var time = now;
      await withClock(Clock(() => time), () async {
        final rest = _TokenRest(rotates: true);
        final lifecycle = _Lifecycle();
        final gateway = service(
          rest,
          expiresAt: now.add(const Duration(minutes: 2)),
          saved: [],
          readStoredTokens: () async => HermesDesktopTokenSet(
            accessToken: 'access',
            refreshToken: 'refresh',
            expiresAt: now.add(const Duration(minutes: 2)),
          ),
        )..startLifecycleObservation(lifecycle);

        lifecycle.emit(AppLifecyclePhase.resumed);
        await gateway.resumeRenewal;
        // Each later rotation fails to save too, so storage stays put.
        for (var renewal = 1; renewal <= 11; renewal++) {
          time = _TokenRest.expiryOf(renewal).subtract(
            const Duration(minutes: 2),
          );
          lifecycle.emit(AppLifecyclePhase.resumed);
          await gateway.resumeRenewal;
        }

        check(rest.refreshTokensSent).deepEquals([
          'refresh',
          for (var renewal = 1; renewal <= 11; renewal++)
            'renewed-refresh-$renewal',
        ]);
      });
    });

    // Hermes answers `session_expired`: the refresh token is dead, so the
    // tokens go, and every request after says sign-in is needed.
    test('a refused renewal asks to sign in again', () async {
      final rest = _TokenRest(refreshStatus: HttpStatus.unauthorized);
      final saved = <HermesDesktopCredentials>[];
      final gateway = service(
        rest,
        expiresAt: DateTime.utc(2020),
        saved: saved,
      );

      await check(gateway.listJobs()).throws<HermesGatewaySignInRequired>();
      check(saved.single.nativeTokens).isNull();
      await check(gateway.listJobs()).throws<HermesGatewaySignInRequired>();
      check(rest.paths).not((it) => it.contains('/api/cron/jobs'));
    });

    test('a 401 the renewed tokens get too asks to sign in again', () async {
      final rest = _TokenRest(requestStatus: HttpStatus.unauthorized);
      final saved = <HermesDesktopCredentials>[];
      final gateway = service(
        rest,
        expiresAt: DateTime.utc(2099),
        saved: saved,
      );

      await check(gateway.listJobs()).throws<HermesGatewaySignInRequired>();
      check(saved.last.nativeTokens).isNull();
    });
  });

  group('connection name suggestion', () {
    test('uses the Desktop profile title, else its name', () async {
      final gateway = await _Gateway.start(
        profiles: [
          {'name': 'default'},
          {
            'name': 'research',
            'ui_meta': {
              'hermes-bots': {'title': 'Research Bot'},
            },
          },
          {'name': 'plain'},
        ],
      );
      addTearDown(gateway.close);
      final container = ProviderContainer(
        overrides: [hermesConfigProvider.overrideWith(_DisabledConfig.new)],
      );
      addTearDown(container.dispose);
      final connection = container.read(hermesConnectionGatewayProvider);

      HermesConfig draft(String profile) => HermesConfig(
        baseUrl: gateway.baseUrl,
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.nativePkce,
        desktopProfile: profile,
        desktopCredentials: HermesDesktopCredentials(
          nativeTokens: HermesDesktopTokenSet(
            accessToken: 'access',
            refreshToken: 'refresh',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        ),
      );

      check(
        await connection.suggestDisplayName(draft('research')),
      ).equals('Research Bot');
      check(await connection.suggestDisplayName(draft('plain'))).equals('plain');
      check(await connection.suggestDisplayName(draft('missing'))).isNull();
      // Hermes's unconfigured default profile says nothing about the server.
      check(await connection.suggestDisplayName(draft('default'))).isNull();
      check(gateway.rpcMethods).contains('profiles.list');
    });

    test('uses the first Responses model id', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/v1/models') {
          check(
            request.headers.value(HttpHeaders.authorizationHeader),
          ).equals('Bearer key');
          request.response.write(
            jsonEncode({
              'object': 'list',
              'data': [
                {'id': 'my-agent', 'object': 'model'},
                {'id': 'alias', 'object': 'model'},
              ],
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final container = ProviderContainer(
        overrides: [hermesConfigProvider.overrideWith(_DisabledConfig.new)],
      );
      addTearDown(container.dispose);

      check(
        await container
            .read(hermesConnectionGatewayProvider)
            .suggestDisplayName(
              HermesConfig(
                baseUrl: 'http://127.0.0.1:${server.port}/v1',
                apiKey: 'key',
              ),
            ),
      ).equals('my-agent');
    });
  });
}

final class _DisabledConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(enabled: false);
}

final class _Gateway {
  _Gateway(this.server, {this.profiles = const []});

  final HttpServer server;

  /// Rows `profiles.list` answers with.
  final List<Map<String, Object?>> profiles;
  final sockets = <WebSocket>[];
  final ticketAuthorizations = <String?>[];
  final socketTickets = <String?>[];

  /// The codes `/auth/native/token` was asked to exchange.
  final exchangedCodes = <Object?>[];
  final rpcMethods = <String>[];
  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_Gateway> start({
    List<Map<String, Object?>> profiles = const [],
  }) async {
    final gateway = _Gateway(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      profiles: profiles,
    );
    gateway.server.listen(gateway.handle);
    return gateway;
  }

  Future<void> handle(HttpRequest request) async {
    if (request.uri.path == '/api/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final ticket = request.uri.queryParameters['ticket'];
      socketTickets.add(ticket);
      if (ticket != 'native-ticket' && ticket != 'dashboard-ticket') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': {}},
        }),
      );
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        rpcMethods.add(frame['method'] as String);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': frame['method'] == 'profiles.list'
                ? {'profiles': profiles}
                : {},
          }),
        );
      });
      return;
    }
    request.response.headers.contentType = ContentType.json;
    switch (request.uri.path) {
      case '/api/status':
        request.response.write(
          jsonEncode({
            'auth_required': true,
            'auth_flows': ['cookie', 'native_pkce'],
          }),
        );
      case '/auth/native/token':
        exchangedCodes.add(
          (jsonDecode(await utf8.decodeStream(request)) as Map)['code'],
        );
        request.response.write(
          jsonEncode({
            'access_token': 'access',
            'refresh_token': 'refresh',
            'expires_at':
                DateTime.now()
                    .add(const Duration(minutes: 15))
                    .millisecondsSinceEpoch ~/
                1000,
          }),
        );
      case '/api/auth/ws-ticket':
        final authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        ticketAuthorizations.add(authorization);
        if (request.method == 'POST' && authorization == 'Bearer access') {
          request.response.write(jsonEncode({'ticket': 'native-ticket'}));
        } else {
          request.response.statusCode = HttpStatus.unauthorized;
        }
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

final class _CallbackBrowser implements OpenExternalUrlPort {
  _CallbackBrowser({this.code = 'one-time-code'});

  final String code;
  final opened = <Uri>[];

  /// The page the listener answered the callback with, once it has.
  final page = Completer<({int status, String body})>();

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    final callback = Uri.parse(url.queryParameters['redirect_uri']!).replace(
      queryParameters: {'code': code, 'state': url.queryParameters['state']!},
    );
    unawaited(() async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(callback)).close();
        page.complete((
          status: response.statusCode,
          body: await utf8.decodeStream(response),
        ));
      } finally {
        client.close(force: true);
      }
    }());
    return true;
  }
}

/// The system browser's sheet. It follows the sign-in page to the loopback
/// redirect Hermes sends it to, and ends where the listener sends it next:
/// on the app's redirect, it returns that, as the platform does.
final class _Sheet implements BrowserAuthPort {
  _Sheet({
    this.supported = true,
    this.closedByUser = false,
    this.strayFirst = false,
    this.code = 'one-time-code',
  });

  final bool supported;

  /// Closed before Hermes redirects, so the listener is never reached.
  final bool closedByUser;

  /// Something else on the device calls the listener, with another state,
  /// before Hermes redirects.
  final bool strayFirst;

  /// The code Hermes' redirect carries; none when null.
  final String? code;

  final opened = <Uri>[];
  final redirects = <Uri>[];
  final answers = <({int status, String? location})>[];

  @override
  bool get isSupported => supported;

  @override
  Future<BrowserAuthResult> authorize(
    Uri url, {
    required Uri redirectUri,
    bool preferEphemeral = false,
  }) async {
    opened.add(url);
    redirects.add(redirectUri);
    if (closedByUser) return const BrowserAuthResult.cancelled();
    final listener = Uri.parse(url.queryParameters['redirect_uri']!);
    final client = HttpClient();
    Future<String?> call(Map<String, String> query) async {
      final request = await client.getUrl(
        listener.replace(queryParameters: query),
      );
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      final location = response.headers.value(HttpHeaders.locationHeader);
      answers.add((status: response.statusCode, location: location));
      return location;
    }

    try {
      if (strayFirst) await call({'code': 'stray-code', 'state': 'forged'});
      final location = await call({
        'code': ?code,
        'state': url.queryParameters['state']!,
      });
      final landed = Uri.tryParse(location ?? '');
      if (landed == null ||
          landed.scheme != redirectUri.scheme ||
          landed.host != redirectUri.host ||
          landed.path != redirectUri.path) {
        return const BrowserAuthResult.failed(
          BrowserAuthErrorCodes.unexpectedCallback,
        );
      }
      return BrowserAuthResult(
        outcome: BrowserAuthOutcome.success,
        callbackUri: landed,
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> cancel() async {}
}

/// A gateway that requires sign-in: answers the token refresh with
/// [refreshStatus] and any other request with [requestStatus].
final class _TokenRest implements HttpClientAdapter {
  _TokenRest({
    this.refreshStatus = HttpStatus.ok,
    this.requestStatus = HttpStatus.ok,
    this.refreshGate,
    this.rotates = false,
  });

  final int refreshStatus;
  final int requestStatus;

  /// Each renewal issues new tokens, `renewed-refresh-1` onwards, expiring at
  /// [expiryOf] their number; otherwise always `renewed-refresh`.
  final bool rotates;
  var _renewals = 0;

  static DateTime expiryOf(int renewal) =>
      DateTime.utc(2030).add(Duration(hours: renewal));

  /// Holds the refresh's answer until it completes.
  final Future<void>? refreshGate;
  final paths = <String>[];

  /// The refresh tokens renewals sent.
  final refreshTokensSent = <Object?>[];

  /// Completes once a renewal reaches the gateway.
  final refreshArrived = Completer<void>();

  /// The `Authorization` each `/api/cron/jobs` request carried.
  final jobsAuthorizations = <Object?>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    paths.add(path);
    if (path == '/auth/native/refresh') {
      final data = options.data;
      final body = data is String ? jsonDecode(data) : data;
      refreshTokensSent.add((body as Map)['refresh_token']);
      if (!refreshArrived.isCompleted) refreshArrived.complete();
      await refreshGate;
    }
    if (path == '/api/cron/jobs') {
      jobsAuthorizations.add(options.headers['Authorization']);
    }
    final (status, Object body) = switch (path) {
      '/api/status' => (
        HttpStatus.ok,
        {
          'auth_required': true,
          'auth_flows': ['native_pkce'],
        },
      ),
      '/auth/native/token' => (
        HttpStatus.ok,
        {
          'access_token': 'signed-in-access',
          'refresh_token': 'signed-in-refresh',
          'expires_at': DateTime.utc(2099).millisecondsSinceEpoch ~/ 1000,
        },
      ),
      '/api/cron/jobs' when requestStatus == HttpStatus.ok => (
        HttpStatus.ok,
        const <Object?>[],
      ),
      '/auth/native/refresh' when refreshStatus == HttpStatus.ok && rotates =>
        (
          HttpStatus.ok,
          {
            'access_token': 'renewed-access-${++_renewals}',
            'refresh_token': 'renewed-refresh-$_renewals',
            'expires_at':
                expiryOf(_renewals).millisecondsSinceEpoch ~/ 1000,
          },
        ),
      '/auth/native/refresh' when refreshStatus == HttpStatus.ok => (
        HttpStatus.ok,
        {
          'access_token': 'renewed-access',
          'refresh_token': 'renewed-refresh',
          'expires_at': DateTime.utc(2099).millisecondsSinceEpoch ~/ 1000,
        },
      ),
      '/auth/native/refresh' => (refreshStatus, {'error': 'session_expired'}),
      _ => (requestStatus, const <String, Object?>{}),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Stored gateway tokens under the controller's rule: a save must expect the
/// refresh token stored, and a read makes the reader expect it. A refused
/// save is dropped, as the live client's writer drops it.
final class _TokenStore {
  _TokenStore(this.tokens, {required this.expected});

  HermesDesktopTokenSet? tokens;
  String? expected;

  Future<HermesDesktopTokenSet?> read() async {
    expected = tokens?.refreshToken;
    return tokens;
  }

  Future<void> write(HermesDesktopCredentials credentials) async {
    if (tokens?.refreshToken != expected) return;
    tokens = credentials.nativeTokens;
    expected = tokens?.refreshToken;
  }
}

/// Stored gateway tokens shared by several clients, each with its own
/// expectation of them, as the controller's `tokenAccessFor` hands them out,
/// and its guard for the gateway connection.
final class _SharedTokens {
  _SharedTokens(this.tokens);

  HermesDesktopTokenSet? tokens;
  final _lock = Lock();

  Future<T> guard<T>(Future<T> Function() action) =>
      _lock.synchronized(action);

  ({HermesDesktopTokensReader read, HermesDesktopCredentialsWriter write})
  client() {
    var expected = tokens?.refreshToken;
    return (
      read: () async {
        expected = tokens?.refreshToken;
        return tokens;
      },
      write: (credentials) async {
        if (tokens?.refreshToken != expected) return;
        tokens = credentials.nativeTokens;
        expected = tokens?.refreshToken;
      },
    );
  }
}

final class _Lifecycle implements AppLifecyclePort {
  // Delivered at once, so the service has acted on it when [emit] returns.
  final _changes = StreamController<AppLifecyclePhase>.broadcast(sync: true);

  void emit(AppLifecyclePhase phase) => _changes.add(phase);

  @override
  AppLifecyclePhase? get current => AppLifecyclePhase.resumed;

  @override
  Stream<AppLifecyclePhase> get changes => _changes.stream;
}

final class _ProfileBridge implements HermesDashboardBridge {
  bool closed = false;
  final requests = <String>[];

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
    bool urgent = false,
    bool Function()? beforeSend,
  }) async {
    requests.add('$method ${url.path}');
    if (method == 'POST' && url.path == '/api/auth/ws-ticket') {
      return (status: 200, body: jsonEncode({'ticket': 'dashboard-ticket'}));
    }
    if (method != 'GET' || url.path != '/api/profiles') {
      return (status: 404, body: '{}');
    }
    return (
      status: 200,
      body: jsonEncode({
        'profiles': [
          {'name': 'default'},
          {'name': 'work'},
        ],
      }),
    );
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async => closed = true;
}
