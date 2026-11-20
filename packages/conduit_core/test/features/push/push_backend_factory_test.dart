import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart'
    show savedCredentialAuthApiFactoryProvider;
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend_factory.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show apiServiceProvider;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The saved connection's settings, as the Hermes controller hands them out.
final class _Configs extends HermesConfigController {
  HermesConfig saved = _home;

  /// What a token write throws; none stores it.
  Object? refusal;

  /// Runs while the saved settings are being read.
  void Function()? whileRead;

  @override
  ({
    HermesDesktopCredentialsWriter write,
    HermesDesktopTokensReader read,
    HermesDesktopTokenGuard guard,
  })
  tokenAccessFor(HermesConfig connection, {bool live = false}) => (
    write: (credentials) async {
      if (refusal case final error?) throw error;
    },
    read: () async => saved.desktopCredentials?.nativeTokens,
    guard: _unguarded,
  );

  @override
  HermesConfig build() => const HermesConfig();

  @override
  Future<HermesConfig> savedConnectionConfig(String connectionId) async {
    if (connectionId != 'conn-1') throw StateError('no such connection');
    whileRead?.call();
    return saved;
  }
}

Future<T> _unguarded<T>(Future<T> Function() action) => action();

const _home = HermesConfig(
  enabled: true,
  connectionId: 'conn-1',
  baseUrl: 'https://home.test',
  apiKey: 'old-key-0123456789',
);

const _moved = HermesConfig(
  enabled: true,
  connectionId: 'conn-1',
  baseUrl: 'https://moved.test',
  apiKey: 'new-key-0123456789',
);

HermesConnectionProfile _profile(String baseUrl, String principal) =>
    HermesConnectionProfile(
      id: 'conn-1',
      name: 'Home',
      documentTrustPrincipalId: principal,
      baseUrl: baseUrl,
    );

HermesPushTarget _target(String baseUrl, String principal) => HermesPushTarget(
  connectionId: 'conn-1',
  label: 'Home',
  baseUrl: baseUrl,
  mode: HermesBackendMode.responsesApi,
  credentialsRevision: principal,
);

void main() {
  late ProviderContainer container;
  late _Configs configs;
  late List<HermesConnectionProfile> profiles;

  setUp(() {
    configs = _Configs();
    profiles = [_profile(_home.baseUrl, 'p-1')];
    container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(() => configs),
        hermesConnectionsProvider.overrideWith((ref) => profiles),
      ],
    );
    container.read(hermesConfigProvider);
  });

  tearDown(() => container.dispose());

  AppPushBackendFactory factory() =>
      container.read(pushBackendFactoryProvider) as AppPushBackendFactory;

  Future<void> edit() async {
    configs.saved = _moved;
    profiles = [_profile(_moved.baseUrl, 'p-2')];
    container.invalidate(hermesConnectionsProvider);
  }

  test('a target reaches the server it names', () async {
    final config = await factory().hermesConfigFor(
      _target(_home.baseUrl, 'p-1'),
    );
    check(config.baseUrl).equals(_home.baseUrl);
  });

  test('after an edit, the old target reaches its old server', () async {
    final old = _target(_home.baseUrl, 'p-1');
    await factory().retain(old);
    await edit();

    final config = await factory().hermesConfigFor(old);
    check(config.baseUrl).equals(_home.baseUrl);
    check(config.apiKey).equals(_home.apiKey);
    // The new target reaches the new server.
    final now = await factory().hermesConfigFor(_target(_moved.baseUrl, 'p-2'));
    check(now.baseUrl).equals(_moved.baseUrl);
  });

  // A gateway's tokens outlive a profile change, and the live client keeps
  // rotating them: the refresh token the old settings were kept with is
  // spent, and a provider that detects reuse ends the session on seeing it.
  // They go only where the gateway's current settings trust, and only from
  // settings read paired with their principal.
  for (final (editedWhileRead, refreshToken, selfSigned) in [
    (false, 'rotated-refresh', false),
    (true, 'spent-refresh', true),
  ]) {
    test('an old target on the same gateway uses '
        '${editedWhileRead ? 'its own tokens when an edit lands as the '
                  'current ones are read' : 'its current tokens, over the '
                  'connection it trusts now'}', () async {
      HermesConfig desktop(
        String profile,
        String refreshToken, {
        required bool selfSigned,
      }) => HermesConfig(
        enabled: true,
        connectionId: 'conn-1',
        baseUrl: _home.baseUrl,
        allowSelfSignedCertificates: selfSigned,
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.nativePkce,
        desktopProfile: profile,
        desktopCredentials: HermesDesktopCredentials(
          nativeTokens: HermesDesktopTokenSet(
            accessToken: 'access-$refreshToken',
            refreshToken: refreshToken,
            expiresAt: DateTime.utc(2030),
          ),
        ),
      );
      configs.saved = desktop('default', 'spent-refresh', selfSigned: true);
      const old = HermesPushTarget(
        connectionId: 'conn-1',
        label: 'Home',
        baseUrl: 'https://home.test',
        mode: HermesBackendMode.desktopGateway,
        credentialsRevision: 'p-1',
      );
      await factory().retain(old);
      configs.saved = desktop('work', 'rotated-refresh', selfSigned: false);
      profiles = [_profile(_home.baseUrl, 'p-2')];
      container.invalidate(hermesConnectionsProvider);
      if (editedWhileRead) {
        configs.whileRead = () {
          profiles = [_profile(_home.baseUrl, 'p-3')];
          container.invalidate(hermesConnectionsProvider);
        };
      }

      final config = await factory().hermesConfigFor(old);
      check(config.desktopProfile).equals('default');
      check(
        config.desktopCredentials?.nativeTokens?.refreshToken,
      ).equals(refreshToken);
      check(config.allowSelfSignedCertificates).equals(selfSigned);
    });
  }

  // The live client renews the same tokens as the app resumes, and stores
  // its rotation first: this client's is refused, which is no sign-out, and
  // the tokens it holds still work. A sign-out ends the pass.
  for (final (refusal, worksOn) in [
    (HermesTokenRotationSuperseded(), true),
    (StateError('Hermes connection changed before sign-in completed.'), false),
  ]) {
    test('a Hermes client whose rotation is refused by '
        '${refusal.runtimeType} ${worksOn ? 'works on' : 'stops'}', () async {
      configs.refusal = refusal;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final authorizations = <String?>[];
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/api/status':
            request.response.write('{"auth_required":true}');
          case '/auth/native/refresh':
            request.response.write(
              jsonEncode({
                'access_token': 'fresh-access',
                'refresh_token': 'fresh-refresh',
                'expires_at': DateTime.utc(2030).millisecondsSinceEpoch ~/ 1000,
              }),
            );
          case '/api/cron/jobs':
            authorizations.add(
              request.headers.value(HttpHeaders.authorizationHeader),
            );
            request.response.write('[]');
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      configs.saved = HermesConfig(
        enabled: true,
        connectionId: 'conn-1',
        baseUrl: 'http://127.0.0.1:${server.port}',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.nativePkce,
        desktopCredentials: HermesDesktopCredentials(
          nativeTokens: HermesDesktopTokenSet(
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            expiresAt: DateTime.utc(2020),
          ),
        ),
      );

      final service = await factory().openHermesService('conn-1');
      addTearDown(service.close);
      if (worksOn) {
        check(await service.listJobs()).isEmpty();
        check(authorizations).deepEquals(['Bearer fresh-access']);
      } else {
        await check(
          service.listJobs(),
        ).throws<Object>((it) => it.identicalTo(refusal));
        check(authorizations).isEmpty();
      }
    });
  }

  test('without the old settings, the old target is refused', () async {
    await edit();
    PushBackendException? refused;
    try {
      await factory().hermesConfigFor(_target(_home.baseUrl, 'p-1'));
    } on PushBackendException catch (error) {
      refused = error;
    }
    check(refused?.failure.detail).equals('connection_changed');
  });

  // An edit under way, or one rolled back, leaves the saved address blank.
  void clearAddress() {
    configs.saved = _home.copyWith(baseUrl: '');
    profiles = [_profile('', 'p-1')];
    container.invalidate(hermesConnectionsProvider);
  }

  test('with its address cleared, a target reaches its server still', () async {
    final old = _target(_home.baseUrl, 'p-1');
    await factory().retain(old);
    clearAddress();

    final config = await factory().hermesConfigFor(old);
    check(config.baseUrl).equals(_home.baseUrl);
  });

  test('a cleared address with nothing kept is an invalid one', () async {
    clearAddress();
    PushBackendException? refused;
    try {
      await factory().hermesConfigFor(_target(_home.baseUrl, 'p-1'));
    } on PushBackendException catch (error) {
      refused = error;
    }
    check(refused?.failure.detail).equals('invalid_url');
  });

  test("the active account's switch queues on its live client", () async {
    final server = _SettingsServer();
    final live = _liveClient(server);
    var throwaway = 0;
    final app = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(live),
        savedCredentialAuthApiFactoryProvider.overrideWithValue(
          ({required serverConfig, required workerManager}) {
            throwaway++;
            throw StateError('the live client should be used');
          },
        ),
      ],
    );
    addTearDown(app.dispose);

    // A settings write the app made first, still reading the document.
    final gate = Completer<void>();
    server.gate = gate;
    final sound = live.updateUserNotificationSettings(notificationSound: false);
    final push = app
        .read(pushBackendFactoryProvider)
        .setOpenWebUiNotificationsEnabled('acct-1', enabled: true);
    await pumpEventQueue();
    gate.complete();
    await sound;
    await push;

    check(throwaway).equals(0);
    // Both writes kept, under `ui` where Open WebUI keeps them.
    check(server.settings).deepEquals({
      'ui': {'notificationSound': false, 'notificationEnabled': true},
    });
  });

  test('a switch its server already holds is kept when asked', () async {
    final server = _SettingsServer()..settings = {'notificationEnabled': false};
    final app = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(_liveClient(server))],
    );
    addTearDown(app.dispose);
    final factory = app.read(pushBackendFactoryProvider);

    await factory.setOpenWebUiNotificationsEnabled(
      'acct-1',
      enabled: true,
      onlyIfUnset: true,
    );
    check(server.settings).deepEquals({'notificationEnabled': false});

    // Turned off in Open WebUI's own settings, under `ui`.
    server.settings = {
      'ui': {'notificationEnabled': false},
    };
    await factory.setOpenWebUiNotificationsEnabled(
      'acct-1',
      enabled: true,
      onlyIfUnset: true,
    );
    check(server.settings).deepEquals({
      'ui': {'notificationEnabled': false},
    });

    server.settings = {
      'ui': {'notificationSound': false},
    };
    await factory.setOpenWebUiNotificationsEnabled(
      'acct-1',
      enabled: true,
      onlyIfUnset: true,
    );
    check(server.settings).deepEquals({
      'ui': {'notificationSound': false, 'notificationEnabled': true},
    });
  });
}

/// The live client of acct-1, the active account, talking to [server].
ApiService _liveClient(_SettingsServer server) => ApiService(
  serverConfig: const ServerConfig(
    id: 'acct-1',
    name: 'Home',
    url: 'https://owui.test',
    isActive: true,
  ),
  workerManager: WorkerManager(),
  authToken: 'live-token-0123456789',
)..dio.httpClientAdapter = server;

/// Open WebUI's user settings document, replaced by every update.
final class _SettingsServer implements HttpClientAdapter {
  Map<String, dynamic> settings = {};

  /// Holds the next request until completed.
  Completer<void>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final held = gate;
    if (held != null) {
      gate = null;
      await held.future;
    }
    if (options.method == 'POST') {
      settings = Map<String, dynamic>.from(options.data as Map);
    }
    return ResponseBody.fromString(
      jsonEncode(settings),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
